#Requires -Version 5.0
<#
.SYNOPSIS
    Checks SQL Server instance and SQL Server Agent status, restarts if down.

.DESCRIPTION
    This script:
    - Checks all SQL Server instances on the local machine
    - Verifies if SQL Server service (MSSQLSERVER or named instance) is running
    - Checks if SQL Server Agent is running
    - Checks if CheckmkService (Check MK agent) is running
    - Automatically restarts services if they are stopped
    - Reports all databases with online/offline/other status
    - Reports CPU utilization (SQL Server + total) over the last ~30 minutes
    - Evaluates whether the server is a candidate for CPU core / license reduction
    - Logs all actions and statuses to event log
    - Returns exit codes for monitoring:
      0 = All services running
      1 = One or more services restarted
      2 = One or more services failed to start

.NOTES
    Must be run with administrator privileges.
    Designed to be scheduled via Task Scheduler.
    Logs events to Application event log under 'SQL Server Health Check'.
#>

# Ensure dbatools module is installed
try {
    if (-not (Get-Module -ListAvailable -Name dbatools)) {
        Write-Verbose "Installing dbatools module..."
        Install-Module -Name dbatools -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module dbatools -ErrorAction Stop
} catch {
    Write-Error "Failed to import dbatools module: $_"
    exit 2
}

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$scriptName = "CheckmssqlStatus"
$eventLogSource = "SQL Server Health Check"
$allServicesHealthy = $true
$restartedServices = @()

# Ensure event log source exists
try {
    if (-not [System.Diagnostics.EventLog]::SourceExists($eventLogSource)) {
        New-EventLog -LogName Application -Source $eventLogSource -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "Warning: Could not create event log source: $_"
}

function Log-Event {
    param(
        [string]$Message,
        [int]$EventId = 1000,
        [ValidateSet("Information", "Warning", "Error")]
        [string]$EntryType = "Information"
    )

    $logMessage = "[$timestamp] $Message"
    Write-Host $logMessage

    try {
        Write-EventLog -LogName Application -Source $eventLogSource -EventId $EventId -Message $logMessage -EntryType $EntryType -ErrorAction SilentlyContinue
    } catch {
        Write-Host "Log: $logMessage"
    }
}

function Start-ServiceSafely {
    param(
        [string]$ServiceName,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 5
    )

    $retry = 0
    while ($retry -lt $MaxRetries) {
        try {
            Write-Host "Attempting to start service: $ServiceName (Attempt $($retry + 1)/$MaxRetries)"
            Start-Service -Name $ServiceName -ErrorAction Stop

            Start-Sleep -Seconds 3

            $service = Get-Service -Name $ServiceName -ErrorAction Stop
            if ($service.Status -eq 'Running') {
                Log-Event "Service '$ServiceName' started successfully." -EventId 1002 -EntryType Information
                return $true
            } else {
                Write-Host "Service status after start: $($service.Status)"
            }
        } catch {
            Write-Host "Error starting service '$ServiceName': $_"
            $retry++
            if ($retry -lt $MaxRetries) {
                Write-Host "Waiting $RetryDelaySeconds seconds before retry..."
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    }

    Log-Event "Failed to start service '$ServiceName' after $MaxRetries attempts." -EventId 1003 -EntryType Error
    return $false
}

# Convert service name (e.g. MSSQLSERVER, MSSQL$INST2) to a SQL connection string
function Get-SqlConnectionName {
    param([string]$ServiceName)
    if ($ServiceName -eq "MSSQLSERVER") {
        return $env:COMPUTERNAME
    } else {
        $instancePart = $ServiceName.Split('$')[1]
        return "$env:COMPUTERNAME\$instancePart"
    }
}

# Return a hashtable of databases grouped by state for a given instance
function Get-DatabaseStatus {
    param([string]$SqlInstance)

    $result = [ordered]@{
        Online    = @()
        Offline   = @()
        Restoring = @()
        Other     = @()
        TotalCount = 0
    }

    try {
        $query = @"
SELECT name,
       state_desc,
       recovery_model_desc,
       CAST(ROUND(SUM(size) * 8.0 / 1024, 1) AS DECIMAL(18,1)) AS SizeMB
FROM   sys.databases
CROSS APPLY (SELECT size FROM sys.master_files WHERE database_id = sys.databases.database_id) f
GROUP  BY name, state_desc, recovery_model_desc
ORDER  BY name
"@
        $databases = Invoke-DbaQuery -SqlInstance $SqlInstance -Query $query -ErrorAction Stop

        foreach ($db in $databases) {
            $entry = "$($db.name) ($($db.SizeMB) MB, $($db.recovery_model_desc))"
            switch ($db.state_desc) {
                "ONLINE"    { $result.Online    += $entry }
                "OFFLINE"   { $result.Offline   += $entry }
                "RESTORING" { $result.Restoring += $entry }
                default     { $result.Other     += "$entry [$($db.state_desc)]" }
            }
            $result.TotalCount++
        }
    } catch {
        Write-Host "  Warning: Could not retrieve database list: $_" -ForegroundColor Yellow
    }

    return $result
}

# Query the SQL Server ring buffer for historical CPU data (~30 minutes of 1-min samples)
function Get-SqlCpuUtilization {
    param([string]$SqlInstance)

    $query = @"
SELECT TOP 30
    record_id,
    EventTime,
    SQLProcessUtilization,
    SystemIdle,
    100 - SystemIdle - SQLProcessUtilization AS OtherProcessUtilization,
    100 - SystemIdle                          AS TotalCpuUtilization
FROM (
    SELECT
        record.value('(./Record/@id)[1]', 'int')                                                                                    AS record_id,
        DATEADD(ms, -1 * (ts_now - [timestamp]), GETDATE())                                                                         AS EventTime,
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int')                                  AS SQLProcessUtilization,
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]',         'int')                                  AS SystemIdle
    FROM (
        SELECT [timestamp], CONVERT(XML, record) AS record
        FROM   sys.dm_os_ring_buffers
        WHERE  ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
          AND  record LIKE '%<SystemHealth>%'
    ) AS ring_data
    CROSS JOIN (SELECT cpu_ticks / (cpu_ticks / ms_ticks) AS ts_now FROM sys.dm_os_sys_info) AS ts
) AS data
ORDER BY record_id DESC
"@

    try {
        $rows = Invoke-DbaQuery -SqlInstance $SqlInstance -Query $query -ErrorAction Stop
        if (-not $rows -or $rows.Count -eq 0) { return $null }

        $avgSql   = [math]::Round(($rows | Measure-Object -Property SQLProcessUtilization -Average).Average, 1)
        $maxSql   = [math]::Round(($rows | Measure-Object -Property SQLProcessUtilization -Maximum).Maximum, 1)
        $avgTotal = [math]::Round(($rows | Measure-Object -Property TotalCpuUtilization   -Average).Average, 1)
        $maxTotal = [math]::Round(($rows | Measure-Object -Property TotalCpuUtilization   -Maximum).Maximum, 1)
        $current  = $rows[0].SQLProcessUtilization

        return @{
            CurrentSqlCpu  = $current
            AvgSqlCpu      = $avgSql
            MaxSqlCpu      = $maxSql
            AvgTotalCpu    = $avgTotal
            MaxTotalCpu    = $maxTotal
            SampleMinutes  = $rows.Count
        }
    } catch {
        Write-Host "  Warning: Could not query CPU ring buffer: $_" -ForegroundColor Yellow
        return $null
    }
}

# Determine if the instance is over/under-utilized and flag license reduction opportunity
function Get-UtilizationRecommendation {
    param(
        [string]$SqlInstance,
        [hashtable]$CpuStats
    )

    $result = @{
        LogicalCPUs        = 0
        PhysicalCores      = 0
        LicensedCorePacks  = 0
        UtilizationBand    = "Unknown"
        LicenseCandidate   = $false
        Recommendation     = ""
    }

    try {
        $sysQuery = "SELECT cpu_count, hyperthread_ratio, scheduler_count FROM sys.dm_os_sys_info"
        $sysInfo  = Invoke-DbaQuery -SqlInstance $SqlInstance -Query $sysQuery -ErrorAction Stop

        $result.LogicalCPUs   = $sysInfo.cpu_count
        $ratio                = if ($sysInfo.hyperthread_ratio -gt 1) { $sysInfo.hyperthread_ratio } else { 1 }
        $result.PhysicalCores = [math]::Max(1, [math]::Ceiling($sysInfo.cpu_count / $ratio))
        # SQL Server core licensing sold in 2-core packs (minimum 4 cores per instance)
        $result.LicensedCorePacks = [math]::Ceiling($result.PhysicalCores / 2)
    } catch {
        Write-Host "  Warning: Could not query sys.dm_os_sys_info: $_" -ForegroundColor Yellow
    }

    if (-not $CpuStats) {
        $result.Recommendation = "CPU data unavailable — cannot assess utilization."
        return $result
    }

    $avg = $CpuStats.AvgSqlCpu   # SQL Server share of CPU
    $max = $CpuStats.MaxSqlCpu

    if ($avg -lt 20) {
        $result.UtilizationBand  = "UNDER-UTILIZED"
        $result.LicenseCandidate = $true
        $result.Recommendation   = "Avg SQL CPU $avg% (peak $max%) over last $($CpuStats.SampleMinutes) min. " +
                                   "Server is significantly under-utilized. " +
                                   "CANDIDATE for CPU core reduction and SQL Server license downsizing. " +
                                   "Validate against peak business-hours data before acting."
    } elseif ($avg -lt 50) {
        $result.UtilizationBand  = "LOW-TO-MODERATE"
        $result.LicenseCandidate = $true
        $result.Recommendation   = "Avg SQL CPU $avg% (peak $max%) over last $($CpuStats.SampleMinutes) min. " +
                                   "Utilization is low-to-moderate. " +
                                   "POSSIBLE candidate for license review — analyse peak business-hours data and workload seasonality before reducing cores."
    } elseif ($avg -lt 75) {
        $result.UtilizationBand  = "WELL-UTILIZED"
        $result.LicenseCandidate = $false
        $result.Recommendation   = "Avg SQL CPU $avg% (peak $max%) over last $($CpuStats.SampleMinutes) min. " +
                                   "Server is well-utilized. No license reduction recommended."
    } else {
        $result.UtilizationBand  = "OVER-UTILIZED"
        $result.LicenseCandidate = $false
        $result.Recommendation   = "Avg SQL CPU $avg% (peak $max%) over last $($CpuStats.SampleMinutes) min. " +
                                   "Server is heavily loaded. Consider adding cores, query tuning, or workload offloading."
    }

    return $result
}

# ─────────────────────────────────────────────────────────────
Log-Event "=== SQL Server Health Check Started ===" -EventId 1000 -EntryType Information

try {
    # Discover installed instances from registry
    $instances = @()
    $sqlInstances     = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue
    $sqlInstanceNames = $sqlInstances.InstalledInstances

    if ($sqlInstanceNames) {
        foreach ($name in $sqlInstanceNames) {
            $instances += if ($name -eq "MSSQLSERVER") { "MSSQLSERVER" } else { "MSSQL`$$name" }
        }
    } else {
        $instances = @("MSSQLSERVER")
    }

    Log-Event "Found SQL Server instances: $($instances -join ', ')" -EventId 1001

    foreach ($instance in $instances) {
        Write-Host ""
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
        Write-Host "  Instance: $instance" -ForegroundColor Cyan
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

        # ── Service status ──────────────────────────────────────
        $instanceRunning = $false
        try {
            $service = Get-Service -Name $instance -ErrorAction Stop

            if ($service.Status -ne 'Running') {
                Log-Event "SQL Server instance '$instance' is not running. Status: $($service.Status)" -EventId 1003 -EntryType Warning
                Write-Host "  [SERVICE] Status: $($service.Status)" -ForegroundColor Yellow
                Write-Host "  Attempting to start..." -ForegroundColor Yellow

                if (Start-ServiceSafely -ServiceName $instance) {
                    $restartedServices += $instance
                    $instanceRunning = $true
                } else {
                    $allServicesHealthy = $false
                }
            } else {
                Log-Event "SQL Server instance '$instance' is running." -EventId 1001
                Write-Host "  [SERVICE] Status: Running" -ForegroundColor Green
                $instanceRunning = $true
            }
        } catch {
            Write-Host "  [SERVICE] Error: $_" -ForegroundColor Red
            Log-Event "Error checking SQL Server service '$instance': $_" -EventId 1003 -EntryType Error
            $allServicesHealthy = $false
            continue
        }

        # ── SQL Agent ────────────────────────────────────────────
        $agentServiceName = if ($instance -eq "MSSQLSERVER") { "SQLSERVERAGENT" } else { "SQLAgent`$$($instance.Split('$')[1])" }
        try {
            $agentService = Get-Service -Name $agentServiceName -ErrorAction SilentlyContinue
            if ($agentService) {
                if ($agentService.Status -ne 'Running') {
                    Log-Event "SQL Agent for '$instance' is not running. Status: $($agentService.Status)" -EventId 1003 -EntryType Warning
                    Write-Host "  [AGENT]   Status: $($agentService.Status) — attempting start..." -ForegroundColor Yellow
                    if (Start-ServiceSafely -ServiceName $agentServiceName) {
                        $restartedServices += $agentServiceName
                    } else {
                        $allServicesHealthy = $false
                    }
                } else {
                    Log-Event "SQL Agent for '$instance' is running." -EventId 1001
                    Write-Host "  [AGENT]   Status: Running" -ForegroundColor Green
                }
            } else {
                Write-Host "  [AGENT]   Not installed for this instance." -ForegroundColor Gray
            }
        } catch {
            Write-Host "  [AGENT]   Warning: $_ " -ForegroundColor Yellow
        }

        # ── Database status (only when instance is up) ──────────
        if ($instanceRunning) {
            $sqlConn = Get-SqlConnectionName -ServiceName $instance

            Write-Host ""
            Write-Host "  ── Databases ──────────────────────────────────────" -ForegroundColor Cyan
            $dbStatus = Get-DatabaseStatus -SqlInstance $sqlConn

            Write-Host "  Total databases : $($dbStatus.TotalCount)"

            if ($dbStatus.Online.Count -gt 0) {
                Write-Host "  ONLINE  ($($dbStatus.Online.Count)):" -ForegroundColor Green
                $dbStatus.Online | ForEach-Object { Write-Host "    + $_" -ForegroundColor Green }
            }

            if ($dbStatus.Offline.Count -gt 0) {
                Write-Host "  OFFLINE ($($dbStatus.Offline.Count)):" -ForegroundColor Red
                $dbStatus.Offline | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
                Log-Event "Instance '$instance' has $($dbStatus.Offline.Count) OFFLINE database(s): $($dbStatus.Offline -join '; ')" -EventId 1003 -EntryType Warning
            }

            if ($dbStatus.Restoring.Count -gt 0) {
                Write-Host "  RESTORING ($($dbStatus.Restoring.Count)):" -ForegroundColor Yellow
                $dbStatus.Restoring | ForEach-Object { Write-Host "    ~ $_" -ForegroundColor Yellow }
            }

            if ($dbStatus.Other.Count -gt 0) {
                Write-Host "  OTHER STATE ($($dbStatus.Other.Count)):" -ForegroundColor Yellow
                $dbStatus.Other | ForEach-Object { Write-Host "    ? $_" -ForegroundColor Yellow }
            }

            # ── CPU utilization ─────────────────────────────────
            Write-Host ""
            Write-Host "  ── CPU Utilization (ring buffer, last ~30 min) ────" -ForegroundColor Cyan
            $cpuStats = Get-SqlCpuUtilization -SqlInstance $sqlConn

            if ($cpuStats) {
                Write-Host ("  Current SQL CPU   : {0}%" -f $cpuStats.CurrentSqlCpu)
                Write-Host ("  Avg SQL CPU       : {0}%   (max {1}%)" -f $cpuStats.AvgSqlCpu, $cpuStats.MaxSqlCpu)
                Write-Host ("  Avg Total CPU     : {0}%   (max {1}%)" -f $cpuStats.AvgTotalCpu, $cpuStats.MaxTotalCpu)
                Write-Host ("  Sample window     : {0} minutes"       -f $cpuStats.SampleMinutes)
            } else {
                Write-Host "  CPU data unavailable." -ForegroundColor Yellow
            }

            # ── Utilization & license recommendation ─────────────
            Write-Host ""
            Write-Host "  ── Utilization Assessment & License Recommendation ─" -ForegroundColor Cyan
            $rec = Get-UtilizationRecommendation -SqlInstance $sqlConn -CpuStats $cpuStats

            if ($rec.LogicalCPUs -gt 0) {
                Write-Host ("  Logical CPUs visible to SQL : {0}" -f $rec.LogicalCPUs)
                Write-Host ("  Estimated physical cores    : {0}" -f $rec.PhysicalCores)
                Write-Host ("  Licensed core packs (2-core): {0}  (~{1} cores)" -f $rec.LicensedCorePacks, ($rec.LicensedCorePacks * 2))
            }

            $bandColor = switch ($rec.UtilizationBand) {
                "UNDER-UTILIZED"   { "Red"    }
                "LOW-TO-MODERATE"  { "Yellow" }
                "WELL-UTILIZED"    { "Green"  }
                "OVER-UTILIZED"    { "Magenta" }
                default            { "Gray"   }
            }
            Write-Host ("  Utilization band : {0}" -f $rec.UtilizationBand) -ForegroundColor $bandColor

            if ($rec.LicenseCandidate) {
                Write-Host "  *** LICENSE REDUCTION CANDIDATE ***" -ForegroundColor Red
            }

            Write-Host ("  Recommendation   : {0}" -f $rec.Recommendation) -ForegroundColor $bandColor
            Log-Event "Instance '$instance' — $($rec.UtilizationBand): $($rec.Recommendation)" -EventId 1001
        }
    }

    # ── Check MK Service ────────────────────────────────────────
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  Check MK Service" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    try {
        $checkmkService = Get-Service -Name "CheckmkService" -ErrorAction SilentlyContinue
        if ($checkmkService) {
            if ($checkmkService.Status -ne 'Running') {
                Log-Event "CheckmkService is not running. Status: $($checkmkService.Status)" -EventId 1003 -EntryType Warning
                Write-Host "  Status: $($checkmkService.Status) — attempting start..." -ForegroundColor Yellow
                if (Start-ServiceSafely -ServiceName "CheckmkService") {
                    $restartedServices += "CheckmkService"
                } else {
                    $allServicesHealthy = $false
                }
            } else {
                Log-Event "CheckmkService is running." -EventId 1001
                Write-Host "  Status: Running" -ForegroundColor Green
            }
        } else {
            Write-Host "  CheckmkService not found on this system." -ForegroundColor Gray
        }
    } catch {
        Write-Host "  Error checking CheckmkService: $_" -ForegroundColor Red
    }

    # ── Summary ──────────────────────────────────────────────────
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  Health Check Summary" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    if ($allServicesHealthy -and $restartedServices.Count -eq 0) {
        Log-Event "All services are healthy. No restarts needed." -EventId 1001 -EntryType Information
        Write-Host "  All services are running." -ForegroundColor Green
        exit 0
    } elseif ($restartedServices.Count -gt 0) {
        Log-Event "Services restarted: $($restartedServices -join ', ')" -EventId 1002 -EntryType Information
        Write-Host "  Restarted services: $($restartedServices -join ', ')" -ForegroundColor Yellow
        exit 1
    } else {
        Log-Event "Health check completed with errors. Please review." -EventId 1003 -EntryType Error
        Write-Host "  Health check completed with errors." -ForegroundColor Red
        exit 2
    }

} catch {
    Log-Event "Fatal error during health check: $_" -EventId 1003 -EntryType Error
    Write-Host "Fatal error: $_" -ForegroundColor Red
    exit 2
}
