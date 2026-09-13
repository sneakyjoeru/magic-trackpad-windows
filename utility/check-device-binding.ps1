$ErrorActionPreference = 'Continue'
$enumRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB\VID_05AC&PID_0324&MI_01'
$instances = @(Get-ChildItem $enumRoot -ErrorAction SilentlyContinue)
foreach ($inst in $instances) {
    $drv = (Get-ItemProperty ($inst.PSPath + '\Driver') -ErrorAction SilentlyContinue).Driver
    Write-Host ("INSTANCE: {0}" -f $inst.PSChildName)
    Write-Host ("DRIVER:   {0}" -f $drv)
    $co = (Get-ItemProperty ($inst.PSPath + '\Control') -ErrorAction SilentlyContinue)
    if ($co) { Write-Host ("FLAG:     {0}" -f $co.Flag) }
}
# UMDF service parameters (where the driver reads its settings)
$svc = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WUDF\Services\AmtPtpDeviceUsbUm'
$svcItem = Get-Item $svc -ErrorAction SilentlyContinue
if ($svcItem) {
    Write-Host "SERVICE_KEY: $svc"
    $svcItem.GetValueNames() | ForEach-Object { Write-Host ("  {0} = {1}" -f $_, (Get-ItemProperty $svcItem.PSPath).$_) }
    $params = Get-Item ($svc + '\Parameters') -ErrorAction SilentlyContinue
    if ($params) {
        Write-Host 'PARAMETERS_KEY: present'
        $params.GetValueNames() | ForEach-Object { Write-Host ("  {0} = {1}" -f $_, (Get-ItemProperty $params.PSPath).$_) }
    } else {
        Write-Host 'PARAMETERS_KEY: absent (defaults apply)'
    }
} else {
    Write-Host 'SERVICE_KEY: absent'
}
Write-Host 'BINDING_CHECK_DONE'
