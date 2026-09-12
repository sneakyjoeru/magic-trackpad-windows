<#
.SYNOPSIS
  Removes all self-signed certs named 'MtTrackpadBuild' from the CurrentUser\My
  and LocalMachine\{Root,My,CA} stores (stale CertSign-only certs must not be
  reused by Build-MtTrackpad.ps1).
#>
$ErrorActionPreference = 'Stop'
$stores = @('CurrentUser\My', 'LocalMachine\Root', 'LocalMachine\My', 'LocalMachine\CA')
foreach ($s in $stores) {
    $loc = $s.Split('\')[0]; $name = $s.Split('\')[1]
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($name, $loc)
    $store.Open('ReadWrite')
    $found = @($store.Certificates | Where-Object { $_.FriendlyName -eq 'MtTrackpadBuild' })
    foreach ($c in $found) {
        try {
            $store.Remove($c)
            Write-Host "REMOVED $s : $($c.Thumbprint)"
        } catch {
            Write-Host "WARN: remove failed in $s : $($c.Thumbprint) : $($_.Exception.Message)"
        }
    }
    if ($found.Count -eq 0) { Write-Host "NONE in $s" }
    $store.Close()
}
Write-Host "CLEANUP_DONE"
