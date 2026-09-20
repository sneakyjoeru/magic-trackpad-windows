Apple Magic Trackpad Setup Utility + Drivers v1.0
=================================================

WHAT THIS IS
  The tray control panel and driver installer for the Apple Magic Trackpad on
  Windows. Everything needed is in this folder (see INSTALL.txt): the driver,
  the installer, the panel and the maintenance tools.

  It contains the full vendor control panel plus:

  * Battery percentage, visible without hovering
      - the tray icon itself is the number (large digits coloured by level:
        green >= 50 %, amber 25-49 %, red < 25 %, grey "?" when the trackpad
        reports nothing) with a charge bar along the bottom edge;
      - the tray menu shows it live:
        "Show battery percentage in tray - 100 %";
      - the tray icon's Text/label is the short value ("100%"), which Windows
        shows next to the icon where that per-icon label option exists;
      - refreshes every 5 s while the settings window is focused, immediately at
        launch (retries at 1/2/3 s), whenever the window is opened or re-focused
        and whenever the tray menu is opened; while the app sits unfocused in
        the tray it reads once every 10 minutes.
      - Bluetooth only: over the USB-C cable the trackpad is powered by the
        cable and reports no level - the icon then shows a grey "?".

  * Always runs elevated: one UAC prompt at start; the elevated process owns
    the tray icon. Launching it again while it runs produces no second prompt
    and no second icon (single-instance mutex + elevation relay).

  * Explanatory tooltips on every option in the settings window.

  * "Startup" group in the settings window:
      "Start automatically at login (one UAC prompt per login)"
      "Start hidden in system tray"
    both mirror the tray-menu items "Start with Windows" / "Start minimized".
    Stored per user in HKCU\Software\MtTrackpad\Tray; the autostart entry is
    HKCU\...\CurrentVersion\Run "Magic Trackpad".

REQUIREMENTS
  * Windows 10/11 x64
  * The trackpad driver installed - INSTALL.txt / install.ps1 does that
    automatically, including the code-signing certificates it needs
  * Your account must be in the LOCAL Administrators group: the panel needs
    an elevated token to open the driver's control device. If settings will
    not save (or the battery reads "not available") after accepting UAC, the
    usual cause is a non-admin account.

INSTALL
  Extract the package and double-click   Install.cmd   (or the
  "Install Magic Trackpad" shortcut next to it). One UAC prompt, no commands
  to type. It trusts the certificates, imports the driver, copies the panel to
  %LOCALAPPDATA%\MagicTrackpad and starts it. Uninstall.cmd reverses all of it.

  Command line equivalent:
      powershell -ExecutionPolicy Bypass -File .\install.ps1 [-Autostart] [-DriverOnly]

  See INSTALL.txt for switches, manual steps and troubleshooting.

USE
  Right-click the tray icon:
    Open               - the full settings panel (click feedback, silent
                         click, stopping gestures by pressure or contact
                         size, palm rejection, finger filtering, battery).
    Battery: NN %      - current charge (Bluetooth only).
    Show battery percentage in tray - toggle, shows the live value.
    Start with Windows - run at every logon (one UAC prompt per logon).
    Start minimized    - start in the tray without opening the window.
    Exit               - stop the app.

  Double-clicking the tray icon does the same as "Open".

  Closing the settings window with the X button does NOT stop the app - the
  first close parks it in the tray (a balloon tells you so). To really quit,
  use Exit in the tray menu, or press X a second time after reopening.

  "Apply" saves everything to the driver configuration and hot-reloads the
  driver - no reboot needed.

BUILD IT YOURSELF
  Full source: utility/AmtPtpControlPanel-tray in the repository
  (Main.cs, Main.Designer.cs, Tray.cs, Program.cs, Properties/AssemblyInfo.cs).
  Build with .NET 4.0 csc - no Visual Studio needed:

      powershell -ExecutionPolicy Bypass -File .\build.ps1

LICENSE
  Part of the magic-trackpad-windows repository. The tray extensions (tray
  plumbing, battery reader, tooltips, elevation relay) are MIT licensed.
  The vendored panel forms (Main.cs / Main.Designer.cs) derive from the
  upstream MagicTrackpad2ForWindows project (GPLv2) - see driver/LICENSE.

CREDITS AND ATTRIBUTION
  This package is a thin layer on top of other people's work - the driver, the
  control panel and the haptic protocol all come from the projects below:

    * vitoplantamura/MagicTrackpad2ForWindows - the driver this package ships
      and builds on (user-mode WUDF driver + kernel HID filter, Bluetooth
      support, original control panel), GPLv2.
    * imbushuo/mac-precision-touchpad (Bingxing Wang) - the original Magic
      Trackpad 2 Windows driver that the project above forks.
    * 1Revenger1 - PR #533 to the imbushuo repo (near-field fingers fix, code
      cleanup, interrupt-path QueryPerformanceCounter removal).
    * dos1 - reverse engineering behind the haptic feedback control messages.
    * Landlogic IT - Microsoft Hardware Dashboard access and upstream driver
      package signing.
    * @ordens, Taylor Sharp, @Wikiwix, @nagromc, @danspel, Qiao Zeyu,
      Purasu Oy, Patrick Adler - contributions to the upstream EV
      code-signing certificate.
    * lostindark/DriverStoreExplorer - recommended driver-store cleanup tool.
    * Apple - the hardware; "Magic Trackpad" is an Apple trademark. This
      project is not affiliated with or endorsed by Apple.

  The additions in this package (tray plumbing, battery reader, elevation
  relay, installer, diagnostics) are MIT licensed; the vendored panel forms
  derive from the upstream project (GPLv2) - see driver/LICENSE.

  (Original credits block, kept for reference:)
    * vitoplantamura/MagicTrackpad2ForWindows - the driver this package is
      built on (user-mode WUDF driver + kernel HID filter, Bluetooth support,
      original control panel), GPLv2.
    * imbushuo/mac-precision-touchpad (Bingxing Wang) - the original Magic
      Trackpad 2 Windows driver that the project above forks.
    * 1Revenger1 - PR #533 to the imbushuo repo (near-field fingers fix, code
      cleanup, interrupt-path QueryPerformanceCounter removal).
    * dos1 - reverse engineering behind the haptic feedback control messages.
    * Landlogic IT - Microsoft Hardware Dashboard access and upstream driver
      package signing.
    * @ordens, Taylor Sharp, @Wikiwix, @nagromc, @danspel, Qiao Zeyu,
      Purasu Oy, Patrick Adler - contributions to the upstream EV
      code-signing certificate.
    * lostindark/DriverStoreExplorer - recommended driver-store cleanup tool.
    * Apple - the hardware; "Magic Trackpad" is an Apple trademark. This
      project is not affiliated with or endorsed by Apple.
