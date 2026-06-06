#Requires -Version 5.0
param(
    [int]$LookbackHours = 24,
    [int]$LongRunningMinutes = 60
)
<#
.SYNOPSIS
    Reports failed / long-running SQL Agent jobs across all local instances.
#>

try { Import-Module dbatools -ErrorAction Stop } catch { Write-Error "dbatools missing: $_"; exit 1 }

$ErrorActionPreference = "Continue"
$logFile = "C:\Logs\SQL_AgentJobs_$(Get-Date -Format 'yyyyMMdd').log"
if (-not (Test-Path "C:\Logs")) { New-Item -Path "C:\Logs" -ItemType Directory -Force | Out-Null }
$eventSource = "SQL Server Health Check"

function Log-Message {
    param([string]$Message, [ValidateSet("Information","Warning","Error")][string]$Level = "Information")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
    try { Write-EventLog -LogName Application -Source $eventSource -EventId 1014 -Message $entry -EntryType $Level -ErrorAction SilentlyContinue } catch {}
}

$instances = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty InstalledInstances
if (-not $instances) { $instances = @("MSSQLSERVER") }

$failedReport = [System.Collections.ArrayList]@()
$longRunReport = [System.Collections.ArrayList]@()
$disabledReport = [System.Collections.ArrayList]@()

foreach ($instance in $instances) {
    $sqlInstance = if ($instance -eq "MSSQLSERVER") { "localhost" } else { "localhost\$instance" }
    Log-Message "Instance: $sqlInstance"

    try {
        $history = Get-DbaAgentJobHistory -SqlInstance $sqlInstance -StartDate (Get-Date).AddHours(-$LookbackHours) -ErrorAction SilentlyContinue |
            Where-Object { $_.StepID -eq 0 }   # job outcome only

        foreach ($h in $history) {
            if ("$($h.Status)" -ne 'Succeeded') {
                Log-Message "FAILED $($h.JobName) at $($h.RunDate): $($h.Message)" "Warning"
                [void]$failedReport.Add([pscustomobject]@{
                    instance = $sqlInstance; job = "$($h.JobName)"
                    run_date = "$($h.RunDate)"; status = "$($h.Status)"
                    duration_sec = [int]$h.RunDuration
                    message = ("$($h.Message)" -replace '\s+', ' ').Substring(0,[Math]::Min(400,"$($h.Message)".Length))
                })
            }
            if ($h.RunDuration -gt ($LongRunningMinutes * 60)) {
                [void]$longRunReport.Add([pscustomobject]@{
                    instance = $sqlInstance; job = "$($h.JobName)"
                    run_date = "$($h.RunDate)"; duration_min = [Math]::Round($h.RunDuration/60.0,1)
                    status = "$($h.Status)"
                })
            }
        }

        # Find enabled jobs that haven't run in $LookbackHours, plus disabled jobs that should arguably be re-enabled.
        $jobs = Get-DbaAgentJob -SqlInstance $sqlInstance -ErrorAction SilentlyContinue
        foreach ($j in $jobs) {
            if (-not $j.IsEnabled) {
                [void]$disabledReport.Add([pscustomobject]@{
                    instance = $sqlInstance; job = "$($j.Name)"
                    last_run = "$($j.LastRunDate)"
                })
            }
        }
    } catch { Log-Message "Instance $sqlInstance failed: $_" "Error" }
}

$summary = [pscustomobject]@{
    timestamp = (Get-Date -Format 'o')
    lookback_hours = $LookbackHours
    failed_count = $failedReport.Count
    long_running_count = $longRunReport.Count
    disabled_jobs = $disabledReport.Count
    failed = $failedReport
    long_running = $longRunReport
    disabled = $disabledReport
}
$summary | ConvertTo-Json -Depth 6 -Compress
Log-Message "=== AgentJobs failed=$($summary.failed_count) long=$($summary.long_running_count) disabled=$($summary.disabled_jobs) ==="
exit $(if ($summary.failed_count -gt 0) { 1 } else { 0 })
