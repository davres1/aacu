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
        # If event log fails, just log to console
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
            
            # Wait for service to stabilize
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

Log-Event "=== SQL Server Health Check Started ===" -EventId 1000 -EntryType Information

try {
    # Get all SQL Server instances
    $instances = @()
    
    # Try to get instances from registry
    $sqlInstances = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue
    $sqlInstanceNames = $sqlInstances.InstalledInstances
    
    if ($sqlInstanceNames) {
        foreach ($name in $sqlInstanceNames) {
            if ($name -eq "MSSQLSERVER") {
                $instances += "MSSQLSERVER"
            } else {
                $instances += "MSSQL`$$name"
            }
        }
    } else {
        # Fallback to default instance
        $instances = @("MSSQLSERVER")
    }
    
    Log-Event "Found SQL Server instances: $($instances -join ', ')" -EventId 1001

    # Check each SQL Server instance
    foreach ($instance in $instances) {
        Write-Host ""
        Write-Host "Checking instance: $instance" -ForegroundColor Cyan
        
        # Check SQL Server service
        try {
            $service = Get-Service -Name $instance -ErrorAction Stop
            
            if ($service.Status -ne 'Running') {
                Log-Event "SQL Server instance '$instance' is not running. Status: $($service.Status)" -EventId 1003 -EntryType Warning
                Write-Host "Service is stopped. Attempting to start..." -ForegroundColor Yellow
                
                if (Start-ServiceSafely -ServiceName $instance) {
                    $restartedServices += $instance
                } else {
                    $allServicesHealthy = $false
                }
            } else {
                Log-Event "SQL Server instance '$instance' is running." -EventId 1001
                Write-Host "Status: Running" -ForegroundColor Green
            }
            
        } catch {
            Write-Host "Error checking SQL Server service '$instance': $_" -ForegroundColor Red
            Log-Event "Error checking SQL Server service '$instance': $_" -EventId 1003 -EntryType Error
            $allServicesHealthy = $false
            continue
        }
        
        # Check SQL Server Agent (if applicable)
        $agentServiceName = if ($instance -eq "MSSQLSERVER") { "SQLSERVERAGENT" } else { "SQLAgent`$$($instance.Split('$')[1])" }
        
        try {
            $agentService = Get-Service -Name $agentServiceName -ErrorAction SilentlyContinue
            
            if ($agentService) {
                if ($agentService.Status -ne 'Running') {
                    Log-Event "SQL Agent for instance '$instance' is not running. Status: $($agentService.Status)" -EventId 1003 -EntryType Warning
                    Write-Host "SQL Agent is stopped. Attempting to start..." -ForegroundColor Yellow
                    
                    if (Start-ServiceSafely -ServiceName $agentServiceName) {
                        $restartedServices += $agentServiceName
                    } else {
                        $allServicesHealthy = $false
                    }
                } else {
                    Log-Event "SQL Agent for instance '$instance' is running." -EventId 1001
                    Write-Host "SQL Agent Status: Running" -ForegroundColor Green
                }
            }
        } catch {
            Write-Host "Warning: Could not check SQL Agent for instance '$instance': $_"
        }
    }
    
    # Check Check MK Service
    Write-Host ""
    Write-Host "Checking Check MK Service..." -ForegroundColor Cyan
    
    try {
        $checkmkService = Get-Service -Name "CheckmkService" -ErrorAction SilentlyContinue
        
        if ($checkmkService) {
            if ($checkmkService.Status -ne 'Running') {
                Log-Event "CheckmkService is not running. Status: $($checkmkService.Status)" -EventId 1003 -EntryType Warning
                Write-Host "Check MK Service is stopped. Attempting to start..." -ForegroundColor Yellow
                
                if (Start-ServiceSafely -ServiceName "CheckmkService") {
                    $restartedServices += "CheckmkService"
                } else {
                    $allServicesHealthy = $false
                }
            } else {
                Log-Event "CheckmkService is running." -EventId 1001
                Write-Host "Check MK Service Status: Running" -ForegroundColor Green
            }
        } else {
            Write-Host "CheckmkService not found on this system."
        }
    } catch {
        Write-Host "Error checking CheckmkService: $_" -ForegroundColor Red
    }
    
    # Summary
    Write-Host ""
    Write-Host "=== Health Check Summary ===" -ForegroundColor Cyan
    
    if ($allServicesHealthy -and $restartedServices.Count -eq 0) {
        Log-Event "All services are healthy. No restarts needed." -EventId 1001 -EntryType Information
        Write-Host "All services are running." -ForegroundColor Green
        exit 0
    } elseif ($restartedServices.Count -gt 0) {
        Log-Event "Services restarted: $($restartedServices -join ', ')" -EventId 1002 -EntryType Information
        Write-Host "Restarted services: $($restartedServices -join ', ')" -ForegroundColor Green
        exit 1
    } else {
        Log-Event "Health check completed with errors. Please review." -EventId 1003 -EntryType Error
        Write-Host "Health check completed with errors." -ForegroundColor Red
        exit 2
    }
    
} catch {
    Log-Event "Fatal error during health check: $_" -EventId 1003 -EntryType Error
    Write-Host "Fatal error: $_" -ForegroundColor Red
    exit 2
}
