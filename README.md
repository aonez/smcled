# smcled

Control the **white and amber status LED** of Apple Silicon **Mac mini and Mac Studio** computers from Terminal. Set brightness (0–255), select a color or blinking pattern, or automatically adjust the LED around sunrise and sunset.

Written in Swift using AppleSMC/IOKit. No third-party dependencies, SIP changes, or internet connection required.

**Hardware verified:** M1 Mac mini (`Macmini9,1`) and M4 Max Mac Studio (`Mac16,9`) for manual white brightness and steady amber. Other M1–M4 models, and future Apple Silicon Mac mini/Studio models, require explicit experimental acknowledgement.

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

**Intel Mac mini 2018 (`Macmini8,1`) remains experimental:** its `LSLN=2F FF` differs from Apple Silicon, and it lacks channel telemetry. Physical tests of `LSLN` values `20 FF`, `40 FF`, and `2F 64` produced **no visible LED change**; the original `2F FF` was restored after each. The register's meaning remains unknown, so normal commands and installation remain disabled on Intel.

**Intel multi-test workflow:** `--intel-suite` runs three 2-second probes on the first and second bytes in order: `2F FF → 20 FF`, `2F FF → 40 FF`, and `2F FF → 2F 64`. It restores and verifies `2F FF` after **each** test and aborts if restoration fails. `--intel-probe first|second <decimal-value>` lets you select additional probes without rebuilding; first-byte values are limited to **32–64**. `--intel-snapshot` reads related SMC keys without writing. Watch the LED during each stage; SMC readback alone does not prove any visual change.

**Warning:** Neither first-byte nor second-byte experiments produced a visible LED change on the tested Intel mini. These are writes to an undocumented controller, not proven brightness commands. Run only with physical access; a crash or power failure can prevent restoration.

For an untested Apple Silicon Mac mini or Mac Studio (including newer generations):

```sh
sudo ./smcled --white 100 --accept-untested-model
sudo ./smcled --install-auto 300 --accept-untested-model
```

## Notes

- Startup recovery retries SMC initialization and LED writes together (up to 15 attempts), rather than giving up before the first check.
- Requires `sudo` to change the LED; previews and status do not.
- The tested SMC controls cannot blend white and amber simultaneously.
- **Sleep resets the LED to fixed white at 255** on the tested Mac mini. No wake listener is installed; after wake, the next scheduled check reapplies the correct state. Restoration is not necessarily immediate.
- See [research.md](research.md) for SMC details and hardware tests.

## License

MIT — see [LICENSE](LICENSE).
