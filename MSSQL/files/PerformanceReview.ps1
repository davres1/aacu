#Requires -Version 5.0
param(
    [int]$LongRunningSeconds = 5,
    [int]$TopN = 10
)
<#
.SYNOPSIS
    Read-only performance review per SQL Server instance: long-running requests,
    top statements by CPU, current blocking, top waits, and missing-index
    recommendations. Emits one compact JSON line (consumed by the chatbot, which
    summarizes it and suggests remediations).
#>

try { Import-Module dbatools -ErrorAction Stop } catch { Write-Error "dbatools missing: $_"; exit 1 }

$ErrorActionPreference = "Continue"
$logFile = "C:\Logs\SQL_PerfReview_$(Get-Date -Format 'yyyyMMdd').log"
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

    $longQ = @"
SELECT TOP $TopN
    session_id   = r.session_id,
    database     = DB_NAME(r.database_id),
    status       = r.status,
    elapsed_sec  = r.total_elapsed_time/1000,
    cpu_ms       = r.cpu_time,
    reads        = r.logical_reads,
    wait_type    = r.wait_type,
    blocked_by   = r.blocking_session_id,
    sql_text     = SUBSTRING(t.text,1,400)
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.session_id > 50 AND r.total_elapsed_time/1000 >= $LongRunningSeconds
ORDER BY r.total_elapsed_time DESC
"@
    $topQ = @"
SELECT TOP $TopN
    executions   = qs.execution_count,
    total_cpu_ms = qs.total_worker_time/1000,
    avg_cpu_ms   = (qs.total_worker_time/1000)/qs.execution_count,
    total_reads  = qs.total_logical_reads,
    avg_elapsed_ms = (qs.total_elapsed_time/1000)/qs.execution_count,
    sql_text     = SUBSTRING(t.text,1,400)
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
ORDER BY qs.total_worker_time DESC
"@
    $blockQ = @"
SELECT
    blocker      = r.blocking_session_id,
    waiter       = r.session_id,
    wait_sec     = r.wait_time/1000,
    wait_type    = r.wait_type,
    resource     = r.wait_resource,
    database     = DB_NAME(r.database_id)
FROM sys.dm_exec_requests r
WHERE r.blocking_session_id <> 0
"@
    $waitQ = @"
SELECT TOP $TopN
    wait_type, waiting_tasks_count,
    wait_time_ms = wait_time_ms,
    avg_wait_ms  = CASE WHEN waiting_tasks_count=0 THEN 0 ELSE wait_time_ms/waiting_tasks_count END
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN ('CLR_SEMAPHORE','LAZYWRITER_SLEEP','RESOURCE_QUEUE','SLEEP_TASK',
    'SLEEP_SYSTEMTASK','SQLTRACE_BUFFER_FLUSH','WAITFOR','LOGMGR_QUEUE','CHECKPOINT_QUEUE',
    'REQUEST_FOR_DEADLOCK_SEARCH','XE_TIMER_EVENT','BROKER_TO_FLUSH','BROKER_TASK_STOP',
    'CLR_MANUAL_EVENT','CLR_AUTO_EVENT','DISPATCHER_QUEUE_SEMAPHORE','FT_IFTS_SCHEDULER_IDLE_WAIT',
    'XE_DISPATCHER_WAIT','XE_DISPATCHER_JOIN','SQLTRACE_INCREMENTAL_FLUSH_SLEEP','ONDEMAND_TASK_QUEUE')
  AND waiting_tasks_count > 0
ORDER BY wait_time_ms DESC
"@
    $miQ = @"
SELECT TOP $TopN
    database      = DB_NAME(mid.database_id),
    improvement   = ROUND(migs.avg_total_user_cost * migs.avg_user_impact * (migs.user_seeks + migs.user_scans),0),
    equality_cols = mid.equality_columns,
    inequality_cols = mid.inequality_columns,
    included_cols = mid.included_columns,
    table_name    = mid.statement
FROM sys.dm_db_missing_index_group_stats migs
JOIN sys.dm_db_missing_index_groups mig ON migs.group_handle = mig.index_group_handle
JOIN sys.dm_db_missing_index_details mid ON mig.index_handle = mid.index_handle
ORDER BY improvement DESC
"@
    try {
        $long  = Invoke-DbaQuery -SqlInstance $sqlInstance -Query $longQ  -EnableException
        $top   = Invoke-DbaQuery -SqlInstance $sqlInstance -Query $topQ   -EnableException
        $block = Invoke-DbaQuery -SqlInstance $sqlInstance -Query $blockQ -EnableException
        $wait  = Invoke-DbaQuery -SqlInstance $sqlInstance -Query $waitQ  -EnableException
        $mi    = Invoke-DbaQuery -SqlInstance $sqlInstance -Query $miQ    -EnableException

        if (@($long).Count)  { Log-Message "$sqlInstance: $(@($long).Count) long-running request(s) >= ${LongRunningSeconds}s" "Warning" }
        if (@($block).Count) { Log-Message "$sqlInstance: $(@($block).Count) blocked request(s)" "Warning" }

        [void]$report.Add([pscustomobject]@{
            instance        = $sqlInstance
            long_running    = @($long)
            top_sql         = @($top)
            blocking        = @($block)
            waits           = @($wait)
            missing_indexes = @($mi)
        })
    } catch { Log-Message "Instance $sqlInstance failed: $_" "Error" }
}

$summary = [pscustomobject]@{
    timestamp     = (Get-Date -Format 'o')
    instances     = @($report)
    long_running  = ($report | ForEach-Object { @($_.long_running).Count } | Measure-Object -Sum).Sum
    blocked       = ($report | ForEach-Object { @($_.blocking).Count } | Measure-Object -Sum).Sum
}
$summary | ConvertTo-Json -Depth 6 -Compress
Log-Message "=== PerfReview long_running=$($summary.long_running) blocked=$($summary.blocked) ==="
exit 0
