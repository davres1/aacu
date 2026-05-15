#Requires -Version 5.0
param(
    [int]$DriveFreePercentWarn = 15,
    [int]$DriveFreePercentCrit = 7,
    [int]$DataFileFreePercentWarn = 15,
    [int]$DataFileAutoGrowthDangerMB = 64
)
<#
.SYNOPSIS
    Reports drive free space + per-datafile free space across all instances.
    Flags drives below crit/warn thresholds and datafiles with small
    fixed-MB autogrowth (a common source of file-fragmentation pain).
#>

try { Import-Module dbatools -ErrorAction Stop } catch { Write-Error "dbatools missing: $_"; exit 1 }

$ErrorActionPreference = "Continue"
$logFile = "C:\Logs\SQL_DiskSpace_$(Get-Date -Format 'yyyyMMdd').log"
if (-not (Test-Path "C:\Logs")) { New-Item -Path "C:\Logs" -ItemType Directory -Force | Out-Null }
$eventSource = "SQL Server Health Check"

function Log-Message {
    param([string]$Message, [ValidateSet("Information","Warning","Error")][string]$Level = "Information")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
    try { Write-EventLog -LogName Application -Source $eventSource -EventId 1013 -Message $entry -EntryType $Level -ErrorAction SilentlyContinue } catch {}
}

# Drives
$drives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
    ForEach-Object {
        $totalGB = [Math]::Round($_.Size / 1GB, 1)
        $freeGB  = [Math]::Round($_.FreeSpace / 1GB, 1)
        $pct = if ($totalGB -gt 0) { [Math]::Round(($freeGB / $totalGB) * 100, 1) } else { 0 }
        $sev = if ($pct -lt $DriveFreePercentCrit) { 'critical' }
                elseif ($pct -lt $DriveFreePercentWarn) { 'warning' }
                else { 'ok' }
        if ($sev -ne 'ok') { Log-Message "Drive $($_.DeviceID) $pct% free (${freeGB}/${totalGB} GB)" ($(if ($sev -eq 'critical') {'Error'} else {'Warning'})) }
        [pscustomobject]@{
            drive = $_.DeviceID; total_gb = $totalGB; free_gb = $freeGB
            free_percent = $pct; severity = $sev
        }
    }

# Datafiles per instance
$fileReport = [System.Collections.ArrayList]@()
$instances = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty InstalledInstances
if (-not $instances) { $instances = @("MSSQLSERVER") }

foreach ($instance in $instances) {
    $sqlInstance = if ($instance -eq "MSSQLSERVER") { "localhost" } else { "localhost\$instance" }
    $q = @"
SELECT
    db_name      = DB_NAME(database_id),
    file_id      = file_id,
    logical_name = name,
    physical_name= physical_name,
    type_desc    = type_desc,
    size_mb      = (size * 8) / 1024,
    used_mb      = (FILEPROPERTY(name, 'SpaceUsed') * 8) / 1024,
    growth       = growth,
    is_percent   = is_percent_growth,
    max_size_mb  = CASE WHEN max_size IN (-1, 268435456) THEN -1 ELSE (max_size * 8)/1024 END
FROM sys.master_files
"@
    try {
        $rows = Invoke-DbaQuery -SqlInstance $sqlInstance -Query $q -EnableException
        foreach ($r in $rows) {
            $sizeMB = [int]$r.size_mb
            $usedMB = [int]$r.used_mb
            $freeMB = [Math]::Max(0, $sizeMB - $usedMB)
            $pct = if ($sizeMB -gt 0) { [Math]::Round(($freeMB / $sizeMB) * 100, 1) } else { 100 }

            # Autogrowth health: small fixed-MB autogrowth is a foot-gun.
            $autogrowMB = if ($r.is_percent) {
                if ($sizeMB -gt 0) { [Math]::Round($sizeMB * ($r.growth / 100.0), 0) } else { 0 }
            } else { [int](($r.growth * 8) / 1024) }
            $autogrowConcerns = ($autogrowMB -lt $DataFileAutoGrowthDangerMB)

            $sev = if ($pct -lt $DataFileFreePercentWarn) { 'warning' } else { 'ok' }

            [void]$fileReport.Add([pscustomobject]@{
                instance = $sqlInstance
                database = "$($r.db_name)"
                file_type = "$($r.type_desc)"
                logical_name = "$($r.logical_name)"
                physical_name = "$($r.physical_name)"
                size_mb = $sizeMB; used_mb = $usedMB; free_mb = $freeMB
                free_percent = $pct; severity = $sev
                autogrow_mb = $autogrowMB
                autogrow_concerning = $autogrowConcerns
                max_size_mb = [int]$r.max_size_mb
            })

            if ($sev -ne 'ok') {
                Log-Message "$sqlInstance/$($r.db_name)/$($r.logical_name) $pct% free" "Warning"
            }
        }
    } catch { Log-Message "Instance $sqlInstance failed: $_" "Error" }
}

$summary = [pscustomobject]@{
    timestamp = (Get-Date -Format 'o')
    drives = @($drives)
    datafiles = @($fileReport)
    drive_warnings = (@($drives) | Where-Object { $_.severity -ne 'ok' }).Count
    file_warnings  = (@($fileReport) | Where-Object { $_.severity -ne 'ok' }).Count
    autogrow_concerns = (@($fileReport) | Where-Object { $_.autogrow_concerning }).Count
}
$summary | ConvertTo-Json -Depth 6 -Compress
Log-Message "=== DiskSpace finished drives_warn=$($summary.drive_warnings) file_warn=$($summary.file_warnings) ==="
exit 0
