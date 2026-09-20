# AmtPtpControlPanel-tray

A tray-resident control panel for the Magic Trackpad driver. Forked from the upstream
WinForms control panel (`driver/AmtPtpControlPanel`) and extended with:

- **Runs elevated, always** — the app starts normally, then hands over to an elevated
  copy (UAC) via a mutex + named-event relay, so a single elevated process owns the
  tray icon. Duplicate launches exit silently without an extra UAC prompt.
- **Tray icon shows battery percentage** (optional, menu → *Show battery in tray*).
  Works in **Bluetooth mode only** — over USB-C the trackpad is powered by the cable
  and the driver reports no level.
- **Explanatory tooltips** on every option control (click feedback, gesture stopping,
  palm rejection, finger filtering, battery).
- **Autostart / start-minimized options** (menu → *Start at login*, *Start minimized*),
  stored per-user in `HKCU\Software\MtTrackpad\Tray`.

Settings persist to the same vendor registry location the original panel uses
(`HKLM\...\WUDF\Services\AmtPtpDeviceUsbUm\Parameters`), so both panels control the
same driver configuration. Applying settings hot-reloads the driver — no reboot.

## Requirements

- Windows 10/11 x64
- The trackpad driver installed (see the driver package or `MtTrackpad.ps1 install`)
- The account must be a member of **local Administrators** (the app needs an
  elevated token to open the driver's control device)

## Using

1. Run `AmtPtpControlPanel.exe`. On first start you will see a **UAC prompt** —
   accept it. The non-elevated stub exits; the elevated process now owns the tray icon.
2. Right-click the tray icon:
   - **Open settings** — the full control panel (click feedback strength, silent
     clicks, gesture stopping, palm rejection, focus hack, battery, …).
   - **Battery: NN %** — current charge (Bluetooth mode only).
   - **Show battery in tray** — toggle: draw the percentage next to the icon.
   - **Start at login** — adds a per-user Run key entry. Because the app runs
     elevated, you will get one UAC prompt after each logon; refuse it and the
     app asks (Retry/Exit) or stays out of the way until you launch it again.
   - **Start minimized** — begin in the tray without opening the window.

## Building

Built with the .NET 4.0 `csc.exe` (no project file needed):

```powershell
.\build.ps1
```

produces `AmtPtpControlPanel.exe` next to the sources. Equivalent command line:

```
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe ^
  /nologo /target:winexe /optimize+ /out:AmtPtpControlPanel.exe ^
  /r:System.dll /r:System.Core.dll /r:System.Data.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll ^
  /resource:Icon1.ico,AmtPtpControlPanel.Icon1.ico /win32icon:Icon1.ico ^
  Main.cs Main.Designer.cs Tray.cs Program.cs Properties\AssemblyInfo.cs
```

Files:

| File | Role |
|---|---|
| `Program.cs` | entry point; single-instance + elevation relay |
| `Tray.cs` | tray icon, menu, options persistence, overlapped-I/O battery reader |
| `Main.cs` / `Main.Designer.cs` | the original vendor control panel form |
| `Properties\AssemblyInfo.cs` | assembly identity |
