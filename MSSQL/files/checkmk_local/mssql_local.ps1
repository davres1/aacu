#Requires -Version 5.0
<#
.SYNOPSIS
    CheckMK local plugin (default ~60s cycle).
    Emits one line per check item in CheckMK local-check format:
        <status> <item> <perfdata|-> <details>

    Covers fast-moving health signals:
      - SQL Server service running state
      - SQL Agent running state
      - Current blocked session count (informational; the active cleanup
        is the scheduled DetectBlockingLocks.ps1)
      - AlwaysOn AG database sync health + lag (per AG database, only if HADR enabled)

    Uses Integrated Security as the CheckMK agent's local SYSTEM account.
    Drop in: C:\ProgramData\checkmk\agent\local\
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

$lagWarn = [int](Get-Threshold 'alwayson.lag_warn_sec' 30)
$lagCrit = [int](Get-Threshold 'alwayson.lag_crit_sec' 120)

function Open-Conn { param([string]$Server)
    $cs = "Server=$Server;Database=master;Integrated Security=True;Application Name=CheckMK_local;TrustServerCertificate=True;Connect Timeout=5"
    $cn = New-Object System.Data.SqlClient.SqlConnection $cs
    $cn.Open()
    return $cn
}

function Scalar { param($Conn,[string]$Sql)
    $cmd = $Conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = 10
    return $cmd.ExecuteScalar()
}

function Rows { param($Conn,[string]$Sql)
    $cmd = $Conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = 10
    $a = New-Object System.Data.DataTable
    (New-Object System.Data.SqlClient.SqlDataAdapter($cmd)).Fill($a) | Out-Null
    return $a.Rows
}

$instances = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -ErrorAction SilentlyContinue).InstalledInstances
if (-not $instances) { $instances = @('MSSQLSERVER') }

foreach ($inst in $instances) {
    $server = if ($inst -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$inst" }
    $tag    = if ($inst -eq 'MSSQLSERVER') { 'default' } else { ($inst -replace '[^A-Za-z0-9_-]','_') }

    # ---- Service state (Windows side; fast) ----
    $svcName   = if ($inst -eq 'MSSQLSERVER') { 'MSSQLSERVER'    } else { "MSSQL`$$inst"   }
    $agentName = if ($inst -eq 'MSSQLSERVER') { 'SQLSERVERAGENT' } else { "SQLAgent`$$inst" }
    $svc   = Get-Service -Name $svcName   -ErrorAction SilentlyContinue
    $agent = Get-Service -Name $agentName -ErrorAction SilentlyContinue
    if ($svc) {
        $s = if ($svc.Status -eq 'Running') { 0 } else { 2 }
        Emit $s "MSSQL_Service_$tag" "-" "Status=$($svc.Status)"
    } else {
        Emit 3 "MSSQL_Service_$tag" "-" "Service $svcName not found"
        continue
    }
    if ($agent) {
        $s = if ($agent.Status -eq 'Running') { 0 } else { 1 }
        Emit $s "MSSQL_Agent_$tag" "-" "Status=$($agent.Status)"
    }

    if ($svc.Status -ne 'Running') { continue }

    # ---- Live SQL probes ----
    try {
        $cn = Open-Conn $server

        $blocked = [int](Scalar $cn "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE blocking_session_id <> 0")
        $sev = if ($blocked -ge 10) { 2 } elseif ($blocked -ge 1) { 1 } else { 0 }
        Emit $sev "MSSQL_Blocking_$tag" "blocked=$blocked;1;10" "blocked sessions=$blocked"

        $sessions = [int](Scalar $cn "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE session_id > 50")
        Emit 0 "MSSQL_Sessions_$tag" "sessions=$sessions" "user sessions=$sessions"

        # AlwaysOn (only if HADR enabled)
        $isHadr = [int](Scalar $cn "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS int)")
        if ($isHadr -eq 1) {
            $ag = Rows $cn @"
SELECT ag_name = ag.name,
       database_name = dc.database_name,
       sync_state = drs.synchronization_state_desc,
       sync_health = drs.synchronization_health_desc,
       is_suspended = drs.is_suspended,
       lag_sec = CASE
           WHEN drs.log_send_rate > 0 THEN (drs.log_send_queue_size * 1.0) / drs.log_send_rate
           WHEN drs.redo_rate > 0     THEN (drs.redo_queue_size * 1.0) / drs.redo_rate
           ELSE 0 END
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_databases_cluster dc ON drs.group_database_id = dc.group_database_id
JOIN sys.availability_replicas ar          ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag            ON ar.group_id = ag.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE ars.role_desc = 'PRIMARY'
"@
            foreach ($r in $ag) {
                $lag = [Math]::Round([double]$r.lag_sec, 1)
                $s = 0
                if ($r.is_suspended -or "$($r.sync_health)" -ne 'HEALTHY') { $s = 2 }
                elseif ($lag -ge $lagCrit) { $s = 2 }
                elseif ($lag -ge $lagWarn) { $s = 1 }
                $item = "MSSQL_AG_${tag}_$($r.ag_name)_$($r.database_name)" -replace '[^A-Za-z0-9_-]','_'
                Emit $s $item "lag_sec=$lag;$lagWarn;$lagCrit" "sync=$($r.sync_state) health=$($r.sync_health)"
            }
        }

        $cn.Close()
    } catch {
        Emit 3 "MSSQL_Live_$tag" "-" "probe failed: $($_.Exception.Message)"
    }
}
