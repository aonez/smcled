# smcled

Control the **status LED** of supported Mac mini and Mac Studio computers from Terminal. On verified Apple Silicon models, set white/amber brightness (0–255), select blinking patterns, or automate sunrise/sunset transitions. On the 2018 Intel T2 Mac mini, off/full-white/system-default and several manually dimmed levels have been physically verified. The full 0–255 manual range and optional software fading are available experimentally; Intel amber is unsupported.

Written in Swift using AppleSMC/IOKit. No third-party dependencies, SIP changes, or internet connection required.

**Hardware verified:** M1 Mac mini (`Macmini9,1`) and M4 Max Mac Studio (`Mac16,9`) for manual white brightness and steady amber; 2018 Intel T2 Mac mini (`Macmini8,1`) for off, forced full-white, and restoration to normal white. Additional Intel brightness levels are available as experimental manual settings; no Intel persistent installation is enabled. Other M1–M4 models, and future Apple Silicon Mac mini/Studio models, require explicit experimental acknowledgement.

## Build

Requires Xcode Command Line Tools:

```sh
swiftc -O smcled.swift -framework IOKit -o smcled
```

## Usage

```sh
sudo ./smcled --white 100         # White at brightness 100
sudo ./smcled --amber 100         # Steady amber
sudo ./smcled --amber-blink 50    # Blinking amber
sudo ./smcled --amber-double 50   # Double blink
sudo ./smcled --off               # LED off
sudo ./smcled --reset             # Restore white at 255
```

Brightness values range from `0` (off) to `255` (maximum). Run `./smcled --help` for all options.

## Intel Mac mini 2018 (T2, Macmini8,1)

The Intel Mac mini has **different SMC LED controls from Apple Silicon**. Physical tests on one 2018 Mac mini (T2/bridgeOS 24P6005) confirmed:

| Command | SMC call | Observed result |
|---|---|---|
| `sudo ./smcled --off` (or `--intel-off`) | `LSOO=0` | Front LED goes off; `LSPV=00 00`, `LSOF=01` |
| `sudo ./smcled --intel-full` | `LSOO=1` | Front LED becomes substantially brighter white; `LSPV=6B 08` |
| `sudo ./smcled --reset` (or `--intel-restore`, `--white`) | `LSRB=0`, reset `LSLB=FF FF` | Returns to firmware-controlled normal white with a fade; `LSPV=14 11` |
| `./smcled --intel-led-status` | Read-only | Prints current Intel LED-related SMC registers |

Intel LED commands require `sudo`, check the `Macmini8,1` model and exact SMC metadata/calibration, and confirm the observed SMC output. **Manual brightness now fades by default**, while `--no-fade` requests an immediate write; `--reset` uses the controller's normal restoration behavior. No Intel commands install a daemon or persist a boot preference. On the tested unit, `LSLN=2F FF`, `LSSV=08 6B`, and `LS! =00`; if your unit differs, write commands refuse to run until separately validated. A reported SMC state does not substitute for seeing the physical LED respond.

**Intel 0–255 manual brightness is experimental.** `sudo ./smcled --intel-brightness 50`, `sudo ./smcled --white 50`, or `sudo ./smcled 50` set a live white PWM level via `LSLB=[value,value]` and `LSOO=1`; `0` uses the separately verified `LSOO=0` off command. `sudo ./smcled --reset` restores firmware-controlled normal white and the original `LSLB=FF FF`. Custom-to-custom updates now write `LSLB` **directly** while the manual override is active; from off, `LSLB` is configured before re-enabling the LED. This avoids the previous intermediate return to firmware-controlled normal brightness, which caused visible flashes at small brightness levels. The revised direct-transition path still needs physical confirmation. These values are not perceptually linear or photometrically calibrated. **Unsupported on Intel:** amber/color selection, `--install`, and `--install-auto`. White blinking tests remain separate from amber. Sleep/wake/restart behavior is untested.

### Intel variable-brightness research (physically observed)

The **full-on PWM preset** `LSLB`, combined with `LSOO=1`, changes the reported LED output linearly. The tested 2018 Mac mini physically dimmed when `LSLB=10 00`; the experiment was repeated three times. These are different brightness values, not three hardware modes.

| Temporary `LSLB` setting | Observed `LSPV` | Physical outcome |
|---|---|---|
| `10 00` | `06 B0` | Visibly below normal brightness, three repeat tests |
| `7F FF` | `35 84` | Above normal, roughly half of the full-on PWM |
| `FF FF` | `6B 08` | Previously verified full white |
| *(normal mode, via `LSRB`)* | `14 11` | Normal white (does not use full-on override) |

The relationship is approximately `LSPV ≈ 0.4181 × LSLB`, interpreting the 2-byte values as **big-endian unsigned PWM integers**. This is SMC telemetry, not a calibrated photometric measurement of the LED.

Further tests support either a **reversible two-second probe at any 0–255 level**, or a manual level that stays active until another command or an SMC reset. The test probe always tries to restore normal white; the manual CLI does not automatically revert.

```sh
swiftc -O smcled-intel-lsoo-probe.swift -framework IOKit -o intel-sil-probe
sudo ./intel-sil-probe --test-very-low-dim --confirm-hardware-test  # LSLB=08 00; predicted LSPV≈03 58
sudo ./intel-sil-probe --test-mid-dim --confirm-hardware-test       # LSLB=20 00; predicted LSPV≈0D 61
sudo ./intel-sil-probe --test-low-dim --confirm-hardware-test       # already verified 10 00
sudo ./intel-sil-probe --test-full-dim --confirm-hardware-test      # already verified 7F FF
sudo ./intel-sil-probe --test-brightness 50 --confirm-hardware-test  # custom 0...255; returns to normal

# Custom manual level (no timeout, no startup persistence):
sudo ./smcled --intel-brightness 50
sudo ./smcled --intel-brightness 100
sudo ./smcled --reset             # restore normal system-controlled white
```

Run **one** test at a time and confirm normal LED brightness has returned before trying the next. Each test requires the observed baseline and restores the original `LSLB=FF FF` and normal LED mode. Previous versions restored `LSLB` *before* clearing the `LSOO` full-on override, briefly producing a maximum-white pulse; the revised diagnostic now calls `LSRB` and waits for normal PWM **before** restoring `LSLB`. This corrected restoration ordering was confirmed in the subsequent physical low/very-low/mid tests. If anything fails, stop and inspect the LED. Sudden crashes, power loss, and undocumented firmware behavior may prevent recovery.

Arbitrary **0–255 manual** Intel brightness is enabled for experimental testing, with guards for the observed `Macmini8,1` calibration and live output. The 0–255 range and custom levels across multiple commands have not all been physically tested. The exact mapping is an 8-bit input replicated to a 16-bit preset; do not assume Apple Silicon brightness levels look identical. Persistent Intel installation is still disabled. If a write or restoration fails, stop and inspect the LED rather than repeating commands.

### Intel white-only flashing patterns

The tested 2018 Intel Mac mini uses a **white front status LED**. No amber color was observed in any hardware test, and the model-specific evidence indicates that amber is not available on this machine. **Intel amber compatibility is intentionally not provided**; Apple Silicon amber controls are separate and unchanged.

The two patterns confirmed on the physical Intel mini remain available only as explicit, reversible research tests:

| Command | SMC payload | Physical result |
|---|---|---|
| `sudo ./intel-sil-probe --test-white-blink --confirm-hardware-test` | `LSSB=08 00` | Repeating single **white** flash |
| `sudo ./intel-sil-probe --test-white-double --confirm-hardware-test` | `LSSB=09 00` | Repeating double **white** flash |

Each probe displays the pattern briefly, then calls `LSRB` and confirms a return to normal white. Earlier exploratory values `LSSB=04 00` and `01 00` showed no visible change, while `00 00` turned the white LED off; those speculative amber tests have been removed from the probe and are preserved only in historical research notes. No additional color-mode guessing is planned.

### Native and software LED fades

**Intel Mac mini 2018:** Regular manual white brightness commands now perform a software fade by default. Duration is **proportional to the actual brightness change**, with 0→255 taking one second:

\[
\text{duration (seconds)} = |\text{new level}-\text{current level}| / 255
\]

The Intel hardware reacts immediately to each `LSLB` write, so smcled interpolates its 16-bit PWM preset with smoothstep easing. This interpolation was physically tested successfully at longer, explicit durations before becoming the default; short proportional transitions still require on-device testing. Tiny changes may finish more slowly than the theoretical duration because SMC calls take time.

```sh
sudo ./smcled 20                    # Intel: fade toward brightness 20, proportional duration
sudo ./smcled 200                   # Intel: same rule regardless of target level
sudo ./smcled 20 --no-fade          # Intel: direct immediate change
sudo ./smcled --off                 # Intel: proportional fade to off
sudo ./smcled --fade 100            # Intel: explicitly request proportional fade
sudo ./smcled --fade 100 3          # Intel: explicitly request a 3-second software fade
sudo ./smcled --reset               # Intel: restore firmware-controlled white
```

**Apple Silicon Mac mini / Studio:** Keep the previously tested **native SMC write behavior by default**. White LED brightness on the tested M1 showed natural smoothing from direct writes; this is distinct from smcled's three-second, **software-driven** sunrise/sunset transitions. We deliberately do not apply a second software fade to ordinary Apple Silicon manual commands. `--no-fade` cannot disable any smoothing intrinsic to the hardware.

```sh
sudo ./smcled 20                    # Apple Silicon: original native white LED control
sudo ./smcled --white 100           # Apple Silicon: original native white LED control
sudo ./smcled --fade 100            # Apple Silicon: single native SMC write on current channel
sudo ./smcled --fade 100 3          # Apple Silicon: explicit 3-second SOFTWARE fade on current channel
```

On both architectures, an explicit `--fade <level> [seconds]` with a supplied duration selects software easing. Duration overrides accept `0.01...15` seconds. Without an explicit duration, Intel applies proportional software fading and Apple Silicon uses native hardware behavior. `--fade` preserves the active color channel on Apple Silicon; bare numeric values and `--white` target white as before.

**Automatic mode:** The existing Apple Silicon sunrise/sunset schedule still uses its independently implemented three-second software fades; its timing has *not* been changed. Intel has the PWM fade mechanism needed for a future **white-only** automatic mode, but Intel automation remains disabled pending a separate scheduling and wake/reboot design.

## Automatic sunrise/sunset mode

| Time | LED |
|---|---|
| Sunrise − 1 hour | Amber `100` |
| Sunrise | White `33` |
| Sunrise + 1 hour | White `255` |
| Sunset | White `100` |
| Sunset + 1 hour | Amber `255` |
| Sunset + 4 hours | Amber `33` |

For sunsets at **21:00 or later**, the last transition occurs after **3 hours** instead of 4. Changes use 3-second fades; color changes fade through darkness.

```sh
./smcled --auto-preview           # Preview today's schedule; no LED changes
sudo ./smcled --auto-check        # Apply the current state once
sudo ./smcled --install-auto      # Enable automation (every 300 seconds)
sudo ./smcled --install-auto 60   # Or customize interval (30–86400 seconds)
./smcled --status                # Check installation and actual interval
sudo smcled --uninstall           # Remove installation and reset LED
```

Installation creates a one-shot system LaunchDaemon that runs at startup and periodically (default **300 seconds**). The optional interval is in seconds; to change it, rerun `--install-auto` with a new value. Transitions can be delayed by roughly the selected interval. No resident process is needed.

Solar times are calculated offline using the city configured in macOS (`/Library/Preferences/.GlobalPreferences.plist`), with CoreBrightness as a fallback. No location permission is needed. These are undocumented system interfaces and may change in future macOS releases.

Fixed startup settings are also available, e.g. `sudo ./smcled --install amber 100`.

## Check another Mac

```sh
./smcled --compatibility             # Read-only SMC key check
./smcled --compatibility-self-test   # Offline classification self-tests
./smcled --sample-brightness         # Read-only LSLN samples
sudo ./smcled --test-brightness 100 --confirm-hardware-test
sudo ./smcled --test-studio-amber --confirm-hardware-test  # Mac16,9 only
./smcled --intel-snapshot            # Intel: read-only LED-related SMC keys
sudo ./smcled --intel-suite --confirm-hardware-test  # Intel: three stages
sudo ./smcled --intel-probe first 32 --confirm-hardware-test
sudo ./smcled --intel-probe second 100 --confirm-hardware-test
sudo ./smcled --test-intel-brightness 100 --confirm-hardware-test  # Legacy second-byte probe
```

`--compatibility` reports SMC metadata, not proof of physical LED behavior. M1–M4 Apple Silicon Mac mini/Studio models are recognized by identifier and require the complete LED key signature. **Untested models require** `--accept-untested-model` on write or installation commands. For unknown future model IDs, the tool additionally verifies Apple Silicon hardware, the Mac mini/Studio product family reported by macOS, a full SMC key signature, and plausible initial LED state. The flag never enables Intel or unrelated Mac families.

Steady amber and white brightness have been physically verified on the M1 mini and M4 Max Studio. Flashing modes have only been tested on the M1 mini.

**Intel Mac mini 2018 (`Macmini8,1`) has separately verified on/off/full-white control.** Its `LSLN=2F FF` differs from Apple Silicon, and it lacks channel telemetry. Physical tests of `LSLN` values `20 FF`, `40 FF`, and `2F 64` produced **no visible change**, even though `LSPV` followed these changes. See the Intel section above: selected dim levels are hardware-verified; experimental custom 0–255 manual brightness is available, while amber commands and installation remain disabled on Intel.

**Intel multi-test workflow:** `--intel-suite` runs three 2-second probes on the first and second bytes in order: `2F FF → 20 FF`, `2F FF → 40 FF`, and `2F FF → 2F 64`. It restores and verifies `2F FF` after **each** test and aborts if restoration fails. `--intel-probe first|second <decimal-value>` lets you select additional probes without rebuilding; first-byte values are limited to **32–64**. `--intel-snapshot` reads related SMC keys without writing. Watch the LED during each stage; SMC readback alone does not prove any visual change.

**Warning:** The old Intel `LSLN` experiments are investigative, not validated brightness controls. The new Intel `LSOO`/`LSRB` state commands have been physically verified on one unit, not across all firmware versions. All undocumented SMC writes carry recovery risks.

For an untested Apple Silicon Mac mini or Mac Studio (including newer generations):

```sh
sudo ./smcled --white 100 --accept-untested-model
sudo ./smcled --install-auto 300 --accept-untested-model
```

## Notes

- Startup recovery retries SMC initialization and LED writes together (up to 15 attempts), rather than giving up before the first check.
- Requires `sudo` to change the LED; previews and status do not.
- The tested Apple Silicon SMC controls cannot blend white and amber simultaneously; the Intel 2018 amber path remains unverified.
- **Sleep resets the LED to fixed white at 255** on the tested Apple Silicon Mac mini. No wake listener is installed; after wake, the next scheduled check reapplies the correct state. Restoration is not necessarily immediate.
- See [research.md](research.md) for SMC details and hardware tests.

## License

MIT — see [LICENSE](LICENSE).
