#Requires -Version 5.0
<#
.SYNOPSIS
    CheckMK local plugin, 10-minute interval.
    Per-database last FULL / LOG backup age + failed Agent jobs in last 24h.
    Drop in: C:\ProgramData\checkmk\agent\local\600\
#>

$ErrorActionPreference = 'SilentlyContinue'

function Emit { param([int]$Status,[string]$Item,[string]$Perf,[string]$Text)
    if (-not $Perf) { $Perf = '-' }
    "$Status $Item $Perf $Text"
}

function Get-Threshold {
    param([string]$Path, $Default)
    if (-not $script:T_INIT) {
        $script:T_INIT = $true
        $f = 'C:\DBA\thresholds.json'
        if (Test-Path $f) { try { $script:T = Get-Content $f -Raw | ConvertFrom-Json } catch { $script:T = $null } }
    }
    if (-not $script:T) { return $Default }
    $obj = $script:T
    foreach ($k in ($Path -split '\.')) {
        if ($null -eq $obj) { return $Default }
        $prop = $obj.PSObject.Properties[$k]
        if (-not $prop) { return $Default }
        $obj = $prop.Value
    }
    if ($null -eq $obj) { return $Default } else { return $obj }
}

$fullWarn = [double](Get-Threshold 'backups.full_max_age_hours' 24)
$fullCrit = [double]([Math]::Max($fullWarn, 48))
$logWarn  = [double](Get-Threshold 'backups.log_max_age_hours'  0.5)
$logCrit  = [double]([Math]::Max($logWarn, 2))
$jobLookback = [int](Get-Threshold 'agent_jobs.lookback_hours' 24)

$instances = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -ErrorAction SilentlyContinue).InstalledInstances
if (-not $instances) { $instances = @('MSSQLSERVER') }

foreach ($inst in $instances) {
    $server = if ($inst -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$inst" }
    $tag    = if ($inst -eq 'MSSQLSERVER') { 'default' } else { ($inst -replace '[^A-Za-z0-9_-]','_') }

    try {
        $cs = "Server=$server;Database=master;Integrated Security=True;Application Name=CheckMK_local_10m;TrustServerCertificate=True;Connect Timeout=5"
        $cn = New-Object System.Data.SqlClient.SqlConnection $cs
        $cn.Open()
        $cmd = $cn.CreateCommand()
        $cmd.CommandTimeout = 15

        # ---- Backups ----
        $cmd.CommandText = @"
SELECT d.name,
       recovery = d.recovery_model_desc,
       full_age_h = DATEDIFF(MINUTE, ISNULL(b.last_full, '1900-01-01'), GETDATE()) / 60.0,
       log_age_h  = DATEDIFF(MINUTE, ISNULL(b.last_log,  '1900-01-01'), GETDATE()) / 60.0
FROM sys.databases d
OUTER APPLY (
    SELECT
        last_full = MAX(CASE WHEN type = 'D' THEN backup_finish_date END),
        last_log  = MAX(CASE WHEN type = 'L' THEN backup_finish_date END)
    FROM msdb.dbo.backupset bs
    WHERE bs.database_name = d.name
) b
WHERE d.database_id > 4 AND d.state = 0 AND d.source_database_id IS NULL
"@
        $dt = New-Object System.Data.DataTable
        (New-Object System.Data.SqlClient.SqlDataAdapter($cmd)).Fill($dt) | Out-Null
        foreach ($r in $dt.Rows) {
            $fullH = [Math]::Round([double]$r.full_age_h, 1)
            $logH  = [Math]::Round([double]$r.log_age_h,  1)
            $simpleRecovery = ("$($r.recovery)" -eq 'SIMPLE')

            # Full backup age severity
            $sevF = if ($fullH -ge $fullCrit) { 2 } elseif ($fullH -ge $fullWarn) { 1 } else { 0 }
            $item = "MSSQL_Backup_Full_${tag}_$($r.name)" -replace '[^A-Za-z0-9_-]','_'
            Emit $sevF $item "age_h=$fullH;$fullWarn;$fullCrit" "last full $fullH h ago, recovery=$($r.recovery)"

            # Log backup age only for non-SIMPLE recovery DBs
            if (-not $simpleRecovery) {
                $sevL = if ($logH -ge $logCrit) { 2 } elseif ($logH -ge $logWarn) { 1 } else { 0 }
                $item = "MSSQL_Backup_Log_${tag}_$($r.name)" -replace '[^A-Za-z0-9_-]','_'
                Emit $sevL $item "age_h=$logH;$logWarn;$logCrit" "last log $logH h ago"
            }
        }

        # ---- Agent jobs (failed in last 24h) ----
        $cmd.CommandText = @"
SELECT
    failed = SUM(CASE WHEN h.run_status <> 1 THEN 1 ELSE 0 END),
    total  = COUNT(*)
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE h.step_id = 0
  AND msdb.dbo.agent_datetime(h.run_date, h.run_time) > DATEADD(HOUR, -$jobLookback, GETDATE())
"@
        $reader = $cmd.ExecuteReader()
        if ($reader.Read()) {
            $failed = if ($reader['failed'] -is [DBNull]) { 0 } else { [int]$reader['failed'] }
            $total  = if ($reader['total']  -is [DBNull]) { 0 } else { [int]$reader['total']  }
            $sev = if ($failed -ge 5) { 2 } elseif ($failed -ge 1) { 1 } else { 0 }
            Emit $sev "MSSQL_Agent_Jobs_$tag" "failed=$failed;1;5|total=$total" "$failed failed of $total job runs in ${jobLookback}h"
        }
        $reader.Close()

        $cn.Close()
    } catch {
        Emit 3 "MSSQL_Backups_Jobs_$tag" "-" "probe failed: $($_.Exception.Message)"
    }
}
