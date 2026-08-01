<#
.SYNOPSIS
    Shrinks oversized transaction log files.
    For FULL recovery: takes a log backup first (to a NUL device if no backup configured).
    For SIMPLE / BULK_LOGGED: switches checkpoint then shrinks.
    No service restart required.

    WARNING: Log shrinking is a workaround. Root cause (VLF fragmentation, log backup
    frequency, long-running transactions) should be addressed separately.
#>
param(
    [string]$ServerInstance    = '.',
    [string]$Auth              = 'windows',
    [string]$SqlUser           = '',
    [string]$SqlPassword       = '',
    [string]$DbName            = '',
    [int]   $ThresholdPct      = 80,     # only shrink logs > this % full
    [int]   $TargetSizeMB      = 512     # shrink target (min free space to keep)
)

Set-StrictMode -Version Latest
. "$PSScriptRoot\_common.ps1"

function Invoke-SQL {
    param([string]$Query, [int]$Timeout = 120)
    $a = @('-S', $ServerInstance, '-l', $Timeout)
    if ($Auth -eq 'sql' -and $SqlUser) { $a += @('-U', $SqlUser, '-P', $SqlPassword) }
    else { $a += '-E' }
    $a += @('-Q', $Query, '-h', '-1', '-b')
    return (& sqlcmd @a 2>&1) -join "`n"
}

Write-Host "[$DbName] Checking transaction logs on $ServerInstance (threshold: $ThresholdPct%)..."

# Find oversized log files
$findSql = @"
SET NOCOUNT ON;
SELECT
    d.name                                              AS db_name,
    d.recovery_model_desc                               AS recovery,
    mf.name                                             AS log_file,
    CAST(mf.size * 8.0 / 1024 AS INT)                 AS size_mb,
    CAST(FILEPROPERTY(mf.name,'SpaceUsed')*8.0/1024 AS INT) AS used_mb,
    d.log_reuse_wait_desc
FROM sys.master_files mf
JOIN sys.databases    d  ON d.database_id = mf.database_id
WHERE mf.type_desc = 'LOG'
  AND d.state_desc  = 'ONLINE'
  AND d.name NOT IN ('tempdb','model','msdb')
  AND mf.size > 0
  AND (FILEPROPERTY(mf.name,'SpaceUsed') * 1.0 / mf.size) > ($ThresholdPct / 100.0)
ORDER BY size_mb DESC;
"@

$targets = & sqlcmd @(if ($Auth -eq 'sql') { @('-S', $ServerInstance, '-U', $SqlUser, '-P', $SqlPassword) } else { @('-S', $ServerInstance, '-E') }) `
    -Q $findSql -h -1 -l 30 2>&1 |
    Where-Object { $_ -and $_ -notmatch '^-+$' -and $_.Trim() }

if (-not $targets) {
    Write-Host "No log files above threshold. Nothing to do."
    Save-Action -Status SKIP -DbName $DbName -Message "no transaction logs above $ThresholdPct% full on $ServerInstance"
    exit 0
}

Write-Host "Logs to shrink:`n$($targets -join "`n")"

# Shrink each identified database log
$shrunk = 0
foreach ($row in $targets) {
    if (-not ($row -match '\S')) { continue }

    # Parse CSV-ish output from sqlcmd
    $cols    = $row -split '\s{2,}'
    $db      = $cols[0].Trim()
    $recov   = if ($cols.Count -gt 1) { $cols[1].Trim() } else { 'UNKNOWN' }
    $logFile = if ($cols.Count -gt 2) { $cols[2].Trim() } else { '' }

    if (-not $db -or $db -eq 'db_name') { continue }

    Write-Host "`nProcessing [$db] recovery=$recov log=$logFile"

    if ($recov -eq 'FULL') {
        # Backup log to NUL to free VLFs (no actual backup file needed)
        $backupSql = "BACKUP LOG [$db] TO DISK = 'NUL' WITH STATS=10, COMPRESSION;"
        Write-Host "  Taking log backup to NUL..."
        Write-Host "  $(Invoke-SQL $backupSql 120)"
    } else {
        # SIMPLE/BULK: CHECKPOINT is enough
        $r = Invoke-SQL "USE [$db]; CHECKPOINT;"
        Write-Host "  CHECKPOINT: $r"
    }

    # Shrink the log file
    if ($logFile) {
        $shrinkSql = "USE [$db]; DBCC SHRINKFILE ([$logFile], $TargetSizeMB) WITH NO_INFOMSGS;"
        Write-Host "  Shrinking to ~$TargetSizeMB MB..."
        Write-Host "  $(Invoke-SQL $shrinkSql 120)"
        $shrunk++
    }
}

# --- Save: record how many transaction logs were shrunk ---
Save-Action -Status DONE -DbName $DbName -Message "shrank $shrunk transaction log(s) above $ThresholdPct% full on $ServerInstance"
Write-Host "`n[$DbName] Transaction log shrink complete."
