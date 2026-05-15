#Requires -Version 5.0
<#
.SYNOPSIS
    CheckMK local plugin, 5-minute interval.
    Emits drive %, per-datafile %, tempdb usage, and PAGELATCH avg waits.
    Drop in: C:\ProgramData\checkmk\agent\local\300\
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

$driveWarn   = [int](Get-Threshold 'disk.drive_free_pct_warn'    15)
$driveCrit   = [int](Get-Threshold 'disk.drive_free_pct_crit'    7)
$dfileWarn   = [int](Get-Threshold 'disk.datafile_free_pct_warn' 15)
$dfileCrit   = [int](Get-Threshold 'disk.datafile_free_pct_crit' 5)
$tempFull    = [int](Get-Threshold 'tempdb.full_percent'         85)
$tempContend = [int](Get-Threshold 'tempdb.alloc_contention_ms'  50)

# ---- Drives ----
foreach ($d in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') {
    if (-not $d.Size) { continue }
    $totalGB = [Math]::Round($d.Size / 1GB, 1)
    $freeGB  = [Math]::Round($d.FreeSpace / 1GB, 1)
    $pct     = if ($totalGB -gt 0) { [Math]::Round(($freeGB / $totalGB) * 100, 1) } else { 0 }
    $sev = if ($pct -lt $driveCrit) { 2 } elseif ($pct -lt $driveWarn) { 1 } else { 0 }
    $item = ("Disk_" + ($d.DeviceID -replace '[^A-Za-z0-9]','_'))
    Emit $sev $item "free_pct=$pct;$driveWarn;$driveCrit|free_gb=$freeGB" "$freeGB of $totalGB GB free ($pct%)"
}

# ---- Per-instance: datafiles + tempdb + PAGELATCH ----
$instances = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -ErrorAction SilentlyContinue).InstalledInstances
if (-not $instances) { $instances = @('MSSQLSERVER') }

foreach ($inst in $instances) {
    $server = if ($inst -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$inst" }
    $tag    = if ($inst -eq 'MSSQLSERVER') { 'default' } else { ($inst -replace '[^A-Za-z0-9_-]','_') }

    try {
        $cs = "Server=$server;Database=master;Integrated Security=True;Application Name=CheckMK_local_5m;TrustServerCertificate=True;Connect Timeout=5"
        $cn = New-Object System.Data.SqlClient.SqlConnection $cs
        $cn.Open()

        # ---- Datafiles (skip log files for the free % check; report log size only) ----
        $cmd = $cn.CreateCommand()
        $cmd.CommandTimeout = 10
        $cmd.CommandText = @"
SELECT db = DB_NAME(database_id),
       logical = name,
       type_desc,
       size_mb = (size * 8) / 1024,
       used_mb = (FILEPROPERTY(name,'SpaceUsed') * 8) / 1024
FROM sys.master_files
WHERE database_id > 4
"@
        $dt = New-Object System.Data.DataTable
        (New-Object System.Data.SqlClient.SqlDataAdapter($cmd)).Fill($dt) | Out-Null
        foreach ($r in $dt.Rows) {
            $size = [int]$r.size_mb; $used = [int]$r.used_mb
            $free = [Math]::Max(0, $size - $used)
            $pct  = if ($size -gt 0) { [Math]::Round(($free / [double]$size) * 100, 1) } else { 100 }
            $sev = if ("$($r.type_desc)" -eq 'ROWS' -and $pct -lt $dfileCrit) { 2 }
                   elseif ("$($r.type_desc)" -eq 'ROWS' -and $pct -lt $dfileWarn) { 1 }
                   else { 0 }
            $item = "Datafile_${tag}_$($r.db)_$($r.logical)" -replace '[^A-Za-z0-9_-]','_'
            Emit $sev $item "free_pct=$pct;$dfileWarn;$dfileCrit|size_mb=$size|used_mb=$used" "$($r.type_desc) $free MB free of $size MB ($pct%)"
        }

        # ---- tempdb ----
        $cmd.CommandText = @"
SELECT name,
       size_mb = (size * 8) / 1024,
       used_mb = (FILEPROPERTY(name,'SpaceUsed') * 8) / 1024
FROM tempdb.sys.database_files
WHERE type = 0
"@
        $td = New-Object System.Data.DataTable
        (New-Object System.Data.SqlClient.SqlDataAdapter($cmd)).Fill($td) | Out-Null
        foreach ($r in $td.Rows) {
            $size = [int]$r.size_mb; $used = [int]$r.used_mb
            $pct = if ($size -gt 0) { [Math]::Round(($used / [double]$size) * 100, 1) } else { 0 }
            $tempWarn = [int]([Math]::Max(0, $tempFull - 10))
            $sev = if ($pct -ge $tempFull) { 2 } elseif ($pct -ge $tempWarn) { 1 } else { 0 }
            $item = "MSSQL_TempDB_${tag}_$($r.name)" -replace '[^A-Za-z0-9_-]','_'
            Emit $sev $item "used_pct=$pct;$tempWarn;$tempFull|size_mb=$size|used_mb=$used" "tempdb $($r.name) $pct% used"
        }

        # ---- PAGELATCH contention ----
        $cmd.CommandText = @"
SELECT max_avg = MAX(CASE WHEN waiting_tasks_count = 0 THEN 0 ELSE wait_time_ms / waiting_tasks_count END)
FROM sys.dm_os_wait_stats
WHERE wait_type IN ('PAGELATCH_EX','PAGELATCH_SH','PAGELATCH_UP')
"@
        $avg = [int]($cmd.ExecuteScalar())
        $tcCrit = [int]($tempContend * 4)
        $sev = if ($avg -ge $tcCrit) { 2 } elseif ($avg -ge $tempContend) { 1 } else { 0 }
        Emit $sev "MSSQL_TempDB_Contention_$tag" "avg_pagelatch_ms=$avg;$tempContend;$tcCrit" "PAGELATCH avg wait ${avg}ms"

        $cn.Close()
    } catch {
        Emit 3 "MSSQL_Disk_TempDB_$tag" "-" "probe failed: $($_.Exception.Message)"
    }
}
