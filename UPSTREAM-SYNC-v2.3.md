# Upstream sync: MagicTrackpad2ForWindows 68b31c4 (2026-07-26) -> 2cebc8f (v2.3+1, 2026-11-11)

Branch `upstream-sync-v2.3`. Upstream: https://github.com/vitoplantamura/MagicTrackpad2ForWindows

## What came in (upstream v2.1 / v2.2 / v2.3)

| feature | upstream commit | where |
|---|---|---|
| Battery level over USB for the control panel (named pipe) | 6945c04 | UsbUm `ControlPanel.c` |
| Battery reported to Windows periodically (Bluetooth, every 60 s) | a4e5396 | HidFilter `Battery.c` |
| Per-contact Width/Height/Pressure + Mechanical Force + vendor raw fields in the PTP report | 058bb2a | both drivers, descriptor |
| On-demand haptic click (`IOCTL_PTPFILTER_ACTUATE`, `\\.\AmtPtpHapticDeviceUm`, USB pipe cmd 0x02), `AllowNonAdminAccess` | dd77655 | both drivers, `tools/haptic_test.py` |
| `InvertMovement` setting (upside-down use) | 7d88c75 | both drivers |
| Defaults: StopPressure "do nothing", IgnoreButtonFinger off | b004554 | both drivers, panel |
| TipSwitch reporting rewrite | d9d2658, 85bc270 | both drivers |
| BT: configure the pad off the PnP start path (no hang after pairing) | 05cfaa6 | HidFilter |
| Review fixes: HQA blob, lost reads, stuck pointer-lock, Wellspring transfer size, MT2-only haptic/battery | f2f4256 | both drivers |
| WinUI 3 control panel, localization | 69dac4d, 834683e, 69a87c6, ed9f0e7 | `AmtPtpControlPanel.WinUI3/`, panel |
| `tools/setoption.bat`, `tools/rawinput_test.py` | 54f520b, 489035b | `tools/` |

## Merge decisions (driver/AmtPtpDeviceUsbUm/InputInterrupt.c)

- Our `Rotation` stays. Upstream `InvertMovement` is folded into it as +180 degrees when settings are read:
  upstream's own mirror assumes unrotated spans and would be wrong after a 90/270 rotation. +180 keeps the
  90/270 parity, so the report descriptor swap in `Hid.c` (which reads `Rotation` only) still agrees.
- New Width/Height values are swapped at 90/270 (both share one logical range in the descriptor).
- TipSwitch uses upstream's new rule; our force-click pressure tracking is kept on top of it.
- The X/Y byte block that `AmtPtpSwapXyAxesInReportDescriptor` matches is unchanged upstream (verified).
- `AmtPtpHidFilter/` is byte-identical to upstream (our patches are USB-only).
- INF DriverVer bumped to 2026.3985 (WIN10 INF 2026.3985.2).
- Not taken: upstream `.github/`, `assets/`.

## Verification 2026-11-12

- Build: `utility/Build-MtTrackpad.ps1 -SkipArm64` on n150w -> BUILD_COMPLETE, 0 compiler warnings;
  tray panel `build.ps1` OK.
- SneakyPC has Secure Boot ON and test signing OFF, so the self-signed build cannot load there. Because the
  Bluetooth filter is identical to upstream, the Microsoft-signed upstream v2.3 package
  (`MT2FW11-amd64-20261111-MSSigned.zip`, 2026.3983.1.1000) was installed instead and tested over Bluetooth:
  - battery IOCTL 0x801 -> 31 %; Windows properties `{104EA319-...} 2` and `PKEY_Devices_BatteryLife` = 31
  - haptic ACTUATE light/medium/firm via `\\.\AmtPtpHapticDeviceUm` -> ok; other IOCTLs rejected (as designed)
  - touch pad descriptor exposes 0x0D/0x48 Width, 0x0D/0x49 Height (max 1020), 0x0D/0x30 Pressure and
    0x20/0x494 Mechanical Force (max 1275), vendor 0xFF00/0x02-0x07; input report 112 bytes
  - filter device restart -> touch pad OK after 391 ms, battery + haptics work again
  - existing user settings untouched
- Not tested (needs a finger on the pad or a USB cable): actual pressure/size values while touching
  (`tools/rawinput_test.py`), InvertMovement/rotation feel, USB path (pipe battery, USB haptics), our
  rotation + force click on the merged USB driver.
