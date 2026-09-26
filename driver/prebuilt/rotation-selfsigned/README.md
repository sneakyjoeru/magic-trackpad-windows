# Rotation + force-click driver package - self-signed (AMD64)

Built from this repository's source on 2026-09-27 with
`utility/Build-MtTrackpad.ps1` (VS 2022 + WDK 10.0.26100), x64 only. It contains
**both** optional driver features:

* **rotation** - reads the `Rotation` DWORD from the driver parameters (`0`, `90`,
  `180`, `270`) and remaps every touch contact. For `90`/`270` it also swaps the
  X/Y logical + physical maxima of the Magic Trackpad 2 HID report descriptor, so
  the rotated surface keeps the pad's real 16 x 11.5 cm proportions.
* **force click** - when the highest contact pressure reaches
  `ForceClickPressure` (DWORD, 0 = off, 0-255) the driver signals the named event
  `Global\MagicTrackpad.ForceClick`; the control panel then performs the configured
  action with `SendInput`.

Like every modified driver it cannot carry Microsoft's signature, so this package
is **self-signed** and needs Windows **test signing**:

```powershell
bcdedit /set testsigning on      # Secure Boot off, then reboot
..\..\..\install.ps1 -SelfSigned # from the "(self-signed)" archive
```

The installer trusts `certs\` (this build is signed by `MtTrackpadBuild.local`),
so no manual certificate import is needed. Back to the Microsoft-signed driver:
`Uninstall-All-Apple-Drivers.cmd -IncludeCerts`, `Install.cmd`,
`bcdedit /set testsigning off`, reboot.

| File | Notes |
|---|---|
| `AmtPtpDevice.inf` | patched INF (VID `05AC` + `27A7`, Windows 10 section), `DriverVer 09/13/2026,2026.3984.2.1000` |
| `AmtPtpDevice.cat` | self-signed by `MtTrackpadBuild.local`, timestamped |
| `AmtPtpDeviceUsbUm.dll` | user-mode driver **with rotation + force click** |
| `AmtPtpHidFilter.sys` | kernel HID filter (rebuilt; rotation is a UMDF-side feature) |

Rotation is implemented in the USB (UMDF) driver only - the Bluetooth path is the
native HID stack with `AmtPtpHidFilter` as a passthrough filter.

The build was compile/sign/inf2cat verified; it has **not** been installed on a
machine with test signing by the release automation.
