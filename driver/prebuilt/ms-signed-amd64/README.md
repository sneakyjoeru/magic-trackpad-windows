# Shipped driver package - Microsoft-signed (AMD64)

This is the package the release archives ship in `driver\`: the upstream
MagicTrackpad2ForWindows driver signed by **Microsoft Windows Hardware
Compatibility Publisher**, so it installs and loads without test signing and
with Secure Boot enabled.

| File | Notes |
|---|---|
| `AmtPtpDevice.inf` | covers the Apple vendor IDs incl. `PID_0324` (USB-C) and its Bluetooth forms |
| `AmtPtpDevice.cat` | Microsoft Hardware Compatibility Publisher signature |
| `AmtPtpDeviceUsbUm.dll` | user-mode driver (WUDF) |
| `AmtPtpHidFilter.sys` | kernel HID filter (Bluetooth + precision touchpad) |

Install:

```powershell
pnputil /add-driver .\AmtPtpDevice.inf /install
pnputil /scan-devices
```

VID `27A7` clones are **not** in this INF. Those units need a self-signed build
(`../../build/make_win10.bat`) installed with `install.ps1 -SelfSigned` and
Windows test signing enabled - see `../../prebuilt/win10-x64/` and
`SETUP-NEW-HOST.md`.
