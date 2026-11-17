# M1 Mac mini status LED research: dimming, amber, AppleSMC and persistence

**Research log and reproduction guide**  
**Date:** 31 October 2026  
**Tested machine:** Mac mini (M1, 2020), `Macmini9,1`, Apple board `j274`  
**CLI:** `smcled`, Swift/IOKit, culminating in v6  
**Scope:** Everything established during this session about controlling the front status indicator light (SIL), including brightness, white/amber selection, flashing patterns, firmware research, and boot-time persistence.

> **Evidence convention:** **Confirmed on hardware** means observed on the actual M1 Mac mini. **Confirmed in uploaded binary/source** means checked against files from this session. **Inferred/reverse-engineered** identifies a plausible internal interpretation that is not an Apple-documented API. **Not tested** marks remaining uncertainties. Apple does not provide or guarantee this SMC control interface for end users.

## 1. Executive summary

We established that the front status LED on the M1 Mac mini can be controlled **from macOS user space using IOKit and the `AppleSMC` service**, with root privileges. A custom kext, disabled SIP, an NVRAM setting, and firmware modification are **not required**.

- **White LED brightness:** writing AppleSMC key `LSLN` (`ui16`, read/write) controls brightness. Our CLI represents brightness as an integer `0–255` and writes the byte twice: `0` → `00 00` (off); `10` → `0A 0A` (very dim); `32` → `20 20` (dim); `255` → `FF FF` (factory brightness). **Confirmed on hardware.**
- **Amber LED:** AppleSMC behavior key `LSSB` (2-byte, write-only) accepts experimentally verified modes: `04 00` = **steady amber**; `08 00` = **one amber flashing pattern**; `09 00` = **double-flash amber pattern**. **Confirmed on hardware.**
- **Amber brightness:** after selecting an amber mode, writing `LSLN` changes steady amber brightness; values `10` and `50` were physically tested. **Confirmed on hardware.**
- **Restore white:** send `00` to `LSRB` (1-byte write-only), wait for the asynchronous restoration of white/channel 0, then set `LSLN` as desired. **Confirmed on hardware.**
- **Persistence:** a direct SMC brightness change **did not survive a normal restart or a macOS update**. `smcled` v6 therefore installs a one-shot LaunchDaemon and stores the desired mode and brightness. Startup restoration of all amber variants and sleep/wake behavior were **not conclusively verified in the transcript**.
- **No mixing demonstrated:** the normal firmware LED behavior mechanism drives one active LED channel at a time. Simultaneous white + amber is **not demonstrated**.

### Fast reproduction on the tested model

With the v6 `smcled.swift` source available:

```sh
swiftc -O smcled.swift -framework IOKit -o smcled
./smcled model                 # Macmini9,1
./smcled info LSLN
sudo ./smcled --white 10       # Dim white
sudo ./smcled --amber 10       # Steady dim amber
sudo ./smcled --amber-blink 50 # Amber flashes
sudo ./smcled --amber-double 50
sudo ./smcled --reset          # Normal white, 255
```

To install the CLI and reapply settings at boot:

```sh
sudo ./smcled --install amber 10
smcled --status                # Does not need sudo
sudo smcled --uninstall        # Restore normal LED and clean up installation
```

**This is a device- and firmware-specific result, not a claim that every Mac or every firmware release behaves identically.**

## 2. How the discovery happened

### 2.1 Initial question: NVRAM, kext, or software?

The question was whether the M1 Mac mini's front white power LED could be dimmed or disabled. macOS offers no normal system preference for this. The investigation chose **IOKit → AppleSMC** instead of NVRAM or a kernel extension. An existing third-party application, LuxMini, helped suggest that AppleSMC-based status-light PWM control was feasible, but its model-specific key profile was not used in our custom tool.

We built a single-file Swift CLI which opens the `AppleSMC` IOKit service, retrieves key metadata, enumerates keys, reads key values, and supports explicitly authorized writes. The first test version was deliberately read-only for discovery.

### 2.2 SMC enumeration: 1,008 keys

```sh
./smcled model
./smcled scan
./smcled scan --all
```

The machine reported:

```text
Macmini9,1
SMC keys: 1008
```

The first `scan` listed writable two-byte keys. The interesting LED-family candidates were:

```text
LSLB  size=2  type="ui16"  attrs=0xC0
LSLF  size=2  type="ui16"  attrs=0xC0
LSLN  size=2  type="ui16"  attrs=0xC0
LSSB  size=2  type="hex_"  attrs=0x50
```

We subsequently used `scan --all` to enumerate the full `LS*` family, including one-byte keys and read-only telemetry. The complete 20-key set is reproduced in section 4.

### 2.3 Read-only inspection isolated the brightness key

```sh
./smcled info LSLB
./smcled read LSLB
./smcled info LSLF
./smcled read LSLF
./smcled info LSLN
./smcled read LSLN
```

Results before changing brightness:

```text
LSLB  size=2  type="ui16"  attrs=0xC0  readable=true  writable=true
LSLB  type="ui16"  raw=FF FF
LSLF  size=2  type="ui16"  attrs=0xC0  readable=true  writable=true
LSLF  type="ui16"  raw=00 00
LSLN  size=2  type="ui16"  attrs=0xC0  readable=true  writable=true
LSLN  type="ui16"  raw=FF FF
```

Historical SMC naming suggested `LSLN` was the normal light level. We did **not** assume a name was proof: we ran a reversible hardware test.

### 2.4 First physical brightness test

```sh
sudo ./smcled test LSLN --confirm-led-key --mode vv
```

The initial test saved `FF FF`, wrote `[32,32]` (`20 20`), wrote `[192,192]` (`C0 C0`), then restored `FF FF`. The LED visibly dimmed and returned toward normal. The intermediate `192` and final `255` were not visually easy to distinguish.

We then confirmed individual values:

| CLI value | Actual `LSLN` bytes | Visual result | Evidence |
|---:|---|---|---|
| `0` | `00 00` | Off | Observed |
| `10` | `0A 0A` | Very dim | Observed |
| `32` | `20 20` | Dim | Observed |
| `255` | `FF FF` | Normal/full white | Observed |

Example from the v6 CLI:

```sh
sudo smcled --white 10
sudo smcled --off
sudo smcled --reset
```

**Important:** `LSLN` is a two-byte SMC entry. The tool's `0–255` interface repeats a single input byte (`10` becomes `0x0A0A`). This does **not** establish that perceived brightness is linear or calibrated in percent. We deliberately did not extrapolate all possible 16-bit values.

### 2.5 Persistence test: SMC values are reset

We left `LSLN` at `10` and performed a macOS update. After the update:

```text
LSLN  raw=FF FF
```

A subsequent **normal restart** also restored the default. Therefore one-off writes do not provide persistence on the tested machine. This motivated a LaunchDaemon which reapplies the preference at startup; there is no evidence that storing a special NVRAM value would help.

### 2.6 Finding the second LED channel

Apple documents both white status illumination and amber illumination during firmware recovery. We expanded the SMC scan to the entire `LS*` family and compared registers at different white brightness levels.

Relevant readings:

| White setting | `LS0P` after settling | `LS1P` |
|---:|---|---|
| 10 | `05 4C` | `00 00` |
| 255 | `87 1C` | `00 00` |
| 0 | `00 00` | `00 00` |

At brightness `0`, one **immediate** read returned `LS0P=04 F9`; after allowing the transition to settle, eight successive one-second samples returned `00 00`. The transient was not evidence of light remaining on.

The stable numeric values were strongly proportional to the white brightness setting:

- `0x054C` = 1,356 at input `10`.
- `0x871C` = 34,588 at input `255`.
- Ratio ≈ 25.51, close to input ratio `255/10 = 25.5`.

Thus `LS0P` **tracks** the white LED's actual output/brightness state. At this stage we considered `LS1P` a candidate second channel, **not yet proved to be amber**.

### 2.7 Device-tree inspection did not give a LED mapping

We inspected `ioreg` for LED and PWM devices. A wide grep produced enormous irrelevant output because patterns accidentally matched words such as `enabled` and `polled`.

A focused search found:

```text
pwm@35040000
compatible = <"pwm,t8101","pwm,s5l8920x">
device_type = <"pwm">
```

The node exposed a 16 KiB device-memory region and was matched by `AppleS5L8920XPWM` (`com.apple.driver.AppleS5L8920XPWM`). The node did **not** identify a front-LED connection or an amber output. The later SMC firmware analysis revealed a different, higher-level LED control mechanism, and **no conclusion about the `pwm@35040000` node driving the status light was established**.

### 2.8 Extracting and analyzing the embedded SMC firmware

The key research breakthrough came from the **LLB / iBoot1** image, rather than the normal macOS `AppleSMC` driver or the iBoot2 image.

Files supplied from the tested firmware:

| File | Bytes | Description |
|---|---:|---|
| `iBoot.j274.RELEASE.im4p` | 532,373 | iBoot2 image, less relevant to SMC implementation |
| `LLB.j274.RELEASE.im4p` | 756,312 | LLB / iBoot1 Image4 payload |
| `LLB.bin` | 1,524,304 | Extracted LLB contents |
| `embedded-firmware.bin` | 395,904 | Decoded embedded coprocessor firmware; identified as AppleSMC |

The decompressed `LLB.bin` contained an embedded LZFSE stream: four blocks beginning at file offset **`0xED384`** and ending at **`0x117CA3`** (exclusive). The compressed stream size was **174,367 bytes**. After decoding, the resulting firmware had the following identifying strings:

```text
AppleSMCFirmware_H13-7372.41.4.j274.REL
RTKit_armv8_chinook_Oz_flto-3514.41.1.release
```

It also contained internal path strings such as `smc/smcmain.cpp`, `smc/comms.cpp`, `smc/sys_mgmt.cpp` and `smc/pmu_v2.cpp`.

The LED keys were initially invisible to plain-text searches because the four-character SMC key codes appear in **reverse byte order** in this firmware's key table: e.g. `LS0P` is stored as bytes `50 30 53 4C` (`P0SL`). This led us to the actual key entries and their referenced data locations.

### 2.9 Firmware-supported amber modes: experiment and confirmation

The firmware analysis indicated separate LED channel handling, behavior presets, and a mechanism that normally activates just one channel. We selected candidate presets by analyzing the binary, **not** by blindly writing every possible value to `LSSB`.

Short reversible tests used the two-byte `LSSB` command followed by `LSRB` restoration:

| `LSSB` value | Channel | Actual physical observation |
|---|---|---|
| `04 00` (mode 4) | 1 | **Steady amber** |
| `08 00` (mode 8) | 1 | Amber flashing, approximately one flash per second |
| `09 00` (mode 9) | 1 | Two rapid amber flashes, then a pause |

The `mode 8` log showed `LSCS=01`, `LS0P=00 00`, and `LS1P` alternating between `00 00` and `1C 8E`.

The `mode 4` log was decisive:

```text
Sending LSSB predefined mode 4 (04 00); 3-second visual test...
+0.5s  LSCS=01  LS0P=00 00  LS1P=1C 8E
+1.0s  LSCS=01  LS0P=00 00  LS1P=1C 8E
+1.5s  LSCS=01  LS0P=00 00  LS1P=1C 8E
+2.0s  LSCS=01  LS0P=00 00  LS1P=1C 8E
+2.5s  LSCS=01  LS0P=00 00  LS1P=1C 8E
+3.0s  LSCS=01  LS0P=00 00  LS1P=1C 8E
Restoring saved LED state via LSRB...
Final LSCS: 00, LS1P: 00 00, LSLN: FF FF
```

The front LED was visibly **fixed amber** during this test and returned to fixed white afterward. The combination of physical observation and register telemetry provides strong confirmation that SMC channel 1 drives amber and channel 0 drives white.

### 2.10 Restoring the normal LED: an asynchronous operation

The first amber test restored the LED to white visually, but an immediate read still reported `LSCS=01`. Three seconds later, readings were:

```text
LSCS  raw=00
LS0P  raw=28 88
LS1P  raw=00 00
```

Therefore `LSRB` restoration is **asynchronous**. v6 improves reliability by polling until `LSCS=00` and `LS1P=00 00` before applying the requested white brightness. This is a best-effort software safety measure, not a guarantee against a power failure or SMC malfunction.

### 2.11 Amber is dimmable too

The v5 experiment used `LSSB=04 00` to select steady amber, then wrote a different `LSLN` value. The hardware test confirmed that **amber becomes dimmer at `10` and brighter at `50`**.

That established `LSLN` as a brightness input affecting **both** tested steady-light modes, not just white. The final v6 CLI selects the desired amber behavior first and then, if specified, writes the duplicated brightness bytes to `LSLN`.

The user subsequently reported the v6 commands working, including color selection. Exact perceived brightness curves, flashing-mode PWM characteristics, and cross-model compatibility have not been separately measured.

## 3. The AppleSMC/IOKit access mechanism

The single-file Swift implementation uses system IOKit APIs:

1. `IOServiceGetMatchingService(..., IOServiceMatching("AppleSMC"))`
2. `IOServiceOpen` on that service.
3. `IOConnectCallStructMethod` using selector **`2`**, an **80-byte** request and response structure.
4. Command IDs: **`5`** = read key, **`6`** = write key, **`8`** = enumerate key by index, **`9`** = get key information.

The v6 source models the 80-byte protocol buffer as follows:

| Offset | Field |
|---:|---|
| `0` | 4-byte SMC key identifier |
| `28` | Data size (`UInt32`) |
| `32` | Data type (`UInt32`) |
| `36` | Attributes (`UInt8`) |
| `40` | SMC operation result (`UInt8`) |
| `42` | Command (`UInt8`) |
| `44` | Key index for enumeration |
| `48` | Key payload (up to 32 bytes) |

The response error code **`0x84`** was observed when requesting some unavailable keys (`LSPV`, `LSSV`); this was an SMC refusal, not a reason to try blind writes. The attributes observed in this experiment are interpreted in the CLI as read bit `0x80` and write bit `0x40`; therefore `0xC0` = both read and write, `0x80` = read-only, and `0x50` = writable but not readable by these methods.

All known-color write commands in v6 check the model string `Macmini9,1` and the expected key sizes, types and access permissions before writing. **Root privileges are used for writes.** Read-only `model`, `scan`, `read`, `info` and installation status are designed to run without `sudo`.

## 4. Complete `LS*` key inventory from the tested SMC

This is the **actual** output of `scan --all` on the M1 Mac mini, reduced to the relevant fields:

| Key | Size | Type | Attributes | Notes |
|---|---:|---|---|---|
| `LS! ` | 1 | `ui8 ` | `0xC0` | Purpose undetermined |
| `LS0C` | 2 | `ui16` | `0xC4` | Channel-0-related; **do not blindly write** |
| `LS0P` | 2 | `ui16` | `0x80` | Tracks white output |
| `LS0S` | 2 | `ui16` | `0xC4` | Channel-0-related; meaning not fully established |
| `LS1C` | 2 | `ui16` | `0xC4` | Channel-1-related; **do not blindly write** |
| `LS1P` | 2 | `ui16` | `0x80` | Tracks amber output |
| `LS1S` | 2 | `ui16` | `0xC4` | Channel-1-related; meaning not fully established |
| `LSB!` | 1 | `flag` | `0xC0` | Purpose undetermined |
| `LSCS` | 1 | `ui8 ` | `0x90` | Active/selected channel after transition (`00` white, `01` amber) |
| `LSFD` | 6 | `hex_` | `0xD0` | Fade-related candidate from historical nomenclature |
| `LSFU` | 6 | `hex_` | `0xD0` | Fade-related candidate from historical nomenclature |
| `LSLB` | 2 | `ui16` | `0xC0` | Read `FF FF`; historical light brightness parameter |
| `LSLF` | 2 | `ui16` | `0xC0` | Read `00 00`; historical off brightness parameter |
| `LSLN` | 2 | `ui16` | `0xC0` | **Verified controllable brightness** |
| `LSOF` | 1 | `flag` | `0x80` | Read `00` under normal white operation |
| `LSOO` | 1 | `flag` | `0x50` | Write-only LED-related function; not used |
| `LSRB` | 1 | `flag` | `0x50` | **Verified white/state restore** |
| `LSSB` | 2 | `hex_` | `0x50` | **Verified predefined LED behavior selector** |
| `LSSE` | 1 | `flag` | `0xC0` | Read `01`; semantics not established |
| `LSUP` | 1 | `ui8 ` | `0x50` | Write-only update-related function; not used |

Note that `LS! ` includes a trailing ASCII space. A key's name or write permission alone does not make it safe to modify.

### Other read-only observations before the amber tests

With white at brightness `10`:

```text
LS0C  FF FF     LS0P  05 4C     LS0S  1C 87
LS1C  FF FF     LS1P  00 00     LS1S  2F 5F
LSCS  00        LSSE  01        LSOF  00
```

With white at `255`, the same snapshot changed `LS0P` to `87 1C` and left the other listed values unchanged.

## 5. Reproduce the firmware extraction and key-table discovery

**Only needed to reproduce the reverse engineering.** If you just want LED control, build the Swift CLI in section 6 instead.

### 5.1 Obtain the matching LLB image

The on-device search found the iBoot2 image but not LLB:

```sh
sudo find /System/Volumes/Preboot -type f \
  \( -name 'LLB.j274.RELEASE.im4p' -o -name 'iBoot.j274.RELEASE.im4p' \) \
  2>/dev/null
```

We retrieved a matching `LLB.j274.RELEASE.im4p` from Apple's macOS restore firmware, using **blacktop/ipsw**. The version in this session was macOS `27.2`; for other systems choose the firmware matching that machine/build.

```sh
brew install blacktop/tap/ipsw
mkdir -p "$HOME/Desktop/smc-amber"
ipsw download ipsw --macos --version 27.2 \
  --pattern 'LLB\.j274\.RELEASE\.im4p$' \
  --output "$HOME/Desktop/smc-amber"
```

**CLI-version note:** Earlier in the conversation a command included `--flat` on `ipsw download ipsw`. Current command documentation describes `--pattern` and `--output` there but does **not** list `--flat`; the command above omits that flag. Check `ipsw download ipsw --help` if flags change.

### 5.2 Extract and decompress the LLB IM4P payload

```sh
ipsw img4 im4p extract \
  --output "$HOME/Desktop/smc-amber/LLB.bin" \
  "$HOME/Desktop/smc-amber/LLB.j274.RELEASE.im4p"
```

The actual `LLB.bin` obtained in our session was **1,524,304 bytes**.

### 5.3 Extract the LZFSE stream inside LLB

From the directory containing `LLB.bin`:

```sh
python3 - <<'PY'
from pathlib import Path

blob = Path('LLB.bin').read_bytes()
start = blob.index(b'bvx2')
end = blob.index(b'bvx$', start) + 4
stream = blob[start:end]
assert stream.count(b'bvx2') == 4, 'Unexpected block layout'
Path('embedded-firmware.lzfse').write_bytes(stream)
print(f'Compressed bytes: {len(stream):,}')
PY
```

For **this particular LLB**, the result was **174,367 bytes**. These offsets and assumptions are image-specific; do not treat the first `bvx2`/`bvx$` pair as a universal extractor for all LLB versions.

### 5.4 Decode LZFSE

```sh
brew install lzfse
lzfse -decode -i embedded-firmware.lzfse -o embedded-firmware.bin
ls -lh embedded-firmware.bin
```

Expected **for this exact input**: **395,904 bytes**.

### 5.5 Identify the embedded AppleSMC image

```sh
strings -a embedded-firmware.bin | \
  grep -E 'AppleSMCFirmware|RTKit_armv8|smcmain.cpp|smc/comms.cpp'
```

Expected version markers:

```text
AppleSMCFirmware_H13-7372.41.4.j274.REL
RTKit_armv8_chinook_Oz_flto-3514.41.1.release
```

### 5.6 Locate the LED key entries in the binary

The keys are stored in **reversed byte order**, not as plain four-character strings. This read-only script shows their entry offsets:

```sh
python3 - <<'PY'
from pathlib import Path
fw = Path('embedded-firmware.bin').read_bytes()
keys = ['LS0C','LS0P','LS0S','LS1C','LS1P','LS1S',
        'LSCS','LSLN','LSOO','LSRB','LSSB']
for key in keys:
    pos = fw.find(key.encode('ascii')[::-1])
    print(f'{key}: {f"0x{pos:X}" if pos >= 0 else "not found"}')
PY
```

Verified entry offsets for this exact firmware:

| Key | File offset | Referenced data address in the entry (where applicable) |
|---|---|---|
| `LS0C` | `0x51F24` | `0x5BAA4` |
| `LS0P` | `0x51F36` | `0x6A814` |
| `LS0S` | `0x51F48` | `0x6A810` |
| `LS1C` | `0x51F5A` | `0x5BAA6` |
| `LS1P` | `0x51F6C` | `0x6A816` |
| `LS1S` | `0x51F7E` | `0x6A812` |
| `LSCS` | `0x51FA2` | — |
| `LSLN` | `0x51FFC` | — |
| `LSOO` | `0x52020` | — |
| `LSRB` | `0x52032` | — |
| `LSSB` | `0x52044` | — |

The entries are 18 bytes apart in the relevant table and encode key name, attributes, size, data type and a data pointer or handler. The `0x6A8xx` references are **firmware memory addresses**, not file offsets into the 395,904-byte image.

### 5.7 What the ARM64 analysis suggested

The session's disassembly analysis identified a two-channel LED update routine (reported around `0x11FC4`) and PWM output routine (reported around `0x120A4`), with firmware presets referring to channel 0 or 1. Those precise routine interpretations are **reverse-engineering findings**, not Apple documentation; they should be independently rechecked if porting the work to another firmware revision.

The earlier disassembly also reported separate memory-mapped PWM output bases, `0x23ED40000` (channel 0) and `0x23ED44000` (channel 1), and a fixed-output channel-1 preset for mode 4. Those addresses are **research leads, not independently validated hardware-register documentation**; in particular, they should not be confused with the unrelated `pwm@35040000` node seen in `ioreg`. Do not write directly to either address.

Our key **behavioral** conclusions have much stronger evidence: mode 4 produced steady physical amber with nonzero `LS1P`, and mode 8/9 produced the expected different patterns. We **did not** use raw MMIO register writes, patch the firmware, or prove that both channels can be lit simultaneously.

## 6. Reproduce the v6 Swift command-line tool

The last fully integrated source file from this session is `smcled-v6/smcled.swift` in `smcled-m1-amber-v6.zip`. It is a standalone Swift source file with Foundation, Darwin and IOKit on macOS; no third-party code libraries or kernel components are required.

### 6.1 Build

```sh
unzip smcled-m1-amber-v6.zip
cd smcled-v6
swiftc -O smcled.swift -framework IOKit -o smcled
./smcled model
./smcled info LSLN
```

Expected model: `Macmini9,1`. If it is a different model, the known-color write commands intentionally refuse to run. The binary from this session was **type-checked on Linux**; actual compilation and testing of the macOS IOKit/launchd code was performed by the user on the tested Mac, who subsequently reported all v6 LED controls working.

### 6.2 Immediate control (root required; does not save boot preference)

```sh
sudo ./smcled 10                # Shortcut: white brightness 10
sudo ./smcled --white 10        # White brightness 10
sudo ./smcled --white 255       # White maximum
sudo ./smcled --amber 10        # Steady amber, brightness 10
sudo ./smcled --amber 50        # Steady amber, brightness 50
sudo ./smcled --amber-blink 50  # One-flash amber pattern
sudo ./smcled --amber-double 50 # Double-flash amber pattern
sudo ./smcled --off             # LED off
sudo ./smcled --reset           # Normal white 255
```

All commands that take brightness validate **integer 0–255**. `--white`, `--amber`, `--amber-blink` and `--amber-double` may be given **without a number**; in that case v6 leaves the current `LSLN` value unchanged.

For white, v6 calls `LSRB` to restore normal channel selection before applying `LSLN`. For amber it writes the verified `LSSB` preset before applying `LSLN`.

### 6.3 Three-second reversible experiments

```sh
sudo ./smcled --white 255
sudo ./smcled --test-amber 4      # Steady amber, then restore white
sudo ./smcled --test-amber 8      # Single flashing, then restore white
sudo ./smcled --test-amber 9      # Double flashing, then restore white
sudo ./smcled --test-amber-brightness 10
```

The tests read telemetry and restore the saved `LSLN` after requesting normal white with `LSRB`. **Restoration is best effort:** terminating the process or losing power mid-test may prevent cleanup.

### 6.4 Install in a global command path, persist settings on boot

```sh
sudo ./smcled --install amber 10
smcled --status
```

The installer copies itself to a root-owned support directory and links it into `/usr/local/bin`, so the program works as `smcled` without `./` from any working directory. **Writes and installation still require `sudo`; read-only `--status` does not.** It also acts as the updater: compile a new version and rerun `sudo ./smcled --install ...`.

Alternate settings:

```sh
sudo smcled --install white 10
sudo smcled --install amber 10
sudo smcled --install amber-blink 50
sudo smcled --install amber-double 50
sudo smcled --install 10    # Backward-compatible alias for white 10
```

`--install amber` with no number retains the **saved** brightness, or defaults to `255` on a first installation. This differs from a non-install command with no number, which retains the **current** hardware `LSLN` value.

Installed layout:

| Path | Role |
|---|---|
| `/Library/Application Support/smcled/smcled` | Root-owned installed binary |
| `/Library/Application Support/smcled/brightness` | Saved decimal brightness |
| `/Library/Application Support/smcled/mode` | Saved mode (`white`, `amber`, `amber-blink`, `amber-double`) |
| `/Library/LaunchDaemons/dev.smcled.brightness.plist` | Root LaunchDaemon |
| `/usr/local/bin/smcled` | Symlink to installed binary |

The LaunchDaemon runs the same executable once at startup with `--apply-installed`. v6 waits **4 seconds** and then performs up to **15 attempts**, with **2 seconds between failed attempts**, in case `AppleSMC` is initially unavailable. It is **not a continuously running daemon** and does not automatically reapply settings on wake from sleep.

**Do not infer from the code alone that every reboot or macOS update has been verified.** The direct SMC write was confirmed to reset on reboot; the boot-time reapplication code is the solution, but long-term reliability still depends on launchd, permissions, system initialization order and firmware compatibility.

### 6.5 Status, diagnostics, uninstall

```sh
smcled --status
smcled read LSLN
smcled read LSCS
smcled read LS0P
smcled read LS1P
smcled scan --all
sudo smcled --uninstall
```

`--uninstall` stops the managed launchd job, attempts to restore normal white at 255, removes the managed preferences, installed executable, plist and the matching `/usr/local/bin/smcled` symlink. It checks ownership and refuses to overwrite or delete unrelated content in its managed paths.

**A temporary manual change is not a saved preference:** `sudo smcled --amber 10` changes the live LED; `sudo smcled --install amber 10` changes the setting restored at startup. `sudo smcled --reset` similarly restores white immediately but leaves any installed boot preference untouched.

## 7. Safety and operational boundaries

- **No kext, SIP weakening, NVRAM tweaks, or firmware patching.** All normal control is a root-authorized IOKit user-space request to AppleSMC.
- **Undocumented API.** The `LSSB`/`LSRB` behavior protocol is based on this firmware and the hardware experiments; macOS or firmware updates may change it.
- **Avoid arbitrary SMC writes.** Keys such as `LS0C`, `LS1C`, `LS0S`, `LS1S`, `LSUP`, or unexplored `LSSB` modes should not be used without new analysis and a restoration plan. The legacy generic `smcled led` function exists for research but is not a recommendation to probe arbitrary keys.
- **Brightness `10` and longevity.** A lower PWM setting should generally reduce average LED output/power and is not expected to increase LED wear, but Apple has not published this Mac's LED electrical ratings or officially supported `LSLN` range. Long-term hardware safety is a reasonable engineering expectation, **not experimentally proven over years**.
- **Power draw.** No electrical measurements were made. Whether amber consumes more or less than white at equal CLI values is **unknown**; LED channel forward voltage alone is insufficient without actual drive current.
- **Amber does not itself put the Mac in DFU.** In this experiment, amber is an LED display setting while macOS continues operating. However, Apple normally uses amber for firmware recovery indications, so deliberately displaying it can be misleading to an observer.
- **Restore after unexpected behavior.** Prefer `sudo smcled --reset` (or the compiled local `sudo ./smcled --reset`); a normal restart previously restored the factory white LED. If an undocumented SMC command causes abnormal behavior, don't assume a user-space restore will always succeed.
- **Privileged installation security.** The installer avoids setuid-root and creates a root-owned service directory and managed `/usr/local/bin` symlink. A system-level job and root-owned executable should still be inspected before installation.

## 8. Remaining questions / future experiments

1. **Firmware update resilience:** A raw SMC write reset during an update. Whether the installed v6 LaunchDaemon restores every chosen amber mode reliably after all types of updates remains to be established.
2. **Sleep/wake:** Does the SMC preserve the mode and brightness through sleep, or will a wake-triggered reapply ever be needed?
3. **Blinking-mode brightness response:** Steady amber brightness was physically verified at 10 and 50; detailed output telemetry for the brightness scaling of the two flashing presets was not recorded in the transcript.
4. **Independent dual-channel illumination:** Normal firmware presets appear to activate white or amber, not both; simultaneous illumination is unproven and unnecessary for the present goal.
5. **Compatibility:** Do the exact `LSSB` presets and key metadata work identically on other Mac minis, SoCs or firmware builds? **Not established.** The v6 CLI deliberately limits writes to `Macmini9,1`.
6. **PWM transfer function:** Which signal mapping makes a requested brightness of 10 produce `LS0P=0x054C`, and what are the physical luminance and power curves? No calibrated measurements were made.

## 9. File provenance and integrity

The following hashes were computed from the actual uploaded files used in this session. They let a future investigator confirm that they are analyzing the **same firmware**, rather than merely a file with the same name.

| Artifact | SHA-256 |
|---|---|
| `LLB.j274.RELEASE.im4p` | `0e63995279ea88b66b527c8bdd89f23d3d944780e119ca0f72b72d1967c09fb5` |
| `LLB.bin` | `b8a202b74349a8173e177367b5cbad904cd684f9ca0543c8fd1371b880e42fa6` |
| `embedded-firmware.lzfse` | `867bbb50ee11033458e46dd9c5a5377be44d92c75dc48c4712638f5e623eeaad` |
| `embedded-firmware.bin` | `648ffa667df03aa37c12f6c3544d446ccca7adee15d544bd5e9a47b649af8292` |
| `iBoot.j274.RELEASE.im4p` | `ce471a510807f4774c2d81b19c2c710d13a356893de47a3ebe0d64080d477a2c` |

Verify locally with:

```sh
shasum -a 256 LLB.bin embedded-firmware.bin
```

### External background and command documentation

These links support the boot architecture, Apple-defined status-light indications and the documented extraction-tool interface. **They do not document the private SMC keys or prove our experiment. Those conclusions came from the actual uploaded firmware and on-device tests.**

- [Apple: Mac computer status indicator light behavior](https://support.apple.com/en-us/102768) — normal white, amber during firmware recovery.
- [Asahi Linux: Apple Silicon boot flow](https://asahilinux.org/docs/fw/boot/) — LLB/iBoot1 versus iBoot2.
- [Asahi Linux: Introduction to Apple Silicon](https://asahilinux.org/docs/platform/introduction/) — firmware and coprocessor background.
- [blacktop/ipsw](https://github.com/blacktop/ipsw) — firmware research and extraction tool.
- [ipsw: IM4P extraction guide](https://blacktop.github.io/ipsw/docs/guides/img4/).
- [ipsw: macOS IPSW download command](https://blacktop.github.io/ipsw/docs/cli/ipsw/download/ipsw/).

## 10. Final result

On the **M1 Mac mini `Macmini9,1`**, a small root-authorized Swift executable can set the front LED to **off, dim white, full white, dim steady amber, bright steady amber, or two amber flashing patterns**, without modifying the kernel, firmware or SIP. The specific key/value discoveries were confirmed in the user's physical experiments, and a reusable `smcled` v6 CLI with a LaunchDaemon was implemented for saved boot preferences.

The **verified control primitives** are concise:

```text
WHITE BRIGHTNESS     Write LSLN = [value, value] (0–255)
STEADY AMBER         Write LSSB = 04 00; then optionally LSLN
AMBER FLASH          Write LSSB = 08 00; then optionally LSLN
AMBER DOUBLE FLASH   Write LSSB = 09 00; then optionally LSLN
RESTORE WHITE        Write LSRB = 00; wait for LSCS=00 and LS1P=00 00
FACTORY WHITE        Restore white; write LSLN = FF FF
```

**The most important caution:** these are **reverse-engineered, model-specific AppleSMC behaviors**, not a public supported Apple LED API. Keep the model guard, metadata checks, root requirement, and safe restore path when reusing or extending the tool.


## v7: Non-destructive dual-channel telemetry diagnostic (subsequently hardware tested)

The CLI now offers `sudo ./smcled --test-dual-channel` on `Macmini9,1`.
It measures whether both `LS0P` (white PWM) and `LS1P` (amber PWM) ever read
nonzero during a verified white -> steady amber -> white mode switch, including
transient samples every 200 ms. It does not try unknown `LS0C`, `LS1C`, `LS0S`,
`LS1S`, `LSFD`, `LSFU` or arbitrary `LSSB` values. It restores the original
white brightness via `LSRB` + `LSLN`, with SIGINT/SIGTERM cancellation support.

**Do not interpret a telemetry overlap as proof that both LED die are visibly
illuminated**. Similarly, an absence of overlap means only that the known mode
switch doesn't mix channels at this sampling resolution: it does not rule out
undocumented independent control. Independent channel brightness and genuine
white/amber cross-fades are not implemented or established.

## November 2026 — sunrise/sunset automation and dual-channel confirmation

- `--test-dual-channel` hardware output on M1 Mac mini showed white `LSCS=00`, `LS0P` active, `LS1P=0000`; steady amber showed `LSCS=01`, `LS0P=0000`, `LS1P` active. No simultaneous PWM output was sampled (200-ms sampling), and there was an abrupt visible color switch. This does not prove undocumented simultaneous-channel control impossible; it only rules it out using the existing verified presets.
- Automatic scheduler was added as an opt-in: read system selected city, calculate solar times, fallback to parsed CoreBrightness solar events, apply target every 300 seconds with `launchd` and `RunAtLoad`.
- The installed diagnostic has a new `--test-zero` to physically confirm `LSLN=00 00` extinguishes both steady modes before relying on fade-through-darkness.
- Offline Swift 6.2 preview checked for Barcelona on Nov 1 2026: sunrise 07:21:45 CET, sunset 17:48:07 CET. Jun 21 2026: sunrise 06:17:28 CEST, sunset 21:27:49 CEST; the late-sunset +3-hour amber-33 event schedules for Jun 22 at 00:27:49 CEST. The automatic fade was later tested on-device and judged visually smooth by the operator.

## November 1, 2026 — on-device automation verification

Tests performed on the M1 Mac mini with the `smcled-auto-sunrise` build:

- `--test-zero`: white and amber each extinguished fully at brightness zero. Readback white `LS0P=00 00 LSLN=00 00`; amber `LS1P=00 00 LSLN=00 00`. Observer reported visible soft changes on white even though this diagnostic uses direct writes, versus hard-on/hard-off changes on amber. This is consistent with, but does not prove, intrinsic white-channel smoothing.
- `--auto-preview`: system preference successfully yielded Barcelona and the expected solar schedule on 2026-11-01. Sunrise 07:21:45 CET, sunset 17:48:07 CET; target amber 255 at 19:09 CET.
- `--auto-check`: user reported a visually pleasing software-managed white→amber fade-through-darkness.
- `--install-auto`: LaunchDaemon `dev.smcled.brightness` loaded successfully. `launchctl print` showed `run interval = 300 seconds`, `runs = 1`, `last exit code = 0`, and `state = not running`, normal for a one-shot periodic program.

Not yet tested on-device: sleeping/waking while a transition is missed, unattended scheduled event timing, or firmware-update recovery. No attempt was made to drive the two PWM channels simultaneously using unknown SMC writes.

## November 1, 2026 — sleep behavior and configurable interval

- On-device sleep test: sleeping resets the front LED to fixed white at maximum (`255`).
- No resident wake-notification listener is used. The existing one-shot system LaunchDaemon checks again when scheduled after waking; it does not guarantee immediate restoration on wake.
- The automatic installation now supports `--install-auto [interval_seconds]` (default 300; accepted 30–86400) and stores that interval directly in the LaunchDaemon's `StartInterval` field. `--status` reads the actual configured value from the plist. Reinstall with a different interval to change it.


## 17 November 2026 — Read-only compatibility fingerprinting

The CLI now includes `--compatibility` (read-only), `--compatibility-self-test` (pure signature tests), and `--test-brightness <level> --confirm-hardware-test` (two-second, opt-in reversible LSLN test). Candidates are not automatically whitelisted for normal writes, amber switching, or LaunchDaemon installation; the model-specific guard for `Macmini9,1` remains in force.

**Mac Studio M4 Max (`Mac16,9`)**, live read-only result: `LSLN` `ui16` `0xC0`, `LSSB` `hex_` `0x50`, `LSRB` `flag` `0x50`, `LSCS` `ui8 ` `0x90`, `LS0P`/`LS1P` `ui16` `0x80`, all matching the M1 signatures. Normal LED readings: `LSLN=FF FF`, `LSCS=00`, `LS0P=A3 B2`, `LS1P=00 00`. This is an **unverified full-interface candidate**; no physical brightness or amber test has been performed.

**Mac mini 2018 (`Macmini8,1`)**, live read-only key listing: `LS0C` `ui16` `0xC4`, `LSLN` `ui16` `0xC0`, `LSRB` `flag` `0x50`, and `LSSB` `hex_` `0x50`. `LSCS`/`LS0P`/`LS1P` were absent from the returned filtered key scan. This is a **brightness-register candidate**, not established white or amber LED control. The lack of channel telemetry makes the M1 color-restoration procedure unsuitable without further analysis.

`--test-brightness` does not write `LSSB`, `LSRB`, or any channel configuration key. It requires `sudo` plus an explicit flag, verifies `LSLN` metadata, declines unexpected initial values, and restores original brightness on normal exit or handled signals. Readback is not proof of physical LED control; user observation is required. A crash, SIGKILL, or power failure may prevent restoration.

## 17 November 2026 — Physical brightness test results

- **Mac Studio M4 Max (`Mac16,9`):** `--compatibility` matched all six keys in the full interface. `sudo ./smcled --test-brightness 100 --confirm-hardware-test` changed `LSLN=FF FF` to `64 64` and restored `FF FF`. The user physically observed the white status LED dim and return to full brightness. **White brightness adjustment is now hardware-verified on Mac16,9.** Amber, flashing presets, and persistent installation remain untested and blocked by the existing guard.
- **Mac mini 2018 (`Macmini8,1`):** `--compatibility` showed `LSLN=2F FF`, unlike symmetric values on Apple Silicon machines. The same temporary test correctly refused before writing: `Unexpected LSLN=2F FF`. **No LED writes were made.** The mapping of the two bytes is unknown; do not replace `2F FF` with `64 64` simply to force a test.
- The read-only `--sample-brightness` command gathers repeated values for investigating whether the unusual Intel SMC value changes over time. It makes no SMC writes and cannot establish the two-byte encoding by itself.


### Pending Mac Studio amber probe

A guarded `--test-studio-amber --confirm-hardware-test` command was added for `Mac16,9` only. It requires root, no loaded smcled job, full SMC signature, initial white channel (`LSCS=00`, `LS1P=0000`) and symmetric brightness. After dimming white to zero, it sends only the M1-tested steady amber preset (`LSSB=04 00`) and checks channel telemetry. If the channel responds as expected, it displays brightness 100 for 1.5 seconds. A `defer` attempts to return to white using `LSRB` and the saved `LSLN`. SIGINT/SIGTERM use the existing cancellation handler; process crash, SIGKILL, or a power interruption can defeat restoration. **Mac Studio amber and restore behavior are still unverified until observed physically.** No regular write permissions were expanded.
## 17 November 2026 — Mac Studio amber and guarded family support

**Mac Studio M4 Max (`Mac16,9`) passed the physical amber test.** Initially `LSCS=00 LS0P=A3 B2 LS1P=00 00 LSLN=FF FF`. The `LSSB=04 00` preset selected channel 1 and visually produced amber. At `LSLN=64 64`, `LS1P=41 A9`. After restoration, `LSCS=00` and `LSLN=FF FF`; `LS0P=00 00` at the immediate sample may indicate delayed PWM settling. The user reports correct restoration.

Apple Silicon Mac mini and Studio identifiers covering M1–M4 are recognized in the normal command paths, with full SMC metadata validation. Only `Macmini9,1` and `Mac16,9` have confirmed physical behavior. Other listed models must pass `--accept-untested-model`; their installed daemon records this acknowledgement. Unknown newer model IDs stay blocked pending review. Flashing presets on Mac Studio remain unverified.

**Mac mini 2018 (`Macmini8,1`)** returned stable asymmetric `LSLN=2F FF` in ten samples. Encoding remains unknown. An explicitly experimental `--test-intel-brightness` command alters only byte 2 for two seconds and restores both original bytes. It does not enable permanent Intel control, and a failed process or power loss could prevent restoration.

## 17 November 2026 — Manual Mac Studio confirmation; Intel test result

- **Mac Studio M4 Max (`Mac16,9`):** The user ran the normal, newly enabled commands `sudo ./smcled --amber 100` and `sudo ./smcled --white 255`. Both worked visually as expected. Together with the earlier white brightness and reversible amber diagnostic tests, this **physically verifies manual white and steady amber switching on `Mac16,9`**. The user expressly chose **not** to install the LaunchDaemon on the Studio, so persistent auto mode on this machine is **not yet tested**. Flashing patterns on Studio have also **not** been tested.
- **Mac mini 2018 (`Macmini8,1`):** `sudo ./smcled --test-intel-brightness 100 --confirm-hardware-test` changed the observed `LSLN` bytes from `2F FF` to `2F 64` for two seconds, then restored `2F FF`. The user saw **no visible LED brightness change**. This does not establish that the first byte controls brightness or that the machine cannot be dimmed; the encoding and effects of undocumented keys remain unknown. Keep normal Intel LED writes and installation disabled.

## 17 November 2026 — Intel multi-test diagnostics in one build

New Macmini8,1-only diagnostic commands:

- `--intel-snapshot`: read-only inventory of LED-related SMC keys, reporting unavailable keys without writes.
- `--intel-suite --confirm-hardware-test`: three sequential, reversible two-second `LSLN` experiments: `2F FF → 20 FF` (first byte), `2F FF → 40 FF` (first byte), then `2F FF → 2F 64` (second byte, previous no-visible-effect control).
- `--intel-probe first|second <0...255> --confirm-hardware-test`: selectable reversible test without rebuilding. First-byte values limited to decimal 32–64 because the first byte has not previously been modified on this model.
- The prior `--test-intel-brightness` remains available, using the common probe engine.

Every stage verifies the observed baseline `2F FF`, samples the test value, and attempts to restore and re-read the exact baseline before continuing. A failed restore stops subsequent probes; there is an additional best-effort restore on exit. `SIGINT`/`SIGTERM` are handled through the existing diagnostic cancellation object, but crash, SIGKILL, and power loss cannot guarantee restoration. Only `LSLN` is ever written. No Intel support is granted for ordinary or persistent LED changes. **No first-byte hardware experiment has yet been run.**

## 17 November 2026 — Intel three-stage physical observation

On `Macmini8,1`, user ran `--intel-snapshot` and `--intel-suite --confirm-hardware-test` successfully. `LSLN` was initially `2F FF`; other read-only keys included `LSLB=FF FF`, `LSLF=00 00`, `LS0C=FF FF`, `LSOF=00`, and `LSSE=01`. `LS0P`, `LS0S`, `LS1C`, `LS1P`, `LS1S`, `LSCS` were unavailable. Three steps accepted their respective values and restored the original `LSLN` after each:

- `2F FF` -> `20 FF` -> `2F FF`: **no visible brightness change**.
- `2F FF` -> `40 FF` -> `2F FF`: **no visible brightness change**.
- `2F FF` -> `2F 64` -> `2F FF`: **no visible brightness change** (reproducing prior outcome).

All reported read-only key snapshots after each stage matched the initial baseline. User explicitly reported no visual change in any stage. This does **not** establish that these keys are irrelevant in all conditions, but there is no evidence here that `LSLN` drives the physical LED on the Intel mini. Stop blind SMC write experiments; seek device/firmware-specific evidence before any new Intel write tests. Intel normal LED commands and installation stay disabled.

## 17 November 2026 — Startup retries and opt-in for future Apple Silicon desktops

`applyInstalledBrightness()` now enters the bounded boot-time retry loop **before** opening/checking AppleSMC. This fixes the case where an early AppleSMC failure previously bypassed all 15 retries. The loop passes the opened SMC connection to the model/key guard before applying saved mode.

`--accept-untested-model` remains required for all recognized but unverified M1–M4 mini/Studio models. It now also allows **unlisted future Apple Silicon Mac mini or Mac Studio models** only if: `hw.model` matches the modern `MacN,N` syntax, `hw.optional.arm64` confirms Apple Silicon, `/usr/sbin/system_profiler SPHardwareDataType -json` reports the same model ID and a `Mac mini` or `Mac Studio` product family, the SMC full key signature matches the verified profile, and the current brightness/channel readback looks plausible. The flag is persisted into the LaunchDaemon command on unverified models. Intel models and other product families remain blocked. The tool makes no assertion that future hardware is physically verified.

The new unknown-model product-family check invokes the OS system profiler with a bounded 10-second timeout. If it is unavailable or cannot identify the family, no write is allowed. The diagnostic `--compatibility-self-test` now covers future model-ID syntax.


## 17 November 2026 — Intel T2 SIL state investigation (independent research)

### Evidence from Macmini8,1 hardware

The complete read-only \`LS*\` key inventory included \`LSLN\` (ui16, 2, C0), \`LSLB\` (ui16, 2, C0), \`LSLF\` (ui16, 2, C0), \`LSPV\` (ui16, 2, 80), \`LSOF\` (flag, 1, 80), \`LSOO\` (flag, 1, 50), \`LSRB\` (flag, 1, 50), \`LSSB\` (hex_, 2, 50), \`LSSV\` (ui16, 2, C4), and \`LSSE\` (flag, 1, C0), among other keys. At the observed baseline \`LSLN=2F FF\`, \`LSLB=FF FF\`, \`LSLF=00 00\`, \`LSOF=00\`, \`LSSE=01\`.

The hardware accepted temporary \`LSLN=20 FF\`, \`40 FF\`, and \`2F 64\` but the user saw **no visible LED change** in any stage; \`LSLN=2F FF\` was restored after each test.

### Independent public SIL documentation

The historical Apple SMC key descriptions in [floe/smc_util docs](https://github.com/floe/smc_util/blob/master/docs/readme.md) describe \`LSLN\` as SIL PWM "On", \`LSLB\` as PWM "Full On", \`LSLF\` as PWM "Off", and \`LSPV\` as current PWM. \`LSOF\` indicates whether the SIL is off, \`LSOO\` is an on/off override, \`LSRB\` restores SMC state-machine behavior, \`LSSV\` is a per-unit maximum-brightness scale, and \`LSSE\` enables such scaling. These are *historical descriptions*, not confirmed T2 firmware semantics.

**Hypothesis (not yet established):** the 2018 mini's front LED may currently be in "Full On" behavior using \`LSLB\` (FF FF) rather than the "On" behavior using \`LSLN\` (2F FF). This could explain why writes to \`LSLN\` had no visible effect. The read-only \`LSPV\` register is the next discriminator: compare \`LSPV\` to both \`LSLB\` and \`LSLN\` before considering *any* further write.

### Independent J174 firmware evidence

The provided J174 MacEFI IMG4 image contains 32-bit x86 instructions at file offsets \`0x69769F\` and \`0x6976B8\` that load reversed four-character constants for SMC keys \`LSCS\` and \`LSSB\`, then call a local helper at \`0x69745A\`. Another function refers to \`LSOF\` at \`0x69773C\`. The same instructions repeat in the second firmware bank at an offset of +0x800000. This confirms firmware references to these keys but **does not** prove the handlers are exposed to macOS: \`LSCS\` was absent from the T2 mini's OS-visible SMC inventory. The decompressed bridgeOS kernelcache contains AppleSMC communication classes but no obvious plaintext 4CC literals for these specific LED keys.

No LuxMini code or private profile information was used in this investigation. Do not attempt to mutate \`LSOO\`, \`LSRB\`, \`LSSB\`, \`LSLB\`, or \`LSSV\` solely on the basis of these historical descriptions. The next test is a read-only SMC snapshot, particularly \`LSPV\` and \`LSSV\`.


## 17 November 2026 — Intel live PWM baseline after full `LS*` inventory

User measured on physical `Macmini8,1` (macOS 15.8.2, T2 bridgeOS 24P6005):

| Key | Raw | Interpretation status |
| --- | --- | --- |
| `LSLB` | `FF FF` | Historical full-on PWM preset |
| `LSLF` | `00 00` | Historical off PWM preset |
| `LSLN` | `2F FF` | Historical on PWM preset |
| `LSPV` | `14 11` | Historical actual PWM, constant across five readings spaced 0.5 s |
| `LSOF` | `00` | Historical "off" indicator; consistent with an on LED |
| `LSSV` | `08 6B` | Historical brightness-scale variable, precise current T2 meaning not independently verified |
| `LSSE` | `01` | Historical per-unit scaling enabled |
| `LS0C` | `FF FF` | Unknown significance on this model |
| `LSFD`, `LSFU` | `34 BC 00 01 00 11` | Matching fade-structure bytes; historical flare presets |

Important: `LSPV` differs from `LSLB` and `LSLN` but **this is not conclusive about the selected preset** because `LSSE=01` indicates scaling and the reference lists behavior transitions / ramps. Historical `{pwm` is a 16-bit PWM value; do not interpret each byte separately as independent channels on this Intel model.

**Next controlled experiment:** observe read-only `LSPV` at approximately 100–200 ms intervals *during* the already-tested reversible `LSLN` suite. Correlation (or its absence) will establish whether `LSLN` changes propagate into the reported live PWM. Do not write `LSLB`, `LSOO`, `LSSV`, `LSSE`, `LSSB`, or `LSUP` until supported by further independent evidence. Changing `LSLN` was already completed without visible effect on this particular machine, but no user test is risk-free.

Independent reference: https://github.com/floe/smc_util/blob/master/docs/readme.md (historic SIL key semantics, not guaranteed for T2).
