# Magic Trackpad for Windows

Private utility for setting up, configuring and monitoring an **Apple Magic Trackpad (USB‑to‑PC, latest USB‑C model)** on Windows — wired (USB‑C) first, then wireless (Bluetooth).

Built on the open‑source [MagicTrackpad2ForWindows](https://github.com/vitoplantamura/MagicTrackpad2ForWindows) driver (`AmtPtpDeviceUsbUm` user‑mode WUDF driver + `AmtPtpHidFilter` kernel filter), extended with:

- a **PowerShell setup & control utility** (`utility/MtTrackpad.ps1`) that works headless (SSH / scheduled tasks) — no GUI required;
- an **unattended verification harness** (`utility/Verify-MtTrackpad.ps1`) that reports PASS/FAIL from signals a human at the keyboard is not needed for;
- a small **VID 27A7** compatibility patch (some Magic Trackpad 2 units enumerate under vendor ID `27A7` instead of `05AC`);
- a **Windows 10** driver INF variant (the stock INF targets a Win11‑era section);
- a **tray control panel** (`utility/AmtPtpControlPanel-tray/`) — the upstream WinForms panel plus a system‑tray presence with an optional battery‑percentage display, per‑user autostart, and explanatory tooltips on every option. See [Control panel (tray)](#control-panel-tray).

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
├── SETUP-NEW-HOST.md                # step‑by‑step setup for a fresh Windows machine
├── INSTALL.txt                      # package quick start + manual driver steps
├── install.ps1                      # one‑shot installer (driver + certs + panel)
├── certs/                           # MtRootCA.cer + MtPtpSigner.cer (driver trust)
├── driver/                          # MagicTrackpad2ForWindows source (patched)
│   ├── AmtPtpDeviceUsbUm/           #   user‑mode WUDF driver (C)
│   ├── AmtPtpHidFilter/             #   kernel‑mode HID filter miniport (C)
│   ├── AmtPtpControlPanel/          #   upstream WinForms control panel (C#)
│   ├── build/                       #   INFs + make.bat
│   │   ├── AmtPtpDevice_AMD64.inf          # Win11 x64
│   │   ├── AmtPtpDevice_ARM64.inf          # Win11 ARM64
│   │   └── AmtPtpDevice_AMD64_WIN10.inf    # Windows 10 x64 (used on the streamer PC)
│   └── prebuilt/win10-x64/          #   built + signed Windows 10 x64 package
└── utility/
    ├── MtTrackpad.ps1               # setup & control utility (this is the main tool)
    ├── Verify-MtTrackpad.ps1        # unattended PASS/FAIL verification harness
    ├── Build-MtTrackpad.ps1         # non-interactive build + sign + inf2cat helper
    ├── Remove-MtCerts.ps1           # untrust the test certificates again
    └── AmtPtpControlPanel-tray/     # tray control panel (source + build.ps1)
```

**Full setup on a new machine → [SETUP-NEW-HOST.md](SETUP-NEW-HOST.md)** (or, from a release
archive, `powershell -ExecutionPolicy Bypass -File .\install.ps1`).

## Devices supported

| Hardware ID | Device |
|---|---|
| `USB\VID_05AC&PID_0324` | Magic Trackpad 2, USB‑C (2024) — **the unit on the streamer PC** |
| `USB\VID_27A7&PID_2501` / `0x9601` | Magic Trackpad 2 resold under VID 27A7 (added by this repo) |
| `HID\{...}_VID&0001004c_PID&0324&Col01` | Magic Trackpad 2 USB‑C over Bluetooth (wireless phase) |

> The Bluetooth hardware IDs are captured with `MtTrackpad.ps1 wireless` **after** the trackpad is paired, then added to the INF for wireless support.

## Quick start (wired)

Prereqs: an admin shell on the target PC, and the built driver package (see [Building](#building-the-driver)) —
or skip the build entirely and run `install.ps1` from a release archive
(see [SETUP-NEW-HOST.md](SETUP-NEW-HOST.md)).

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

### Option A — non-interactive helper (recommended for headless builds)

```powershell
# from an elevated PowerShell, anywhere:
.\utility\Build-MtTrackpad.ps1 -RepoRoot <path-to-this-repo> [-NuGetExe <path-to-nuget.exe>]
```

Automates the whole flow with **no prompts**: locates VS2022 + SDK tools, restores NuGet packages, builds all targets, assembles `driver\build\result\`, swaps in the Win10 INF, creates/trusts a self‑signed code‑signing cert, signs all binaries + CATs, and runs `inf2cat`. Prints `BUILD_COMPLETE` on success.

### Option B — interactive make.bat

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

## Known issues & fixes

### "USB Input Device" driver error (CM_ERROR 10) on the wired trackpad

**Symptom.** In Device Manager, the composite device `USB\VID_05AC&PID_0324` shows its interface
`MI_00` ("USB Input Device") with a yellow error badge (CM_ERROR 10 — "device not started"),
while `MI_01` (the real touchpad interface, bound to `AmtPtpDeviceUsbUm`) works normally.

**Root cause.** The Magic Trackpad 2 (USB‑C) is a USB composite device with several interfaces.
Interface `MI_00` is an auxiliary/vendor‑defined interface that carries no HID usage the stock
`HidUsb` driver can bind to. Apple's official v2.0 driver INF — and this repo's INF before
version **2026.3984** — bind only `MI_01` for `PID_0324`, leaving `MI_00` unbound. Windows then
falls back to the stock `HidUsb` driver for `MI_00`, that binding fails to initialise
(CM_ERROR 10) and the yellow badge appears. The error is cosmetic: `MI_00` is not the touch
interface, so pointer/touch/drag keep working through `MI_01`.

**Fix (driver version 2026.3984).** Bind `USB\Vid_05ac&Pid_0324&MI_00` to a **null driver**
(an empty install section with no service and no files) in
[`driver/build/AmtPtpDevice_AMD64_WIN10.inf`](driver/build/AmtPtpDevice_AMD64_WIN10.inf).
The explicit binding stops the `HidUsb` fallback, so the interface no longer errors; the
absence of a service means no second (phantom) touch/pointer instance appears.

## Wireless phase (TODO)

1. Pair the trackpad over Bluetooth on the target PC.
2. `.\utility\MtTrackpad.ps1 wireless -Pair` → complete pairing in the UI.
3. Re‑run `wireless` to capture the trackpad's `BTH\...` / `BTHLEDEVICE\...` hardware IDs.
4. Add those IDs to the INF (`AmtPtpHidFilter_MiniPortDevice` bindings), rebuild, reinstall.
5. Battery + haptics then work over the air.

## Control panel (tray)

`utility/AmtPtpControlPanel-tray/` is a fork of the upstream WinForms control panel
(`driver/AmtPtpControlPanel/`) extended with a system‑tray presence. A prebuilt
`AmtPtpControlPanel.exe` is attached to each [release](https://github.com/sneakyjoeru/magic-trackpad-windows/releases).

Key differences from the upstream panel:

- **Runs elevated, always.** Launching the app starts a small non‑elevated stub that
  hands over to an elevated copy (UAC) through a session‑scoped mutex + named event;
  the stub then exits, so exactly one elevated process owns the tray icon. Duplicate
  launches while an instance is running exit quietly (no extra UAC prompt).
- **Battery percentage, visible without hovering** — *Show battery percentage in tray*
  (tray menu and the settings window's Battery group mirror each other):
  the tray icon itself is the number (large digits coloured by level, plus a charge bar),
  the menu item reads `Show battery percentage in tray - NN %`, and the icon's Text/label
  carries `NN%` for systems that display tray labels. Bluetooth mode only: over USB‑C the
  trackpad is powered by the cable and reports no level (grey `?`). The value refreshes
  every 5 s, immediately at launch (retries at 1/2/3 s) and whenever the settings window
  is opened or re-focused.
- **Explanatory tooltips** on every option (click feedback modes, gesture stopping by
  pressure or by contact size, palm rejection, finger filtering, the focus‑hack field…).
- **Startup options** — tray menu *Start with Windows* / *Start minimized* and the
  settings window's **Startup** group (*Start automatically at login (one UAC prompt per
  login)*, *Start hidden in system tray*), stored per user in
  `HKCU\Software\MtTrackpad\Tray`; the Run entry is `Magic Trackpad`. Autostart re‑runs
  the app after logon, which triggers one UAC prompt; refusing it just leaves the app out
  of the tray until you start it manually (the stub asks once, Retry/Exit).

Requirements: Windows 10/11 x64, the driver installed, and an account in **local
Administrators** (opening the driver's control device needs an elevated token).

Both panels write the same vendor registry settings
(`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WUDF\Services\AmtPtpDeviceUsbUm\Parameters`)
— using them interchangeably is safe, and *Apply* hot‑reloads the driver without a
reboot.

## Credits

Based on [vitoplantamura/MagicTrackpad2ForWindows](https://github.com/vitoplantamura/MagicTrackpad2ForWindows) (itself a fork of [imbushuo/mac-precision-touchpad](https://github.com/imbushuo/mac-precision-touchpad)). Upstream driver is GPLv2; see `driver/LICENSE`.
