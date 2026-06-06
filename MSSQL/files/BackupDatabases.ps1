#Requires -Version 5.0
param(
    [ValidateSet("Full","Diff","Log")]
    [string]$BackupType = "Full",
    [string]$BackupRoot = "C:\Backups",
    [int]$RetentionDays = 14,
    [string[]]$ExcludeDatabase = @("tempdb"),
    [int]$CompressionLevel = 1,
    [int]$Parallel = 4          # databases backed up concurrently
)
<#
.SYNOPSIS
    Parallel FULL / DIFF / LOG backups of every user database on every
    local SQL Server instance, then prune old files. Uses ThreadJob so
    several databases back up at once.
.NOTES
    Scheduling recommendation (set via dba_automation.yaml):
      FULL : daily 22:00, Parallel=4
      DIFF : every 6h,     Parallel=6
      LOG  : every 15min,  Parallel=8
    Emits JSON summary on stdout for the chatbot.
#>

try {
    if (-not (Get-Module -ListAvailable -Name dbatools)) {
        Install-Module dbatools -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module dbatools -ErrorAction Stop
} catch { Write-Error "dbatools unavailable: $_"; exit 1 }

# ThreadJob is in-process and much lighter than Start-Job. Fall back to serial
# only if it can't be installed.
$useThread = $true
try {
    if (-not (Get-Module -ListAvailable -Name ThreadJob)) {
        Install-Module ThreadJob -Force -Scope AllUsers -ErrorAction Stop
    }
    Import-Module ThreadJob -ErrorAction Stop
} catch { $useThread = $false }

$ErrorActionPreference = "Continue"
$logFile = "C:\Logs\SQL_Backup_$(Get-Date -Format 'yyyyMMdd').log"
$eventSource = "SQL Server Health Check"
if (-not (Test-Path "C:\Logs"))   { New-Item -Path "C:\Logs"   -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $BackupRoot)) { New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null }

$logLock = New-Object System.Threading.Mutex($false, "Global\BackupDatabases.ps1.log")
function Log-Message {
    param([string]$Message, [ValidateSet("Information","Warning","Error")][string]$Level = "Information")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $entry
    [void]$logLock.WaitOne(2000); try {
        Add-Content -Path $logFile -Value $entry
        try { Write-EventLog -LogName Application -Source $eventSource -EventId 1010 -Message $entry -EntryType $Level -ErrorAction SilentlyContinue } catch {}
    } finally { $logLock.ReleaseMutex() }
}

$report = [System.Collections.ArrayList]@()
$instances = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -ErrorAction SilentlyContinue).InstalledInstances
if (-not $instances) { $instances = @('MSSQLSERVER') }

Log-Message "=== Backup ($BackupType) started (parallel=$Parallel, thread_jobs=$useThread) ==="

# ----- Build the work queue -----
$work = New-Object System.Collections.ArrayList
foreach ($instance in $instances) {
    $sqlInstance = if ($instance -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$instance" }
    Log-Message "Enumerating $sqlInstance"

    try {
        $databases = Get-DbaDatabase -SqlInstance $sqlInstance -ErrorAction Stop |
            Where-Object { $_.Name -notin $ExcludeDatabase -and $_.Status -eq 'Normal' -and $_.IsAccessible }

        if ($BackupType -eq 'Log') {
            $databases = $databases | Where-Object { $_.RecoveryModel -eq 'Full' -or $_.RecoveryModel -eq 'BulkLogged' }
        } elseif ($BackupType -eq 'Diff') {
            $databases = $databases | Where-Object { $_.LastFullBackup -ne [DateTime]::MinValue }
        }

        $instTag = ($instance -replace '[^A-Za-z0-9_-]','_')
        foreach ($db in $databases) {
            $dir = Join-Path $BackupRoot "$instTag\$($db.Name)\$BackupType"
            if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
            [void]$work.Add([pscustomobject]@{
                Instance = $sqlInstance; Database = $db.Name; Path = $dir; Type = $BackupType
            })
        }
    } catch {
        Log-Message "Instance $sqlInstance enumeration failed: $_" 'Error'
    }
}
Log-Message "Queue: $($work.Count) database(s) to back up"

# ----- Dispatch -----
$jobScript = {
    param($SqlInstance, $Database, $Path, $Type)
    Import-Module dbatools -ErrorAction Stop
    $start = Get-Date
    try {
        $b = Backup-DbaDatabase -SqlInstance $SqlInstance -Database $Database -Path $Path `
                -Type $Type -CompressBackup -Checksum -EnableException -CopyOnly:$false
        $dur = ((Get-Date) - $start).TotalSeconds
        [pscustomobject]@{
            instance = $SqlInstance; database = $Database; type = $Type; status = 'success'
            size_mb  = [Math]::Round($b.TotalSize.Megabyte, 1)
            duration_sec = [Math]::Round($dur, 1)
            path = ($b.Path -join ';')
        }
    } catch {
        [pscustomobject]@{
            instance = $SqlInstance; database = $Database; type = $Type
            status = 'failed'; error = $_.Exception.Message
        }
    }
}

$jobs = New-Object System.Collections.ArrayList
foreach ($w in $work) {
    if ($useThread) {
        while ((@($jobs | Where-Object { $_.State -eq 'Running' })).Count -ge $Parallel) {
            Start-Sleep -Milliseconds 200
        }
        $j = Start-ThreadJob -ArgumentList $w.Instance,$w.Database,$w.Path,$w.Type -ScriptBlock $jobScript
        [void]$jobs.Add($j)
    } else {
        $r = & $jobScript $w.Instance $w.Database $w.Path $w.Type
        [void]$report.Add($r)
        if ($r.status -eq 'success') {
            Log-Message ("OK   {0} [{1}] size={2}MB dur={3}s" -f $r.database,$r.type,$r.size_mb,$r.duration_sec)
        } else {
            Log-Message ("FAIL {0} [{1}] : {2}" -f $r.database,$r.type,$r.error) 'Error'
        }
    }
}

if ($useThread) {
    Log-Message "Waiting for $($jobs.Count) job(s) to complete"
    while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -gt 0) { Start-Sleep -Milliseconds 250 }
    foreach ($j in $jobs) {
        $r = $j | Receive-Job
        if ($r) {
            [void]$report.Add($r)
            if ($r.status -eq 'success') {
                Log-Message ("OK   {0} [{1}] size={2}MB dur={3}s" -f $r.database,$r.type,$r.size_mb,$r.duration_sec)
            } else {
                Log-Message ("FAIL {0} [{1}] : {2}" -f $r.database,$r.type,$r.error) 'Error'
            }
        }
        $j | Remove-Job -Force
    }
}

# ----- Retention sweep -----
try {
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -Path $BackupRoot -Recurse -File -Include *.bak,*.trn,*.dif -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            Log-Message ("Prune {0} (age {1}d)" -f $_.FullName, [int]((Get-Date) - $_.LastWriteTime).TotalDays)
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
} catch { Log-Message "Retention sweep failed: $_" 'Warning' }

$summary = [pscustomobject]@{
    timestamp   = (Get-Date -Format 'o')
    backup_type = $BackupType
    parallel    = $Parallel
    total       = $report.Count
    success     = ($report | Where-Object { $_.status -eq 'success' }).Count
    failed      = ($report | Where-Object { $_.status -eq 'failed'  }).Count
    items       = $report
}
$summary | ConvertTo-Json -Depth 6 -Compress
Log-Message "=== Backup ($BackupType) finished: $($summary.success)/$($summary.total) ok, $($summary.failed) failed ==="
exit $(if ($summary.failed -gt 0) { 1 } else { 0 })
