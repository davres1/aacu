#Requires -Version 5.0
param(
    [int]$TempDbFullPercent = 85,
    [int]$AllocContentionWaitMs = 50
)
<#
.SYNOPSIS
    Reports tempdb size/usage, session-level tempdb consumption hotspots,
    and PAGELATCH allocation contention (the classic too-few-tempdb-files
    symptom).
#>

try { Import-Module dbatools -ErrorAction Stop } catch { Write-Error "dbatools missing: $_"; exit 1 }

$ErrorActionPreference = "Continue"
$logFile = "C:\Logs\SQL_TempDB_$(Get-Date -Format 'yyyyMMdd').log"
if (-not (Test-Path "C:\Logs")) { New-Item -Path "C:\Logs" -ItemType Directory -Force | Out-Null }
$eventSource = "SQL Server Health Check"

function Log-Message {
    param([string]$Message, [ValidateSet("Information","Warning","Error")][string]$Level = "Information")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
    try { Write-EventLog -LogName Application -Source $eventSource -EventId 1015 -Message $entry -EntryType $Level -ErrorAction SilentlyContinue } catch {}
}

$instances = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty InstalledInstances
if (-not $instances) { $instances = @("MSSQLSERVER") }

$report = [System.Collections.ArrayList]@()

foreach ($instance in $instances) {
    $sqlInstance = if ($instance -eq "MSSQLSERVER") { "localhost" } else { "localhost\$instance" }

    $fileQ = @"
SELECT
    file_id, name, type_desc,
    size_mb = (size*8)/1024,
    used_mb = (FILEPROPERTY(name,'SpaceUsed')*8)/1024
FROM tempdb.sys.database_files
"@
    $topQ = @"
SELECT TOP 10
    session_id     = t.session_id,
    login_name     = s.login_name,
    host_name      = s.host_name,
    program        = s.program_name,
    user_alloc_mb  = (t.user_objects_alloc_page_count * 8) / 1024,
    internal_alloc_mb = (t.internal_objects_alloc_page_count * 8) / 1024
FROM sys.dm_db_session_space_usage t
JOIN sys.dm_exec_sessions s ON s.session_id = t.session_id
WHERE t.user_objects_alloc_page_count > 0
   OR t.internal_objects_alloc_page_count > 0
ORDER BY (t.user_objects_alloc_page_count + t.internal_objects_alloc_page_count) DESC
"@
    $waitQ = @"
SELECT wait_type,
       waiting_tasks_count,
       wait_time_ms,
       max_wait_time_ms,
       avg_wait_ms = CASE WHEN waiting_tasks_count = 0 THEN 0 ELSE wait_time_ms / waiting_tasks_count END
FROM sys.dm_os_wait_stats
WHERE wait_type IN ('PAGELATCH_EX','PAGELATCH_SH','PAGELATCH_UP')
"@
    try {
        $files = Invoke-DbaQuery -SqlInstance $sqlInstance -Database tempdb -Query $fileQ -EnableException
        $top   = Invoke-DbaQuery -SqlInstance $sqlInstance -Query $topQ  -EnableException
        $wait  = Invoke-DbaQuery -SqlInstance $sqlInstance -Query $waitQ -EnableException

        $fileSummary = $files | ForEach-Object {
            $pct = if ($_.size_mb -gt 0) { [Math]::Round(($_.used_mb / [double]$_.size_mb) * 100, 1) } else { 0 }
            [pscustomobject]@{
                file = "$($_.name)"; type = "$($_.type_desc)"
                size_mb = [int]$_.size_mb; used_mb = [int]$_.used_mb; used_percent = $pct
            }
        }

        $allocContention = @($wait | Where-Object { $_.avg_wait_ms -gt $AllocContentionWaitMs }).Count -gt 0
        $tempdbFull      = @($fileSummary | Where-Object { $_.used_percent -ge $TempDbFullPercent }).Count -gt 0

        if ($tempdbFull)      { Log-Message "$sqlInstance tempdb file > ${TempDbFullPercent}% used" "Warning" }
        if ($allocContention) { Log-Message "$sqlInstance tempdb PAGELATCH contention (avg > ${AllocContentionWaitMs}ms)" "Warning" }

        [void]$report.Add([pscustomobject]@{
            instance         = $sqlInstance
            file_count       = @($files).Count
            files            = @($fileSummary)
            top_consumers    = @($top)
            pagelatch        = @($wait)
            tempdb_full      = $tempdbFull
            alloc_contention = $allocContention
        })
    } catch { Log-Message "Instance $sqlInstance failed: $_" "Error" }
}

$summary = [pscustomobject]@{
    timestamp = (Get-Date -Format 'o')
    instances = @($report)
    full       = ($report | Where-Object { $_.tempdb_full }).Count
    contention = ($report | Where-Object { $_.alloc_contention }).Count
}
$summary | ConvertTo-Json -Depth 6 -Compress
Log-Message "=== TempDB full=$($summary.full) contention=$($summary.contention) ==="
exit 0
