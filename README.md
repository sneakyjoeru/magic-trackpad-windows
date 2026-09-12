# Magic Trackpad for Windows

Private utility for setting up, configuring and monitoring an **Apple Magic Trackpad (USB‑to‑PC, latest USB‑C model)** on Windows — wired (USB‑C) first, then wireless (Bluetooth).

Built on the open‑source [MagicTrackpad2ForWindows](https://github.com/vitoplantamura/MagicTrackpad2ForWindows) driver (`AmtPtpDeviceUsbUm` user‑mode WUDF driver + `AmtPtpHidFilter` kernel filter), extended with:

- a **PowerShell setup & control utility** (`utility/MtTrackpad.ps1`) that works headless (SSH / scheduled tasks) — no GUI required;
- an **unattended verification harness** (`utility/Verify-MtTrackpad.ps1`) that reports PASS/FAIL from signals a human at the keyboard is not needed for;
- a small **VID 27A7** compatibility patch (some Magic Trackpad 2 units enumerate under vendor ID `27A7` instead of `05AC`);
- a **Windows 10** driver INF variant (the stock INF targets a Win11‑era section).

## What the driver gives you

| Feature | Wired (USB‑C) | Wireless (Bluetooth) |
|---|---|---|
| Precision / multi‑touch gestures | ✅ | ✅ |
| Force / haptic click feedback control | ✅ | ✅ |
| Battery level reading | ➖ (powered by cable) | ✅ |
| Pointer precision options | ✅ | ✅ |

## Repository layout

```
magic-trackpad-windows/
├── README.md
├── driver/                          # MagicTrackpad2ForWindows source (patched)
│   ├── AmtPtpDeviceUsbUm/           #   user‑mode WUDF driver (C)
│   ├── AmtPtpHidFilter/             #   kernel‑mode HID filter miniport (C)
│   ├── AmtPtpControlPanel/          #   upstream WinForms control panel (C#)
│   └── build/                       #   INFs + make.bat
│       ├── AmtPtpDevice_AMD64.inf          # Win11 x64
│       ├── AmtPtpDevice_ARM64.inf          # Win11 ARM64
│       └── AmtPtpDevice_AMD64_WIN10.inf    # Windows 10 x64 (used on the streamer PC)
└── utility/
    ├── MtTrackpad.ps1               # setup & control utility (this is the main tool)
    └── Verify-MtTrackpad.ps1        # unattended PASS/FAIL verification harness
```

## Devices supported

| Hardware ID | Device |
|---|---|
| `USB\VID_05AC&PID_0324` | Magic Trackpad 2, USB‑C (2024) — **the unit on the streamer PC** |
| `USB\VID_27A7&PID_2501` / `0x9601` | Magic Trackpad 2 resold under VID 27A7 (added by this repo) |
| `HID\{...}_VID&0001004c_PID&0324&Col01` | Magic Trackpad 2 USB‑C over Bluetooth (wireless phase) |

> The Bluetooth hardware IDs are captured with `MtTrackpad.ps1 wireless` **after** the trackpad is paired, then added to the INF for wireless support.

## Quick start (wired)

Prereqs: an admin shell on the target PC, and the built driver package (see [Building](#building-the-driver)).

```powershell
# 1. Install the driver (trusts the signing cert, imports the package, binds the device)
.\utility\MtTrackpad.ps1 install -DriverDir C:\MtTrackpad\Driver

# 2. Verify it's actually working (headless)
.\utility\Verify-MtTrackpad.ps1

# 3. Configure haptics / gestures
.\utility\MtTrackpad.ps1 configure -Feedback medium -Silent -StopPressure 50 -Palm on

# 4. Inspect state / battery
.\utility\MtTrackpad.ps1 status
.\utility\MtTrackpad.ps1 battery
```

## Utility commands

| Command | Purpose |
|---|---|
| `install -DriverDir <dir>` | Trust signing cert, import driver package, bind the wired device |
| `uninstall [-Force]` | Stop filter service, remove driver packages (and device instances with `-Force`) |
| `status [-Json]` | Device / driver / service / control‑device state |
| `settings` | Show current haptic & gesture settings |
| `configure -Feedback <light\|medium\|firm\|maximum\|disabled> [-Silent] [-StopPressure N] [-StopSize N] [-Palm on\|off] [-IgnoreButton on\|off] [-IgnoreNear on\|off]` | Apply settings, then reload the driver |
| `battery` | Query battery level via IOCTL (meaningful over Bluetooth) |
| `reload` | Ask the driver to reload settings + restart the device |
| `wireless [-Pair]` | List Bluetooth candidates / start pairing UI / report hardware IDs for the INF |

### Haptic feedback presets

The `FeedbackClick` / `FeedbackRelease` DWORDs encode vibration intensity (high byte) + audio (low byte), mirroring the upstream control panel:

| Preset | Click | Release | Notes |
|---|---|---|---|
| `light` | `0x040415` | `0x000010` | gentle |
| `medium` | `0x060617` | `0x000014` | default |
| `firm` | `0x08081e` | `0x020218` | strong |
| `maximum` | `0xFFFFFF` | `0xFFFFFF` | strongest |
| `disabled` | `0x000000` | `0x000000` | no feedback |

`-Silent` masks the audio (low) byte; `-NoSilent` restores it.

## Building the driver

Requires **Visual Studio 2022** with the *Desktop development in C++* and *Windows Driver Kit* workloads, run from an **x64 Native Tools Command Prompt for VS 2022**.

```bat
cd driver
NuGet.exe restore ..\AmtPtpHidFilter\packages.config -PackagesDirectory ..\packages\
build\make.bat
```

`make.bat` builds both projects for ARM64 + x64, copies artifacts to `build\result\{AMD64,ARM64}`, signs them, and runs `inf2cat`. It prompts interactively for the `inf2cat.exe` path and the two SHA‑1 signing thumbprints (control‑panel exe, drivers).

For the **Windows 10** target, place `build\AmtPtpDevice_AMD64_WIN10.inf` as `result\AMD64\AmtPtpDevice.inf` before running `inf2cat` (the stock `AmtPtpDevice_AMD64.inf` targets a Win11‑era section).

### Signing

A self‑signed code‑signing certificate is generated on the build machine (the upstream release `.cer` ships without a private key). The same cert signs the control‑panel exe and both drivers, and is included in the package so `MtTrackpad.ps1 install` can trust it.

## Verification (headless)

`Verify-MtTrackpad.ps1` returns:

- exit `0` — all mandatory checks passed (device present, bound to `AmtPtpDeviceUsbUm`, filter service running, control‑device IOCTL answered);
- exit `1` — one or more mandatory checks failed;
- exit `2` — trackpad not present.

Signals used (no keyboard needed): PnP instance status + bound service, `AmtPtpHidFilter` service state, `\\.\AmtPtpControlDeviceUm` IOCTL round‑trip, battery IOCTL (informational), and driver‑related System‑log errors since a given time.

## Wireless phase (TODO)

1. Pair the trackpad over Bluetooth on the target PC.
2. `.\utility\MtTrackpad.ps1 wireless -Pair` → complete pairing in the UI.
3. Re‑run `wireless` to capture the trackpad's `BTH\...` / `BTHLEDEVICE\...` hardware IDs.
4. Add those IDs to the INF (`AmtPtpHidFilter_MiniPortDevice` bindings), rebuild, reinstall.
5. Battery + haptics then work over the air.

## Credits

Based on [vitoplantamura/MagicTrackpad2ForWindows](https://github.com/vitoplantamura/MagicTrackpad2ForWindows) (itself a fork of [imbushuo/mac-precision-touchpad](https://github.com/imbushuo/mac-precision-touchpad)). Upstream driver is GPLv2; see `driver/LICENSE`.
