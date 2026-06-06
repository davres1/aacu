#Requires -Version 5.0
param(
    [int]$FullBackupMaxAgeHours = 30,
    [int]$LogBackupMaxAgeHours = 2,
    [int]$VerifySampleCount = 3
)
<#
.SYNOPSIS
    Verifies recent backups with RESTORE VERIFYONLY and alerts on stale
    backup ages (per database). Pulls history from msdb.
#>

try { Import-Module dbatools -ErrorAction Stop } catch { Write-Error "dbatools missing: $_"; exit 1 }

$ErrorActionPreference = "Continue"
$logFile = "C:\Logs\SQL_BackupVerify_$(Get-Date -Format 'yyyyMMdd').log"
if (-not (Test-Path "C:\Logs")) { New-Item -Path "C:\Logs" -ItemType Directory -Force | Out-Null }
$eventSource = "SQL Server Health Check"

function Log-Message {
    param([string]$Message, [ValidateSet("Information","Warning","Error")][string]$Level = "Information")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
    try { Write-EventLog -LogName Application -Source $eventSource -EventId 1011 -Message $entry -EntryType $Level -ErrorAction SilentlyContinue } catch {}
}

$instances = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty InstalledInstances
if (-not $instances) { $instances = @("MSSQLSERVER") }

$ageReport = [System.Collections.ArrayList]@()
$verifyReport = [System.Collections.ArrayList]@()

foreach ($instance in $instances) {
    $sqlInstance = if ($instance -eq "MSSQLSERVER") { "localhost" } else { "localhost\$instance" }
    Log-Message "Instance: $sqlInstance"

    try {
        $databases = Get-DbaDatabase -SqlInstance $sqlInstance -ExcludeSystem -ErrorAction Stop |
            Where-Object { $_.IsAccessible -and $_.Status -eq 'Normal' }

        foreach ($db in $databases) {
            $fullAgeH = if ($db.LastFullBackup -eq [DateTime]::MinValue) { 999999 } else { ((Get-Date) - $db.LastFullBackup).TotalHours }
            $logAgeH  = if ($db.LastLogBackup  -eq [DateTime]::MinValue) { 999999 } else { ((Get-Date) - $db.LastLogBackup).TotalHours }

            $fullStale = $fullAgeH -gt $FullBackupMaxAgeHours
            $logStale  = ($db.RecoveryModel -ne 'Simple') -and ($logAgeH -gt $LogBackupMaxAgeHours)

            $entry = [pscustomobject]@{
                instance = $sqlInstance; database = $db.Name
                recovery_model = "$($db.RecoveryModel)"
                last_full_hours = [Math]::Round($fullAgeH,1)
                last_log_hours  = [Math]::Round($logAgeH,1)
                full_stale = $fullStale; log_stale = $logStale
            }
            [void]$ageReport.Add($entry)

            if ($fullStale -or $logStale) {
                Log-Message "STALE backup $($db.Name) full=${fullAgeH}h log=${logAgeH}h" "Warning"
            }
        }

        # Verify the last N backup files for this instance with RESTORE VERIFYONLY.
        $recent = Get-DbaDbBackupHistory -SqlInstance $sqlInstance -Last -ErrorAction SilentlyContinue |
            Sort-Object Start -Descending | Select-Object -First $VerifySampleCount
        foreach ($r in $recent) {
            try {
                $ok = $true
                foreach ($file in $r.FullName) {
                    if (-not (Test-Path -LiteralPath $file)) { $ok = $false; break }
                    $q = "RESTORE VERIFYONLY FROM DISK = N'$($file.Replace("'","''"))' WITH CHECKSUM"
                    Invoke-DbaQuery -SqlInstance $sqlInstance -Query $q -EnableException | Out-Null
                }
                [void]$verifyReport.Add([pscustomobject]@{
                    instance = $sqlInstance; database = $r.Database; type = "$($r.Type)"
                    verified = $ok; path = ($r.FullName -join ';')
                })
            } catch {
                Log-Message "VERIFY FAIL $($r.Database): $_" "Error"
                [void]$verifyReport.Add([pscustomobject]@{
                    instance = $sqlInstance; database = $r.Database; type = "$($r.Type)"
                    verified = $false; error = $_.Exception.Message
                })
            }
        }
    } catch { Log-Message "Instance $sqlInstance failed: $_" "Error" }
}

$summary = [pscustomobject]@{
    timestamp = (Get-Date -Format 'o')
    age_thresholds = @{ full_h = $FullBackupMaxAgeHours; log_h = $LogBackupMaxAgeHours }
    stale_full = ($ageReport | Where-Object { $_.full_stale }).Count
    stale_log  = ($ageReport | Where-Object { $_.log_stale  }).Count
    verify_failed = ($verifyReport | Where-Object { -not $_.verified }).Count
    ages = $ageReport
    verifies = $verifyReport
}
$summary | ConvertTo-Json -Depth 6 -Compress
Log-Message "=== BackupVerify finished stale_full=$($summary.stale_full) stale_log=$($summary.stale_log) verify_fail=$($summary.verify_failed) ==="
exit $(if ($summary.stale_full + $summary.stale_log + $summary.verify_failed -gt 0) { 1 } else { 0 })
