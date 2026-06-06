#Requires -Version 5.0
param(
    [int]$PhysicalOnlyAboveGB = 200,
    [string[]]$ExcludeDatabase = @("tempdb"),
    [int]$Parallel = 2          # CHECKDBs run concurrently. Lower than backups because CHECKDB is heavy on I/O + CPU.
)
<#
.SYNOPSIS
    Parallel DBCC CHECKDB across every user database on every local SQL
    instance. Uses PHYSICAL_ONLY on databases larger than $PhysicalOnlyAboveGB
    so big databases stay within a sensible runtime.
.NOTES
    Writes a compact summary to C:\Logs\checkdb_status.json which the
    CheckMK local plugin (3600s) reads. Schedule weekly during off-peak.
#>

try { Import-Module dbatools -ErrorAction Stop } catch { Write-Error "dbatools missing: $_"; exit 1 }

$useThread = $true
try {
    if (-not (Get-Module -ListAvailable -Name ThreadJob)) {
        Install-Module ThreadJob -Force -Scope AllUsers -ErrorAction Stop
    }
    Import-Module ThreadJob -ErrorAction Stop
} catch { $useThread = $false }

$ErrorActionPreference = "Continue"
$logFile = "C:\Logs\SQL_CHECKDB_$(Get-Date -Format 'yyyyMMdd').log"
if (-not (Test-Path "C:\Logs")) { New-Item -Path "C:\Logs" -ItemType Directory -Force | Out-Null }
$eventSource = "SQL Server Health Check"

$logLock = New-Object System.Threading.Mutex($false, "Global\DBCCCheckDB.ps1.log")
function Log-Message {
    param([string]$Message, [ValidateSet("Information","Warning","Error")][string]$Level = "Information")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $entry
    [void]$logLock.WaitOne(2000); try {
        Add-Content -Path $logFile -Value $entry
        try { Write-EventLog -LogName Application -Source $eventSource -EventId 1012 -Message $entry -EntryType $Level -ErrorAction SilentlyContinue } catch {}
    } finally { $logLock.ReleaseMutex() }
}

$instances = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -ErrorAction SilentlyContinue).InstalledInstances
if (-not $instances) { $instances = @('MSSQLSERVER') }

# ----- Build the work queue -----
$work = New-Object System.Collections.ArrayList
foreach ($instance in $instances) {
    $sqlInstance = if ($instance -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$instance" }
    Log-Message "Enumerating $sqlInstance"
    try {
        $databases = Get-DbaDatabase -SqlInstance $sqlInstance -ErrorAction Stop |
            Where-Object { $_.Name -notin $ExcludeDatabase -and $_.IsAccessible -and $_.Status -eq 'Normal' }
        foreach ($db in $databases) {
            $sizeGB = [Math]::Round(($db.Size / 1024), 1)
            [void]$work.Add([pscustomobject]@{
                Instance = $sqlInstance
                Database = $db.Name
                SizeGB   = $sizeGB
                PhysicalOnly = ($sizeGB -ge $PhysicalOnlyAboveGB)
            })
        }
    } catch {
        Log-Message "Instance $sqlInstance enumeration failed: $_" 'Error'
    }
}
Log-Message "=== CHECKDB started (parallel=$Parallel, thread_jobs=$useThread, queue=$($work.Count)) ==="

# ----- Dispatch -----
$jobScript = {
    param($SqlInstance, $Database, $SizeGB, $PhysicalOnly)
    Import-Module dbatools -ErrorAction Stop
    $start = Get-Date
    try {
        $q = "DBCC CHECKDB(N'$Database') WITH NO_INFOMSGS, ALL_ERRORMSGS"
        if ($PhysicalOnly) { $q += ", PHYSICAL_ONLY" }
        $msgs = Invoke-DbaQuery -SqlInstance $SqlInstance -Query $q -EnableException -MessagesToOutput
        $dur = ((Get-Date) - $start).TotalSeconds
        $errCount = if ($msgs) { @($msgs).Count } else { 0 }
        [pscustomobject]@{
            instance = $SqlInstance; database = $Database
            size_gb = $SizeGB; physical_only = $PhysicalOnly
            duration_sec = [Math]::Round($dur, 1)
            status = $(if ($errCount -eq 0) { 'clean' } else { 'errors' })
            error_messages = $(if ($msgs) {
                $s = ($msgs | Out-String).Trim()
                $s.Substring(0, [Math]::Min(800, $s.Length))
            } else { $null })
        }
    } catch {
        [pscustomobject]@{
            instance = $SqlInstance; database = $Database
            size_gb = $SizeGB; physical_only = $PhysicalOnly
            status = 'failed'; error = $_.Exception.Message
        }
    }
}

$jobs   = New-Object System.Collections.ArrayList
$report = New-Object System.Collections.ArrayList
foreach ($w in $work) {
    if ($useThread) {
        while ((@($jobs | Where-Object { $_.State -eq 'Running' })).Count -ge $Parallel) {
            Start-Sleep -Milliseconds 500
        }
        $j = Start-ThreadJob -ArgumentList $w.Instance,$w.Database,$w.SizeGB,$w.PhysicalOnly -ScriptBlock $jobScript
        [void]$jobs.Add($j)
        Log-Message "Dispatched CHECKDB $($w.Database) ($($w.SizeGB)GB, physical_only=$($w.PhysicalOnly))"
    } else {
        $r = & $jobScript $w.Instance $w.Database $w.SizeGB $w.PhysicalOnly
        [void]$report.Add($r)
        Log-Message ("{0,-6} CHECKDB {1} ({2}GB, {3}s)" -f $r.status.ToUpper(), $r.database, $r.size_gb, $r.duration_sec) $(if ($r.status -eq 'clean') { 'Information' } else { 'Error' })
    }
}

if ($useThread) {
    Log-Message "Waiting for $($jobs.Count) CHECKDB job(s) to complete"
    while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -gt 0) { Start-Sleep -Seconds 1 }
    foreach ($j in $jobs) {
        $r = $j | Receive-Job
        if ($r) {
            [void]$report.Add($r)
            Log-Message ("{0,-6} CHECKDB {1} ({2}GB, {3}s)" -f $r.status.ToUpper(), $r.database, $r.size_gb, $r.duration_sec) $(if ($r.status -eq 'clean') { 'Information' } else { 'Error' })
        }
        $j | Remove-Job -Force
    }
}

$summary = [pscustomobject]@{
    timestamp = (Get-Date -Format 'o')
    parallel  = $Parallel
    total     = $report.Count
    clean     = ($report | Where-Object { $_.status -eq 'clean'  }).Count
    errors    = ($report | Where-Object { $_.status -eq 'errors' }).Count
    failed    = ($report | Where-Object { $_.status -eq 'failed' }).Count
    items     = $report
}
$json = $summary | ConvertTo-Json -Depth 6 -Compress
$json
try {
    Set-Content -Path 'C:\Logs\checkdb_status.json' -Value $json -Encoding UTF8 -Force
} catch {
    Log-Message "Could not write C:\Logs\checkdb_status.json : $_" 'Warning'
}
Log-Message "=== CHECKDB finished clean=$($summary.clean) errors=$($summary.errors) failed=$($summary.failed) ==="
exit $(if ($summary.errors + $summary.failed -gt 0) { 1 } else { 0 })
