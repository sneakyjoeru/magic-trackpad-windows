# Optional self-signed driver package - Windows 10 x64

Kept for reference and for **VID `27A7` clones**, which the Microsoft-signed
package does not cover. This variant is self-signed (`MtPtpSigner` /
`MtRootCA`) and its **kernel** filter only loads when Windows test signing is
enabled:

```powershell
bcdedit /set testsigning on      # Secure Boot must be OFF, then reboot
```

Install it from a release archive with `install.ps1 -SelfSigned` (it trusts the
certificates in `certs\`). Normal machines should use the Microsoft-signed
package in `../ms-signed-amd64/` instead - it needs neither test signing nor
certificates. Turn test signing back off afterwards with
`Restore-Signature-Enforcement.cmd`.

| File | Notes |
|---|---|
| `AmtPtpDevice.inf` | patched: VID `27A7` clones + Windows 10 section, `DriverVer 09/13/2026,2026.3984.1.1000` |
| `AmtPtpDevice.cat` | self-signed by `MtPtpSigner` / `MtRootCA` |
| `AmtPtpDeviceUsbUm.dll` | user-mode driver (WUDF) |
| `AmtPtpHidFilter.sys` | kernel HID filter - **requires test signing** |
