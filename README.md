# smcled

Control the **white and amber status LED** of the **M1 Mac mini** from Terminal. Set brightness (0–255), select a color or blinking pattern, or automatically adjust the LED around sunrise and sunset.

Written in Swift using AppleSMC/IOKit. No third-party dependencies, SIP changes, or internet connection required.

**Hardware verified:** Mac mini (M1, 2020), `Macmini9,1` (j274). Other models can be inspected but are not yet enabled for LED control.

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
sudo ./smcled --test-brightness 100 --confirm-hardware-test
```

`--compatibility` identifies a **verified**, **full key-set candidate**, **brightness-register candidate**, or **unsupported** interface. A candidate is **not** proof that the physical LED works. The optional brightness test writes only `LSLN` for 2 seconds and restores its original value; observe the LED to confirm. It does not alter the installed configuration. No automatic installation or amber switching is enabled on unverified hardware.

Preliminary SMC checks: `Mac16,9` (Mac Studio M4 Max) matches all M1 keys; `Macmini8,1` (2018 Mac mini) has `LSLN`, `LSSB` and `LSRB` but no `LSCS`/`LS0P`/`LS1P` telemetry. **Neither has been physically validated.**

## Notes
- Requires `sudo` to change the LED; previews and status do not.
- The tested SMC controls cannot blend white and amber simultaneously.
- **Sleep resets the LED to fixed white at 255** on the tested Mac mini. No wake listener is installed; after wake, the next scheduled check reapplies the correct state. Restoration is not necessarily immediate.
- See [research.md](research.md) for SMC details and hardware tests.

## License

MIT — see [LICENSE](LICENSE).
