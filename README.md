# smcled

Control the **status LED** of supported Mac mini and Mac Studio computers from Terminal. On verified Apple Silicon models, set white/amber brightness (0–255), select blinking patterns, or automate sunrise/sunset transitions. On the 2018 Intel T2 Mac mini, use the independently verified off/full-white/system-default states; adjustable brightness and amber remain under investigation.

Written in Swift using AppleSMC/IOKit. No third-party dependencies, SIP changes, or internet connection required.

**Hardware verified:** M1 Mac mini (`Macmini9,1`) and M4 Max Mac Studio (`Mac16,9`) for manual white brightness and steady amber; 2018 Intel T2 Mac mini (`Macmini8,1`) for off, forced full-white, and restoration to normal white. Only those three Intel states are enabled. Other M1–M4 models, and future Apple Silicon Mac mini/Studio models, require explicit experimental acknowledgement.

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
| \`sudo ./smcled --off\` (or \`--intel-off\`) | \`LSOO=0\` | Front LED goes off; \`LSPV=00 00\`, \`LSOF=01\` |
| \`sudo ./smcled --intel-full\` | \`LSOO=1\` | Front LED becomes substantially brighter white; \`LSPV=6B 08\` |
| \`sudo ./smcled --reset\` (or \`--intel-restore\`, \`--white\`) | \`LSRB=0\` | Returns to firmware-controlled normal white with a fade; \`LSPV=14 11\` |
| \`./smcled --intel-led-status\` | Read-only | Prints current Intel LED-related SMC registers |

All three state commands require \`sudo\`, check the \`Macmini8,1\` model and exact SMC metadata/calibration, and confirm the observed SMC output. They are **immediate operations** and do **not** install a daemon or persist a boot preference. On the tested unit, \`LSLN=2F FF\`, \`LSSV=08 6B\`, and \`LS! =00\`; if your unit differs, write commands refuse to run until separately validated. A reported SMC state does not substitute for seeing the physical LED respond.

**Not supported on Intel yet:** \`--white 0...255\`, bare numeric brightness, \`--amber\` and other color modes, \`--install\`, and \`--install-auto\`. Previous \`LSLN\` experiments changed internal \`LSPV\` telemetry but did not visibly dim the LED. Sleep/wake/restart behavior is untested.

### Experimental Intel adjustable brightness

On the tested Intel Mac, writing \`LSLN\` changed the firmware's \`LSPV\` readings but did **not** visibly dim the LED. Changing \`LSLB\` (historically the full-on PWM preset) from \`FF FF\` to \`7F FF\`, followed by \`LSOO=1\`, produced a stable \`LSPV=35 84\`, exactly half the full-on \`6B 08\` value. The user observed two brightness changes (up to test level and down to normal), but **did not yet confirm sub-normal dimming**.

To investigate brightness lower than normal, a separately gated experiment uses \`LSLB=10 00\`, predicted to produce PWM around \`06 D0\` (below normal \`14 11\`). This is a prediction; the physical effect remains unknown.

\`\`\`sh
swiftc -O smcled-intel-lsoo-probe.swift -framework IOKit -o intel-sil-probe
sudo ./intel-sil-probe --test-low-dim --confirm-hardware-test
\`\`\`

Each test requires the observed baseline, applies \`LSOO=1\` for only two seconds, restores \`LSLB=FF FF\` **before** \`LSRB=0\`, and polls for return to normal-white telemetry. No arbitrary brightness inputs or persistent Intel dimming are enabled.

### Experimental Intel amber/other-mode candidates

**No amber state has been physically verified on the Intel 2018 mini.** The initial \`LSSB=04 00\` candidate produced neither a visible change nor an \`LSPV\` change on the tested machine.

The J174 MacEFI boot-signalling routine referenced two \`LSSB\` payloads, \`00 00\` and \`01 00\`, in conjunction with \`LSCS\`. However, the Intel mini does **not** expose \`LSCS\` to macOS, and those payloads are **not** independently identified as amber/color settings. Two further payloads, \`08 00\` and \`09 00\`, produce different amber flash patterns on the M1 mini; their Intel behavior is unknown.

The standalone Intel probe offers **separate** opt-in tests (never a color sweep or an automatic suite):

| Command | \`LSSB\` payload | Evidence / expectation |
|---|---|---|
| \`--test-amber\` | \`04 00\` | M1 steady amber; already ineffective on Intel |
| \`--test-amber-fw1\` | \`01 00\` | Seen in J174 EFI boot-signalling code; output unknown |
| \`--test-amber-fw0\` | \`00 00\` | Seen in J174 EFI boot-signalling code; output unknown |
| \`--test-amber-blink\` | \`08 00\` | M1 single amber flash; output unknown on Intel |
| \`--test-amber-double\` | \`09 00\` | M1 double amber flash; output unknown on Intel |

\`\`\`sh
./intel-sil-probe --snapshot
sudo ./intel-sil-probe --test-amber-fw1 --confirm-hardware-test
# Evaluate results before trying a different value:
sudo ./intel-sil-probe --test-amber-fw0 --confirm-hardware-test
\`\`\`

Each command requires the verified normal-white baseline, issues **one** bounded two-second SMC experiment, samples \`LSPV\` and \`LSOF\`, attempts restoration with \`LSRB\`, and checks the original PWM. Do **not** run consecutive tests if there is any unexpected LED state or restoration failure. A correct SMC readback is not proof of an amber color; observe the LED directly.

As with all undocumented SMC writes, a crash, power loss or unexpected firmware response can prevent restoration. Nothing is enabled in regular \`smcled --amber\` on Intel until physically validated. This investigation uses independent historical SMC documentation and the J174 EFI image, with **no LuxMini code or private profiles**.

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

**Intel Mac mini 2018 (`Macmini8,1`) has separately verified on/off/full-white control.** Its `LSLN=2F FF` differs from Apple Silicon, and it lacks channel telemetry. Physical tests of `LSLN` values `20 FF`, `40 FF`, and `2F 64` produced **no visible change**, even though `LSPV` followed these changes. See the Intel section above for the supported three-state interface; numeric dimming, normal amber commands, and installation remain disabled on Intel.

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
