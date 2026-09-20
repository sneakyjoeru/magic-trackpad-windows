# Force-click driver package - self-signed (AMD64)

Built from this repository's source with the force-click patch
(`AmtPtpDeviceUsbUm/InputInterrupt.c` + `include/Device.h`): when the highest
contact pressure reaches the `ForceClickPressure` setting (DWORD, 0 = off,
UCHAR 0-255 range) the driver signals the named event
`Global\MagicTrackpad.ForceClick`; the control panel performs the configured
action with `SendInput`.

Like every modified driver it can no longer carry Microsoft's signature, so this
package is **self-signed** (catalogue signed by `MtRootCA`, timestamped) and
needs Windows **test signing**:

```powershell
bcdedit /set testsigning on      # Secure Boot off, then reboot
..\..\..\install.ps1 -SelfSigned # from the "(force click, self-signed)" archive
```

The touchpad's HID report descriptor is deliberately untouched, so the device
stays a valid Windows Precision Touchpad.

| File | Notes |
|---|---|
| `AmtPtpDevice.inf` | the patched INF (VID `05AC` + `27A7`, Windows 10 section), `DriverVer 09/13/2026,2026.3984.1.1000` |
| `AmtPtpDevice.cat` | signed by `MtRootCA` (self-signed, timestamped) |
| `AmtPtpDeviceUsbUm.dll` | user-mode driver **with** the force-click patch |
| `AmtPtpHidFilter.sys` | unchanged kernel HID filter |
