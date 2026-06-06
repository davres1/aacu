#Requires -Version 5.0
param(
    [int]$LagWarnSec = 30,
    [int]$LagCritSec = 120,
    [int]$SendQueueWarnKB = 100000
)
<#
.SYNOPSIS
    Reports AlwaysOn Availability Group health across all local instances.
    Surfaces:
      - AG and replica state (PRIMARY/SECONDARY, role, sync state)
      - Database-level sync state, suspended databases
      - Send and redo queue sizes
      - Replication lag in seconds (estimated from log_send_rate / queues)
      - Listener health
#>

try { Import-Module dbatools -ErrorAction Stop } catch { Write-Error "dbatools missing: $_"; exit 1 }

$ErrorActionPreference = "Continue"
$logFile = "C:\Logs\SQL_AlwaysOn_$(Get-Date -Format 'yyyyMMdd').log"
if (-not (Test-Path "C:\Logs")) { New-Item -Path "C:\Logs" -ItemType Directory -Force | Out-Null }
$eventSource = "SQL Server Health Check"

function Log-Message {
    param([string]$Message, [ValidateSet("Information","Warning","Error")][string]$Level = "Information")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
    try { Write-EventLog -LogName Application -Source $eventSource -EventId 1018 -Message $entry -EntryType $Level -ErrorAction SilentlyContinue } catch {}
}

$instances = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty InstalledInstances
if (-not $instances) { $instances = @("MSSQLSERVER") }

$report = [System.Collections.ArrayList]@()

foreach ($instance in $instances) {
    $sqlInstance = if ($instance -eq "MSSQLSERVER") { "localhost" } else { "localhost\$instance" }

    try {
        $hadrEnabled = (Invoke-DbaQuery -SqlInstance $sqlInstance -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS v" -EnableException).v
        if (-not $hadrEnabled) {
            Log-Message "$sqlInstance HADR not enabled. Skipping."
            continue
        }
    } catch { Log-Message "Cannot probe HADR on $sqlInstance : $_" "Warning"; continue }

    try {
        $ags = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT
    ag.name             AS ag_name,
    ar.replica_server_name,
    ars.role_desc,
    ars.connected_state_desc,
    ars.synchronization_health_desc,
    ars.operational_state_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar          ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
"@
        $dbStates = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT
    ag.name                              AS ag_name,
    ar.replica_server_name,
    dc.database_name,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.is_suspended,
    drs.suspend_reason_desc,
    drs.log_send_queue_size,
    drs.log_send_rate,
    drs.redo_queue_size,
    drs.redo_rate,
    estimated_lag_sec = CASE
        WHEN drs.log_send_rate > 0 THEN (drs.log_send_queue_size * 1.0) / drs.log_send_rate
        WHEN drs.redo_rate > 0     THEN (drs.redo_queue_size * 1.0) / drs.redo_rate
        ELSE NULL END
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_databases_cluster dc ON drs.group_database_id = dc.group_database_id
JOIN sys.availability_replicas ar          ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag            ON ar.group_id = ag.group_id
"@
        $listeners = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT ag.name AS ag_name, agl.dns_name, agl.port, agl.ip_configuration_string_from_cluster
FROM sys.availability_group_listeners agl
JOIN sys.availability_groups ag ON agl.group_id = ag.group_id
"@

        $dbStateOut = @($dbStates | ForEach-Object {
            $lag = if ($_.estimated_lag_sec -ne $null) { [Math]::Round([double]$_.estimated_lag_sec, 1) } else { $null }
            $sev = 'ok'
            if ($_.is_suspended) { $sev = 'critical' }
            elseif ($_.synchronization_health_desc -ne 'HEALTHY') { $sev = 'critical' }
            elseif ($lag -ne $null -and $lag -ge $LagCritSec) { $sev = 'critical' }
            elseif ($lag -ne $null -and $lag -ge $LagWarnSec) { $sev = 'warning' }
            elseif ($_.log_send_queue_size -ge $SendQueueWarnKB) { $sev = 'warning' }

            [pscustomobject]@{
                ag_name = "$($_.ag_name)"; replica = "$($_.replica_server_name)"
                database = "$($_.database_name)"
                sync_state = "$($_.synchronization_state_desc)"
                sync_health = "$($_.synchronization_health_desc)"
                suspended = [bool]$_.is_suspended
                suspend_reason = "$($_.suspend_reason_desc)"
                log_send_queue_kb = [int]$_.log_send_queue_size
                redo_queue_kb = [int]$_.redo_queue_size
                estimated_lag_sec = $lag
                severity = $sev
            }
        })

        foreach ($d in $dbStateOut) {
            if ($d.severity -ne 'ok') {
                Log-Message "AG '$($d.ag_name)' replica '$($d.replica)' db '$($d.database)' [$($d.severity)] sync=$($d.sync_state) health=$($d.sync_health) lag=$($d.estimated_lag_sec)s" "Warning"
            }
        }

        [void]$report.Add([pscustomobject]@{
            instance = $sqlInstance
            replicas = @($ags | ForEach-Object { [pscustomobject]@{
                ag_name = "$($_.ag_name)"; replica = "$($_.replica_server_name)"
                role = "$($_.role_desc)"; connected = "$($_.connected_state_desc)"
                sync_health = "$($_.synchronization_health_desc)"
                operational = "$($_.operational_state_desc)"
            } })
            databases = $dbStateOut
            listeners = @($listeners | ForEach-Object { [pscustomobject]@{
                ag_name = "$($_.ag_name)"; dns = "$($_.dns_name)"; port = [int]$_.port
            } })
            critical_count = ($dbStateOut | Where-Object { $_.severity -eq 'critical' }).Count
            warning_count  = ($dbStateOut | Where-Object { $_.severity -eq 'warning'  }).Count
        })
    } catch { Log-Message "AG probe failed on $sqlInstance : $_" "Error" }
}

$summary = [pscustomobject]@{
    timestamp = (Get-Date -Format 'o')
    instances = @($report)
    critical = ($report | ForEach-Object { $_.critical_count } | Measure-Object -Sum).Sum
    warning  = ($report | ForEach-Object { $_.warning_count  } | Measure-Object -Sum).Sum
}
$summary | ConvertTo-Json -Depth 7 -Compress
Log-Message "=== AlwaysOn crit=$($summary.critical) warn=$($summary.warning) ==="
exit $(if ($summary.critical -gt 0) { 1 } else { 0 })
