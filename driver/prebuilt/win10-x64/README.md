# Prebuilt driver package - Windows 10 x64

The exact, working package for the Windows 10 streamer PC: the patched
`AmtPtpDevice.inf` (VID `05AC` **and** `27A7`, Windows 10 section), the
user-mode WUDF driver, the kernel HID filter and the catalog that ties them
together.

| File | Notes |
|---|---|
| `AmtPtpDevice.inf` | `DriverVer = 09/13/2026,2026.3984.1.1000` |
| `AmtPtpDevice.cat` | signed by `MtPtpSigner`, issued by `MtRootCA` |
| `AmtPtpDeviceUsbUm.dll` | user-mode driver (WUDF host) |
| `AmtPtpHidFilter.sys` | kernel HID filter miniport |

The catalog is **self-signed**: the root must be trusted before Windows will
accept the package. Both certificates ship in `certs/` and are imported by
`install.ps1` (or `utility/MtTrackpad.ps1 install`) into `LocalMachine\Root`,
`\CA` and `\TrustedPublisher`.

Install:

```powershell
pnputil /add-driver <this folder>\AmtPtpDevice.inf /install
pnputil /scan-devices
```

Rebuild from source instead with `driver\build\make_win10.bat`
(Visual Studio + WDK); see `SETUP-NEW-HOST.md`.
