# Magic Trackpad for Windows

Get an **Apple Magic Trackpad (Magic Trackpad 2 / USB‑C model)** working properly on
Windows: precision multi‑touch, haptic clicks, a control panel, and a battery readout in
the system tray. Wired over USB‑C or wireless over Bluetooth.

<img width="765" height="851" alt="image" src="https://github.com/user-attachments/assets/e48c0c1a-b21a-4e4e-87b1-039384188705" />

Built on the open‑source driver [MagicTrackpad2ForWindows](https://github.com/vitoplantamura/MagicTrackpad2ForWindows)
with the additions this repo needs in practice:

- a signed driver package **plus the certificates it needs**, so one script installs everything;
- a **one‑click installer** (`Install.cmd`) — UAC prompt, nothing to type;
- a small **VID 27A7** patch (some Magic Trackpad 2 units enumerate with vendor ID `27A7`
  instead of `05AC`);
- a **Windows 10** INF variant (the stock one targets a Windows 11 section);
- a **tray control panel** with the battery percentage in the icon, per‑user autostart and
  tooltips on every option;
- **headless PowerShell utilities** for setup, verification and configuration over SSH or
  scheduled tasks.

## Install

1. Download `AmtPtpControlPanel-v1.0.8-win64.zip` from [Releases](../../releases/latest) and extract it.
2. Double‑click **`Install.cmd`** and confirm the UAC prompt.

That installs the certificates, the driver package, the control panel (to
`%LOCALAPPDATA%\MagicTrackpad`) and a Start Menu shortcut, then starts the panel.
`Uninstall.cmd` removes it all again. Moving the trackpad from another PC (or any
"Failed to open device. Error: 2" from the panel) is covered by
`Uninstall-All-Apple-Drivers.cmd` — it clears every known Apple/trackpad driver package and
leftover device instance first; `Install.cmd -Clean` does both in one pass.

Details, switches, manual steps, verification and troubleshooting:
**[SETUP-NEW-HOST.md](SETUP-NEW-HOST.md)** and **[INSTALL.txt](INSTALL.txt)**.

Requirements: Windows 10/11 x64, an account in the local **Administrators** group (the panel
opens the driver's control device with an elevated token). No compiler needed — .NET 4.x ships
with Windows.

## What works

| Feature | Wired (USB‑C) | Wireless (Bluetooth) |
|---|---|---|
| Precision / multi‑touch gestures | ✅ | ✅ |
| Force / haptic click feedback | ✅ | ✅ |
| Battery level | ➖ powered by the cable | ✅ |
| Pointer / gesture options | ✅ | ✅ |

Tray control panel (right‑click the tray icon):

- **Open** — the full settings window: click feedback, silent clicking, stopping gestures by
  pressure or contact size, palm rejection, finger filtering.
- **Battery** — `Battery: NN %` in the menu, the number drawn **inside the tray icon**, and the
  icon's label (`100%`). Read every 5 s while the window is focused, every 10 minutes while the
  app sits unfocused in the tray, and immediately on launch, on opening the window and on
  opening the tray menu. Bluetooth only — over USB‑C it shows a grey `?`.
- **Startup** — *Start with Windows* / *Start minimized*, mirrored as the settings window's
  **Startup** group. Stored per user in `HKCU\Software\MtTrackpad\Tray`; one UAC prompt per logon.
- Runs elevated, always, and only once (a single elevated process owns the tray icon; extra
  launches exit silently).

## Devices

| Hardware ID | Device |
|---|---|
| `USB\VID_05AC&PID_0324` | Magic Trackpad 2, USB‑C (2024) |
| `USB\VID_27A7&PID_2501` / `0x9601` | Magic Trackpad 2 resold under VID 27A7 (added here) |
| `HID\{...}_VID&0001004c_PID&0324&Col01` | Magic Trackpad 2 over Bluetooth |

## Repository

```
magic-trackpad-windows/
├── install.ps1                  one-shot installer (what Install.cmd calls)
├── Install.cmd / Uninstall.cmd  double-click entry points (self-elevating)
├── Uninstall-All-Apple-Drivers.cmd  clean slate: removes every Apple trackpad driver
├── SETUP-NEW-HOST.md            full setup guide for a fresh machine
├── INSTALL.txt                  quick start, manual steps, troubleshooting
├── certs/                       MtRootCA.cer + MtPtpSigner.cer (driver trust)
├── driver/                      patched MagicTrackpad2ForWindows source
│   ├── AmtPtpDeviceUsbUm/       user-mode WUDF driver (C)
│   ├── AmtPtpHidFilter/         kernel HID filter (C)
│   ├── AmtPtpControlPanel/      upstream WinForms panel (C#)
│   ├── build/                   INFs + make.bat / make_win10.bat
│   └── prebuilt/win10-x64/      built + signed Windows 10 x64 package
└── utility/
    ├── MtTrackpad.ps1           setup / control utility (headless)
    ├── Verify-MtTrackpad.ps1    unattended PASS/FAIL check
    ├── Build-MtTrackpad.ps1     non-interactive build + sign + inf2cat
    ├── Remove-MtCerts.ps1       untrust the test certificates
    └── AmtPtpControlPanel-tray/ tray panel source + build.ps1
```

### Utilities (headless)

```powershell
.\utility\MtTrackpad.ps1 install            # trust certs + import driver + re-scan
.\utility\Verify-MtTrackpad.ps1             # exit 0 = PASS, 1 = failed, 2 = no trackpad
.\utility\MtTrackpad.ps1 status             # device / driver / service / control device
.\utility\MtTrackpad.ps1 battery            # battery via IOCTL (Bluetooth)
.\utility\MtTrackpad.ps1 configure -Feedback medium -Silent -StopPressure 50 -Palm on
```

Other commands: `settings`, `reload`, `wireless [-Pair]`, `uninstall [-Force]`.
Haptic presets: `light`, `medium` (default), `firm`, `maximum`, `disabled`.

### Building from source

- **Driver** — Visual Studio 2022 + WDK, then `driver\build\make.bat` (or `make_win10.bat`
  for the Windows 10 package). `utility\Build-MtTrackpad.ps1` automates the whole flow
  headlessly and prints `BUILD_COMPLETE`.
- **Control panel** — no project file needed:
  `utility\AmtPtpControlPanel-tray\build.ps1` (plain .NET 4.0 `csc`).

Step‑by‑step instructions: [SETUP-NEW-HOST.md](SETUP-NEW-HOST.md).

## Notes

- Both the upstream panel and this tray panel write the same driver settings
  (`HKLM\...\WUDF\Services\AmtPtpDeviceUsbUm\Parameters`); *Apply* hot‑loads them, no reboot.
- `USB\VID_05AC&PID_0324&MI_00` is bound to a null driver by design — that auxiliary interface
  has no HID usage and otherwise shows a cosmetic "device not started" (CM_ERROR 10) badge.
- The battery IOCTL must be issued synchronously and the P/Invoke must return a concrete
  `SafeFileHandle`; the driver rejects overlapped I/O.
- Windows 10 has no tray-label feature and Windows 11 hides labels by default, so the
  percentage is drawn into the tray icon itself.

## Credits

This project is a thin layer on top of other people's work — all credit for the hard parts
belongs here:

- **[vitoplantamura/MagicTrackpad2ForWindows](https://github.com/vitoplantamura/MagicTrackpad2ForWindows)** —
  the driver this repo is built on and forks (user‑mode WUDF driver + kernel HID filter,
  Bluetooth support, control panel). Licensed GPLv2 — see [`driver/LICENSE`](driver/LICENSE).
- **[imbushuo/mac-precision-touchpad](https://github.com/imbushuo/mac-precision-touchpad)** —
  the original Magic Trackpad 2 Windows driver by *Bingxing Wang* that the project above forks.
- **[1Revenger1](https://github.com/1Revenger1)** — the
  [PR #533](https://github.com/imbushuo/mac-precision-touchpad/pull/533) to the imbushuo repo
  that fixes the "near field fingers" problem, cleans up the code and removes the
  `QueryPerformanceCounter` call from the interrupt path.
- **[dos1](https://github.com/dos1)** — the reverse‑engineering work behind the haptic feedback
  control messages the driver sends to the trackpad
  ([reference](https://github.com/mwyborski/Linux-Magic-Trackpad-2-Driver/issues/28#issuecomment-451625504)).
- **[Landlogic IT](https://landlogic.it/)** — handling Microsoft's Hardware Dashboard access and
  signing the upstream driver packages.
- **@ordens, Taylor Sharp, @Wikiwix, @nagromc, @danspel, 乔泽昱, Purasu Oy, Patrick Adler** —
  contributions to the upstream EV code‑signing certificate
  ([details](https://github.com/vitoplantamura/MagicTrackpad2ForWindows/issues/31)).
- **[lostindark/DriverStoreExplorer](https://github.com/lostindark/DriverStoreExplorer)** —
  the driver‑store cleanup tool recommended for removing older driver versions.
- **Apple** — for the hardware; *Magic Trackpad* is an Apple trademark, and this project is not
  affiliated with or endorsed by Apple.

Additions in this repository (tray panel extensions, battery reader, elevation relay,
VID 27A7 / Windows 10 INF variants, installer, utilities) are MIT licensed unless noted
otherwise.
