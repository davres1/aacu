#Requires -Version 5.0
<#
.SYNOPSIS
    Monitors failed authentication attempts and locks/disables accounts after repeated failures.
    
.DESCRIPTION
    This script:
    - Monitors failed login attempts to SQL Server
    - Tracks failed attempts per account
    - Disables accounts after X failed attempts (configurable)
    - Locks out Windows accounts on repeated failures
    - Sends notifications about account lockouts
    - Logs all actions to event log and file
    - Prevents brute force attacks
    
.NOTES
    Must have dbatools module installed.
    Requires SQL Server sysadmin permission.
    Requires Windows Administrator privileges for account lockout.
    Designed to run every 30 minutes via scheduled task.
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
$logFile = "C:\Logs\SQL_Account_Security_$(Get-Date -Format 'yyyyMMdd').log"
$eventLogSource = "SQL Server Health Check"

# Configuration
$failedAttemptThreshold = 5  # Lock account after this many failures
$monitorWindowMinutes = 30   # Check failed attempts in last N minutes
$disableAccountOnLockout = $true  # Disable SQL Server account when locked out

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
        Write-EventLog -LogName Application -Source $eventLogSource -EventId 1007 -Message $logEntry -EntryType $eventType -ErrorAction SilentlyContinue
    } catch {}
}

function Get-FailedLoginAttempts {
    param([string]$SqlInstance)
    
    $query = @"
    SELECT 
        account_name = CASE 
            WHEN server_principal_name LIKE '%\\%' THEN 'Windows\' + SUBSTRING(server_principal_name, CHARINDEX('\', server_principal_name) + 1, LEN(server_principal_name))
            ELSE server_principal_name
        END,
        failure_count = COUNT(*),
        first_failure = MIN(event_time),
        last_failure = MAX(event_time),
        failure_reason = event_subclass_name
    FROM sys.fn_trace_geteventinfo(default) t
    INNER JOIN sys.traces tr ON t.traceid = tr.id
    WHERE event_id = 20  -- Audit Login Failed
    AND event_time > DATEADD(MINUTE, -$monitorWindowMinutes, GETDATE())
    GROUP BY server_principal_name, event_subclass_name
    HAVING COUNT(*) >= 1
    ORDER BY COUNT(*) DESC
"@
    
    try {
        # Query SQL Server error log for failed logins
        $result = Invoke-DbaQuery -SqlInstance $SqlInstance -Query $query -ErrorAction SilentlyContinue
        
        if (-not $result) {
            # Alternative: Query using dbatools
            $failedLogins = Get-DbaErrorLog -SqlInstance $SqlInstance -LogNumber 0 -ErrorAction SilentlyContinue | 
                Where-Object { $_.Text -like '*failed*' -and $_.ProcessInfo -like '*Login*' }
            return $failedLogins
        }
        return $result
    } catch {
        Log-Message "Error retrieving failed login attempts from $SqlInstance : $_" "Error"
        return $null
    }
}

function Disable-SqlLogin {
    param(
        [string]$SqlInstance,
        [string]$LoginName
    )
    
    $query = "ALTER LOGIN [$LoginName] DISABLE"
    
    try {
        Invoke-DbaQuery -SqlInstance $SqlInstance -Query $query -ErrorAction Stop
        return $true
    } catch {
        Log-Message "Error disabling login $LoginName : $_" "Error"
        return $false
    }
}

function Lock-WindowsAccount {
    param([string]$Username)
    
    try {
        # Check if it's a local account
        $account = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
        
        if ($account) {
            Disable-LocalUser -Name $Username -ErrorAction Stop
            Log-Message "Windows local account '$Username' has been disabled." "Warning"
            return $true
        } else {
            # Try Active Directory
            $adAccount = Get-ADUser -Identity $Username -ErrorAction SilentlyContinue
            if ($adAccount) {
                Disable-ADAccount -Identity $Username -ErrorAction Stop
                Log-Message "Active Directory account '$Username' has been disabled." "Warning"
                return $true
            }
        }
        
        Log-Message "Could not find account '$Username' to disable." "Warning"
        return $false
    } catch {
        Log-Message "Error disabling Windows account '$Username' : $_" "Error"
        return $false
    }
}

function Send-AlertNotification {
    param(
        [string]$Subject,
        [string]$Message,
        [string]$AlertLevel = "Warning"
    )
    
    # Write to event log with high visibility
    try {
        Write-EventLog -LogName Application -Source $eventLogSource -EventId 1008 `
            -Message "SECURITY ALERT: $Message" -EntryType Error -ErrorAction SilentlyContinue
    } catch {}
    
    Log-Message "SECURITY ALERT: $Message" "Error"
}

try {
    $instances = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty InstalledInstances
    
    if (-not $instances) {
        $instances = @("MSSQLSERVER")
    }
    
    Log-Message "=== Account Security Monitor Started ===" "Information"
    
    foreach ($instance in $instances) {
        Write-Host ""
        Log-Message "Checking failed login attempts on instance: $instance" "Information"
        
        $instanceName = if ($instance -eq "MSSQLSERVER") { "localhost" } else { "localhost\$instance" }
        
        try {
            $failedLogins = Get-FailedLoginAttempts -SqlInstance $instanceName
            
            if ($failedLogins) {
                Log-Message "Found failed login attempts on instance $instance" "Warning"
                
                foreach ($failed in $failedLogins) {
                    $accountName = $failed.account_name
                    $failureCount = $failed.failure_count
                    $lastFailure = $failed.last_failure
                    $reason = $failed.failure_reason
                    
                    Log-Message "Account: $accountName | Failed Attempts: $failureCount | Last Failure: $lastFailure | Reason: $reason" "Warning"
                    
                    # If failure count exceeds threshold, take action
                    if ($failureCount -ge $failedAttemptThreshold) {
                        $message = "Account '$accountName' has $failureCount failed login attempts in the last $monitorWindowMinutes minutes. Reason: $reason"
                        
                        # Disable SQL Server login if configured
                        if ($disableAccountOnLockout) {
                            if (Disable-SqlLogin -SqlInstance $instanceName -LoginName $accountName) {
                                Send-AlertNotification "Account Lockout" "SQL Server login '$accountName' has been DISABLED due to $failureCount failed attempts."
                            }
                        }
                        
                        # Try to disable Windows account if it's a domain account
                        if ($accountName -like '*\*') {
                            $domainUser = Split-Path -Leaf $accountName
                            Lock-WindowsAccount -Username $domainUser
                            Send-AlertNotification "Account Lockout" "Windows account '$domainUser' has been DISABLED due to repeated SQL Server login failures."
                        }
                    }
                }
            } else {
                Log-Message "No failed login attempts detected on instance $instance" "Information"
            }
            
        } catch {
            Log-Message "Error processing instance $instance : $_" "Error"
        }
    }
    
    Log-Message "=== Account Security Monitor Completed ===" "Information"
    exit 0
    
} catch {
    Log-Message "Fatal error in account security monitoring: $_" "Error"
    exit 1
}
