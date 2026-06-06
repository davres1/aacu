#Requires -Version 5.0
param(
    [int]$BuildMinAge_Days = 180   # warn if SQL build older than this
)
<#
.SYNOPSIS
    Reports the build/CU level of every local SQL Server instance plus the
    Windows OS version + last patch date, so the chatbot can flag servers
    falling behind on patching cadence.
#>

try { Import-Module dbatools -ErrorAction Stop } catch { Write-Error "dbatools missing: $_"; exit 1 }

$ErrorActionPreference = "Continue"
$logFile = "C:\Logs\SQL_PatchLevel_$(Get-Date -Format 'yyyyMMdd').log"
if (-not (Test-Path "C:\Logs")) { New-Item -Path "C:\Logs" -ItemType Directory -Force | Out-Null }
$eventSource = "SQL Server Health Check"

function Log-Message {
    param([string]$Message, [ValidateSet("Information","Warning","Error")][string]$Level = "Information")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
    try { Write-EventLog -LogName Application -Source $eventSource -EventId 1017 -Message $entry -EntryType $Level -ErrorAction SilentlyContinue } catch {}
}

$instances = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty InstalledInstances
if (-not $instances) { $instances = @("MSSQLSERVER") }

$sqlReport = [System.Collections.ArrayList]@()

foreach ($instance in $instances) {
    $sqlInstance = if ($instance -eq "MSSQLSERVER") { "localhost" } else { "localhost\$instance" }
    try {
        $build = Get-DbaBuild -SqlInstance $sqlInstance -ErrorAction Stop
        $supported = $true
        $issues = @()
        if ($build.SupportedUntil -and $build.SupportedUntil -lt (Get-Date)) {
            $supported = $false
            $issues += "Out of mainstream support since $($build.SupportedUntil.ToString('yyyy-MM-dd'))"
        }
        if ($build.BuildAge -gt $BuildMinAge_Days) {
            $issues += "Build is $($build.BuildAge) days old (> ${BuildMinAge_Days}d threshold)"
        }
        [void]$sqlReport.Add([pscustomobject]@{
            instance = $sqlInstance
            build = "$($build.Build)"; sp_level = "$($build.SPLevel)"; cu_level = "$($build.CULevel)"
            version_name = "$($build.NameLevel)"; edition = "$($build.Edition)"
            build_age_days = [int]$build.BuildAge
            supported_until = "$($build.SupportedUntil)"
            supported = $supported
            issues = $issues
        })
        if ($issues.Count) { Log-Message "$sqlInstance build issues: $($issues -join '; ')" "Warning" }
    } catch { Log-Message "Build check failed on $sqlInstance : $_" "Error" }
}

# Windows patch state
$osInfo = Get-CimInstance Win32_OperatingSystem
$lastHotfix = Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 1
$osReport = [pscustomobject]@{
    caption = "$($osInfo.Caption)"
    version = "$($osInfo.Version)"
    build = "$($osInfo.BuildNumber)"
    install_date = $osInfo.InstallDate
    last_boot = $osInfo.LastBootUpTime
    last_hotfix_id = if ($lastHotfix) { "$($lastHotfix.HotFixID)" } else { $null }
    last_hotfix_date = if ($lastHotfix) { $lastHotfix.InstalledOn } else { $null }
    last_hotfix_age_days = if ($lastHotfix) { [int]((Get-Date) - $lastHotfix.InstalledOn).TotalDays } else { $null }
}

$summary = [pscustomobject]@{
    timestamp = (Get-Date -Format 'o')
    sql_instances = @($sqlReport)
    os = $osReport
    unsupported = ($sqlReport | Where-Object { -not $_.supported }).Count
    behind = ($sqlReport | Where-Object { $_.build_age_days -gt $BuildMinAge_Days }).Count
}
$summary | ConvertTo-Json -Depth 6 -Compress
Log-Message "=== PatchLevel unsupported=$($summary.unsupported) behind=$($summary.behind) ==="
exit $(if ($summary.unsupported -gt 0) { 1 } else { 0 })
