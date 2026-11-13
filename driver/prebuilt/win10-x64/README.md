# Optional self-signed driver package - Windows 10 x64

Kept for reference: the upstream driver with a Windows 10 INF section. This
variant is self-signed and its **kernel** filter only loads when Windows test
signing is enabled:

```powershell
bcdedit /set testsigning on      # Secure Boot must be OFF, then reboot
```

Install it from a release archive with `install.ps1 -SelfSigned` (it trusts the
certificates in `certs\`). Normal machines should use the Microsoft-signed
package in `../ms-signed-amd64/` instead - it needs neither test signing nor
certificates. Turn test signing back off afterwards with
`bcdedit /set testsigning off` and a reboot.

| File | Notes |
|---|---|
| `AmtPtpDevice.inf` | patched: Windows 10 section, `DriverVer 09/13/2026,2026.3984.1.1000` |
| `AmtPtpDevice.cat` | re-generated 2026-11-14, self-signed by `MtTrackpadBuild.local`, timestamped |
| `AmtPtpDeviceUsbUm.dll` | user-mode driver (WUDF) |
| `AmtPtpHidFilter.sys` | kernel HID filter - **requires test signing** |
