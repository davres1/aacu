<#
.SYNOPSIS
    Starts a SQL Server Windows service.
.PARAMETER ServerInstance
    SQL Server instance, e.g. "." or "HOST\SQLEXPRESS". Used to derive the service name.
#>
param(
    [string]$ServerInstance = "."
)

. "$PSScriptRoot\_common.ps1"

# Derive Windows service name from instance
if ($ServerInstance -match "\\(.+)$") {
    $svcName = "MSSQL`$$($Matches[1].ToUpper())"
} else {
    $svcName = "MSSQLSERVER"
}

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Starting service: $svcName"

$svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
if (-not $svc) {
    # Try partial match (named instances)
    $svc = Get-Service | Where-Object { $_.Name -like "MSSQL*" } | Select-Object -First 1
    if (-not $svc) {
        Write-Error "No SQL Server service found for instance: $ServerInstance"
        Save-Action -Status FAIL -DbName $ServerInstance -Message "no SQL Server service found for instance $ServerInstance"
        exit 1
    }
    Write-Host "Found service: $($svc.Name)"
}

if ($svc.Status -eq 'Running') {
    Write-Host "Service $($svc.Name) is already Running."
    Save-Action -Status INFO -DbName $ServerInstance -Message "service $($svc.Name) already Running — no action"
    exit 0
}

Start-Service -Name $svc.Name -ErrorAction Stop

# Poll for up to 60 seconds
$limit = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $limit) {
    Start-Sleep -Seconds 3
    $status = (Get-Service -Name $svc.Name).Status
    if ($status -eq 'Running') {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Service $($svc.Name) is now Running."
        Save-Action -Status DONE -DbName $ServerInstance -Message "started SQL Server service $($svc.Name)"
        exit 0
    }
}

Write-Error "Service $($svc.Name) did not reach Running state within 60s."
Save-Action -Status FAIL -DbName $ServerInstance -Message "service $($svc.Name) did not reach Running within 60s"
exit 1
