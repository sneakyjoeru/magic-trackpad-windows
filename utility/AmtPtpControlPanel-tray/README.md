# AmtPtpControlPanel-tray

A tray‑resident control panel for the Magic Trackpad driver. Forked from the upstream
WinForms control panel (`driver/AmtPtpControlPanel`) and extended with:

- **Runs elevated, always** — the app starts normally, then hands over to an elevated
  copy (UAC) via a mutex + named‑event relay, so a single elevated process owns the
  tray icon. Duplicate launches exit silently without an extra UAC prompt.
- **Battery percentage in the tray, without hovering**
  - the tray icon *is* the number: large level‑coloured digits (green ≥ 50 %, amber
    25–49 %, red < 25 %) with a charge bar along the bottom edge of the tile; grey `?`
    when no reading is available;
  - the menu item carries the live value:
    `Show battery percentage in tray - 100 %`;
  - the icon's Text/label is the short value (`100%`) — that is what Windows displays
    next to the icon on systems that show tray labels (Windows 10 has no such option at
    all, Windows 11 hides labels by default);
  - the value refreshes every **5 s**, immediately **at launch** (forced reads at
    1/2/3 s, because the driver can ignore the very first IOCTL) and whenever the
    settings window is **opened or re‑focused**.
  - **Bluetooth only** — over USB‑C the trackpad is powered by the cable and reports no
    level.
- **Explanatory tooltips** on every option control (click feedback, gesture stopping,
  palm rejection, finger filtering, battery, startup).
- **Startup group** in the settings window — *Start automatically at login (one UAC
  prompt per login)* and *Start hidden in system tray* — mirroring the tray menu items
  *Start with Windows* / *Start minimized*. Stored per user in
  `HKCU\Software\MtTrackpad\Tray`; the Run entry is `Magic Trackpad`.

Settings persist to the same vendor registry location the original panel uses
(`HKLM\...\WUDF\Services\AmtPtpDeviceUsbUm\Parameters`), so both panels control the
same driver configuration. *Apply* hot‑reloads the driver — no reboot.

## Requirements

- Windows 10/11 x64
- The trackpad driver installed — the release package's `install.ps1` (or
  `utility\MtTrackpad.ps1 install`) does that, including the certificates the
  self‑signed driver package needs
- The account must be a member of **local Administrators** (the app needs an elevated
  token to open the driver's control device)

## Using

1. Run `AmtPtpControlPanel.exe`. On first start you will see a **UAC prompt** — accept
   it. The non‑elevated stub exits; the elevated process owns the tray icon.
2. Right‑click the tray icon:
   - **Open** — the full settings panel (click feedback strength, silent clicks, gesture
     stopping, palm rejection, focus hack, battery, …).
   - **Battery: NN %** — current charge (Bluetooth mode only).
   - **Show battery percentage in tray - NN %** — toggle; the number is the icon.
   - **Start with Windows** — per‑user Run entry; one UAC prompt per logon.
   - **Start minimized** — begin in the tray without opening the window.
   - **Exit** — stop the app.
3. Closing the settings window with the X button does **not** stop the app: the first
   close parks it in the tray (a balloon says so). Use *Exit* to really stop it.

## Building

Built with the .NET 4.0 `csc.exe` (no project file, no Visual Studio):

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

| File | Role |
|---|---|
| `Program.cs` | entry point; single‑instance + elevation relay |
| `Tray.cs` | tray icon, menu, options persistence, battery reader (synchronous IOCTL) |
| `Main.cs` / `Main.Designer.cs` | the vendor control panel form |
| `Properties\AssemblyInfo.cs` | assembly identity |
| `Icon1.ico` | application + tray icon resource |

### Notes for maintainers

- The battery IOCTL (`0x00222004` on `\\.\AmtPtpControlDeviceUm`) must be issued
  **synchronously**; the driver rejects overlapped I/O. The P/Invoke return type must be
  a concrete `SafeFileHandle` — declaring the abstract `SafeHandle` fails at runtime with
  `MarshalDirectiveException` and silently kills every read.
- WinForms checkboxes only render their full text if the designer file carries an
  explicit `Size` (or `AutoSize = false`); with a bare `AutoSize = true` they stay at the
  104 px default and clip to the first word on .NET 4.0.
- `Form.Activate` is a method — the focus event is `Activated`.
