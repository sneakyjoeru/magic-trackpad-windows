# Setting up a new host

Everything needed to bring the Magic Trackpad up on a **fresh Windows machine** — driver,
certificates, tray control panel and utilities. Two paths: install the ready-made package
(fast, no toolchain) or build everything from this repository.

---

## 0. What you need

| | |
|---|---|
| Target machine | Windows 10 or 11, **x64**, with an account in the local **Administrators** group |
| Trackpad | Apple Magic Trackpad (USB-C model, or a Magic Trackpad 2) |
| Connection | USB-C cable for the first install; Bluetooth comes afterwards |
| Toolchain | **none** for path A. Path B needs visual studio + WDK for the driver and nothing extra for the panel (.NET 4.x `csc` ships with Windows) |

---

## Path A — install the ready-made package (recommended)

1. Download `AmtPtpControlPanel-v1.0.7-win64.zip` from
   [Releases](../../releases/latest) and extract it (e.g. to `C:\MagicTrackpad`).
   The archive is self-contained:

   ```
   AmtPtpControlPanel-v1.0.7-win64/
     install.ps1              one-shot installer / uninstaller
     AmtPtpControlPanel.exe   tray control panel
     README.txt               what the panel does
     INSTALL.txt              switches, manual steps, troubleshooting
     driver/                  AmtPtpDevice.inf + .cat + UsbUm.dll + HidFilter.sys
     certs/                   MtRootCA.cer + MtPtpSigner.cer
     utility/                 MtTrackpad.ps1, Verify-MtTrackpad.ps1, Remove-MtCerts.ps1
   ```

2. Open an **admin PowerShell** in that folder and run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```

   The installer

   * imports `certs\MtRootCA.cer` and `certs\MtPtpSigner.cer` into
     `LocalMachine\Root`, `\CA` and `\TrustedPublisher` (required — the driver package is
     self-signed),
   * imports the driver package with `pnputil /add-driver driver\AmtPtpDevice.inf /install`
     (skipped, with a re-bind instead, if the package is already in the driver store),
   * re-scans PnP and prints the state of every present trackpad device,
   * copies the panel (and the utilities) to `%LOCALAPPDATA%\MagicTrackpad`,
   * optionally registers autostart and starts the panel.

   Switches: `-Autostart`, `-StartMinimized`, `-DriverOnly`, `-SkipLaunch`,
   `-InstallDir <path>`, `-Uninstall`.

3. Accept the UAC prompt for the panel itself. It now lives in the tray; right-click it for
   settings, or double-click to open the window.

The same thing without the installer:

```powershell
certutil -addstore -f Root             certs\MtRootCA.cer
certutil -addstore -f TrustedPublisher certs\MtPtpSigner.cer
pnputil /add-driver driver\AmtPtpDevice.inf /install
pnputil /scan-devices
.\AmtPtpControlPanel.exe
```

`utility\MtTrackpad.ps1` installs the driver too and finds the folder automatically when run
from the extracted archive:

```powershell
.\utility\MtTrackpad.ps1 install      # trusts certs + imports driver + re-scans
.\utility\MtTrackpad.ps1 status
.\utility\Verify-MtTrackpad.ps1
```

---

## Path B — build from source

### B1. Driver

```powershell
# Visual Studio 2022 + WDK (driver development workload) required
cd driver\build
.\make.bat                # builds AMD64 + ARM64 packages for Windows 11
.\make_win10.bat          # builds the Windows 10 x64 variant (AmtPtpDevice_AMD64_WIN10.inf)
```

`make.bat` compiles `AmtPtpDeviceUsbUm` (user-mode WUDF driver) and `AmtPtpHidFilter`
(kernel HID filter), generates the INFs and a catalog with `inf2cat`, and signs with the
certificate in `utility\certs` (`MtTrackpad.pfx` — the upstream test certificate; replace it
with your own for anything but a private machine).

Then install the freshly built package:

```powershell
.\utility\MtTrackpad.ps1 install -DriverDir driver\build
```

The INF variants differ only in the Windows build sections and the supported hardware IDs:

| INF | Use |
|---|---|
| `AmtPtpDevice_AMD64.inf` | Windows 11 x64 |
| `AmtPtpDevice_ARM64.inf` | Windows 11 ARM64 |
| `AmtPtpDevice_AMD64_WIN10.inf` | **Windows 10 x64** (the streamer PC uses this one) |

### B2. Control panel

```powershell
cd utility\AmtPtpControlPanel-tray
.\build.ps1              # .NET 4.0 csc, no project file, no Visual Studio
```

`build.ps1` produces `AmtPtpControlPanel.exe` from `Main.cs`, `Main.Designer.cs`, `Tray.cs`,
`Program.cs` and `Properties\AssemblyInfo.cs`. Alternative: open
`driver\AmtPtpControlPanel\AmtPtpControlPanel.sln` in Visual Studio — that project builds the
upstream panel without the tray extensions, so prefer `build.ps1`.

Deployment after building: nothing to install, just run the exe (the panel is single-instance
and elevates itself through a UAC relay).

---

## Verification

```powershell
# 1. driver package present?
pnputil /enum-drivers | findstr /i amtptp

# 2. devices present and started?
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match '0324|27A7' } |
    Select-Object Status, Class, InstanceId

# 3. full unattended check (exit code 0 = PASS)
.\utility\Verify-MtTrackpad.ps1
```

Expected after a successful install: the driver package listed once, and a handful of
`OK` devices in classes `HIDClass` / `Mouse` (wired: `USB\VID_05AC&PID_0324...`,
wireless: `HID\{...}_VID&0001004C_PID&0324...`).

Battery: the control panel reads it every 5 s. **Bluetooth only** — over USB-C the trackpad
is powered by the cable and reports nothing, so the tray icon shows a grey `?`.

---

## First-run configuration

1. Right-click the tray icon → **Open**.
2. Click feedback / silent clicking / gesture stopping / palm rejection / finger filtering —
   every option has a tooltip; **Apply** hot-reloads the driver, no reboot.
3. **Startup** group: `Start automatically at login (one UAC prompt per login)` and
   `Start hidden in system tray`. Both mirror the tray menu items *Start with Windows* /
   *Start minimized* and live in `HKCU\Software\MtTrackpad\Tray`.
4. Battery: `Show battery percentage in tray` shows the charge in the tray icon (and in the
   menu item, and in the icon's label on systems that display tray labels).

### Autostart and UAC

The panel needs an elevated token (it opens the driver's control device). Its Run entry
(`HKCU\...\CurrentVersion\Run` → `Magic Trackpad`) therefore triggers one UAC prompt per
logon; refusing it leaves the panel closed. For a prompt-free start, create a scheduled task
once that runs the exe with highest privileges at logon — the panel does not care how it was
started.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `pnputil` refuses the package / "not signed" | The signing certificate is not trusted. Re-run `install.ps1` (it imports into `Root`, `CA`, `TrustedPublisher`); check with `certutil -store Root \| findstr /i mt` |
| Device in Device Manager with a warning triangle | Unplug/replug the USB-C cable, then `pnputil /scan-devices`. Wrong INF variant (Win10 vs Win11) is the usual cause |
| "Device present but not started" | Replug, or reboot once — the WUDF host needs to pick up the new driver |
| Nothing reacts to the trackpad | Another pointer input is stealing it; check the panel's *Focus hack* option and Device Manager for a second instance |
| Battery reads "not available" | USB-C mode (by design) or a non-admin account |
| Tray icon does not appear | Look in the tray overflow (behind the clock); the panel's window always appears even if the icon is hidden |
| Second launch does nothing | By design: single instance. Use the tray menu → *Open* |
| Settings do not save | The panel is not elevated (non-admin account) |

---

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

Removes the panel folder, the autostart entry, the imported driver package and the trusted
certificates. (`utility\Remove-MtCerts.ps1` removes the certificates only.) Log off and on to
drop the tray icon.

---

## Repository map

```
magic-trackpad-windows/
├── README.md                      project overview + device matrix
├── SETUP-NEW-HOST.md              this file
├── INSTALL.txt                    package quick start / manual steps
├── install.ps1                    one-shot installer for the release package
├── certs/                         MtRootCA.cer + MtPtpSigner.cer (driver trust)
├── driver/
│   ├── AmtPtpDeviceUsbUm/         user-mode WUDF driver (C)
│   ├── AmtPtpHidFilter/           kernel HID filter (C)
│   ├── AmtPtpControlPanel/        upstream WinForms panel (C#, untouched)
│   ├── build/                     INFs + make.bat / make_win10.bat
│   └── prebuilt/win10-x64/        the built, signed Windows 10 x64 package
└── utility/
    ├── MtTrackpad.ps1             setup / control utility
    ├── Verify-MtTrackpad.ps1      unattended PASS/FAIL harness
    ├── Remove-MtCerts.ps1         untrust the test certificates
    ├── Build-MtTrackpad.ps1       non-interactive build helper
    └── AmtPtpControlPanel-tray/   tray panel source + build.ps1
```
