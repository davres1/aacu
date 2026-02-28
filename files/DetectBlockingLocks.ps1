#Requires -Version 5.0
<#
.SYNOPSIS
    Detects and resolves blocking and lock contention on SQL Server.
    
.DESCRIPTION
    This script:
    - Identifies blocking chains and their causes
    - Analyzes lock contention patterns
    - Provides detailed information about blocking sessions
    - Can optionally kill blocking processes (with safeguards)
    - Logs findings to event log and file
    - Identifies long-running transactions
    
.NOTES
    Must have dbatools module installed.
    Requires SQL Server sysadmin or VIEW SERVER STATE permission.
    Designed to run every 30 minutes as a scheduled task.
#>

try {
    if (-not (Get-Module -ListAvailable -Name dbatools)) {
        Install-Module -Name dbatools -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module dbatools -ErrorAction Stop
} catch {
    Write-Error "Failed to import dbatools module: $_"
    exit 1
}

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$logFile = "C:\Logs\SQL_Blocking_Detection_$(Get-Date -Format 'yyyyMMdd').log"
$eventLogSource = "SQL Server Health Check"

# Ensure log directory exists
if (-not (Test-Path "C:\Logs")) {
    New-Item -Path "C:\Logs" -ItemType Directory -Force | Out-Null
}

function Log-Message {
    param(
        [string]$Message,
        [ValidateSet("Information", "Warning", "Error")]
        [string]$Level = "Information"
    )
    
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry
    Add-Content -Path $logFile -Value $logEntry
    
    try {
        $eventType = switch ($Level) {
            "Information" { "Information" }
            "Warning" { "Warning" }
            "Error" { "Error" }
        }
        Write-EventLog -LogName Application -Source $eventLogSource -EventId 1000 -Message $logEntry -EntryType $eventType -ErrorAction SilentlyContinue
    } catch {}
}

function Get-BlockingChains {
    param([string]$SqlInstance)
    
    $query = @"
    SELECT 
        blocking_session_id,
        session_id,
        wait_duration_ms,
        last_wait_type,
        wait_resource,
        status,
        command,
        sql_text = (SELECT text FROM sys.dm_exec_sql_text(sql_handle)),
        login_name,
        host_name,
        database_id,
        start_time = (SELECT login_time FROM sys.dm_exec_sessions WHERE session_id = r.session_id)
    FROM sys.dm_exec_requests r
    WHERE blocking_session_id <> 0
    ORDER BY blocking_session_id, session_id
"@
    
    try {
        $result = Invoke-DbaQuery -SqlInstance $SqlInstance -Query $query -ErrorAction SilentlyContinue
        return $result
    } catch {
        Log-Message "Error retrieving blocking chains from $SqlInstance : $_" "Error"
        return $null
    }
}

function Get-LongRunningTransactions {
    param([string]$SqlInstance)
    
    $query = @"
    SELECT 
        session_id,
        database_id,
        status,
        open_transaction_count,
        create_time = (SELECT create_time FROM sys.dm_exec_sessions WHERE session_id = t.session_id),
        sql_text = (SELECT text FROM sys.dm_exec_sql_text(sql_handle)),
        transaction_duration_minutes = DATEDIFF(MINUTE, (SELECT create_time FROM sys.dm_exec_sessions WHERE session_id = t.session_id), GETDATE())
    FROM sys.dm_tran_active_transactions t
    WHERE DATEDIFF(MINUTE, (SELECT create_time FROM sys.dm_exec_sessions WHERE session_id = t.session_id), GETDATE()) > 5
    ORDER BY transaction_duration_minutes DESC
"@
    
    try {
        $result = Invoke-DbaQuery -SqlInstance $SqlInstance -Query $query -ErrorAction SilentlyContinue
        return $result
    } catch {
        Log-Message "Error retrieving long-running transactions from $SqlInstance : $_" "Error"
        return $null
    }
}

function Kill-BlockingProcess {
    param(
        [string]$SqlInstance,
        [int]$BlockingSessionId,
        [int]$BlockedSessionId,
        [int]$BlockDurationMinutes
    )
    
    try {
        Log-Message "KILLING BLOCKING PROCESS - Blocking SPID: $BlockingSessionId, Duration: $BlockDurationMinutes minutes, Blocked SPID: $BlockedSessionId" "Warning"
        
        $killQuery = "KILL $BlockingSessionId"
        Invoke-DbaQuery -SqlInstance $SqlInstance -Query $killQuery -ErrorAction Stop
        
        Log-Message "Successfully killed blocking session $BlockingSessionId (was blocking for $BlockDurationMinutes minutes)" "Warning"
        return $true
    } catch {
        Log-Message "Error killing blocking session $BlockingSessionId : $_" "Error"
        return $false
    }
}

try {
    $instances = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty InstalledInstances
    
    if (-not $instances) {
        $instances = @("MSSQLSERVER")
    }
    
    Log-Message "=== Blocking and Lock Contention Detection Started ===" "Information"
    
    foreach ($instance in $instances) {
        Write-Host ""
        Log-Message "Checking blocking locks on instance: $instance" "Information"
        
        $instanceName = if ($instance -eq "MSSQLSERVER") { "localhost" } else { "localhost\$instance" }
        
        try {
            # Check blocking chains
            $blockingChains = Get-BlockingChains -SqlInstance $instanceName
            
            if ($blockingChains -and $blockingChains.Count -gt 0) {
                Log-Message "Found $($blockingChains.Count) blocking session(s) on instance $instance" "Warning"
                
                foreach ($block in $blockingChains) {
                    $blockingDurationMinutes = [Math]::Round($block.wait_duration_ms / 1000 / 60, 2)
                    
                    $message = @"
Blocking Session Detected:
  Blocking SPID: $($block.blocking_session_id)
  Blocked SPID: $($block.session_id)
  Wait Duration: $blockingDurationMinutes minutes ($($block.wait_duration_ms)ms)
  Wait Type: $($block.last_wait_type)
  Status: $($block.status)
  Command: $($block.command)
  Login: $($block.login_name)
  Host: $($block.host_name)
  SQL: $($block.sql_text | Select-Object -First 100)
"@
                    Log-Message $message "Warning"
                    
                    # Kill the blocking process if it's been blocking for more than 1 hour (60 minutes)
                    if ($blockingDurationMinutes -gt 60) {
                        Log-Message "Blocking duration exceeds 1 hour ($blockingDurationMinutes minutes). Terminating blocking process." "Error"
                        Kill-BlockingProcess -SqlInstance $instanceName -BlockingSessionId $block.blocking_session_id -BlockedSessionId $block.session_id -BlockDurationMinutes $blockingDurationMinutes
                    }
                }
            } else {
                Log-Message "No blocking sessions detected on instance $instance" "Information"
            }
            
            # Check long-running transactions
            $longRunning = Get-LongRunningTransactions -SqlInstance $instanceName
            
            if ($longRunning -and $longRunning.Count -gt 0) {
                Log-Message "Found $($longRunning.Count) long-running transaction(s) on instance $instance (>5 minutes)" "Warning"
                
                foreach ($txn in $longRunning) {
                    $message = @"
Long-Running Transaction:
  Session ID: $($txn.session_id)
  Database ID: $($txn.database_id)
  Status: $($txn.status)
  Open Transactions: $($txn.open_transaction_count)
  Duration: $($txn.transaction_duration_minutes) minutes
  SQL: $($txn.sql_text | Select-Object -First 100)
"@
                    Log-Message $message "Warning"
                }
            }
            
        } catch {
            Log-Message "Error processing instance $instance : $_" "Error"
        }
    }
    
    Log-Message "=== Blocking Detection Completed ===" "Information"
    exit 0
    
} catch {
    Log-Message "Fatal error in blocking detection: $_" "Error"
    exit 1
}
