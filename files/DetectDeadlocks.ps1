#Requires -Version 5.0
<#
.SYNOPSIS
    Detects SQL Server deadlocks and captures deadlock graphs for analysis.
    
.DESCRIPTION
    This script:
    - Enables SQL Server deadlock graph tracing
    - Queries system for recent deadlock occurrences
    - Captures detailed deadlock graphs
    - Analyzes deadlock patterns
    - Stores deadlock information for later analysis
    - Alerts on deadlock frequency
    - Logs to event log
    
.NOTES
    Must have dbatools module installed.
    Requires SQL Server sysadmin permission.
    Deadlock graph trace must be enabled in SQL Server.
    Designed to run every 30 minutes.
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
$logFile = "C:\Logs\SQL_Deadlock_Detection_$(Get-Date -Format 'yyyyMMdd').log"
$deadlockGraphPath = "C:\Logs\DeadlockGraphs"
$eventLogSource = "SQL Server Health Check"

# Configuration
$deadlockThreshold = 3        # Alert if this many deadlocks in the time window
$monitorWindow = 35           # Minutes to look back for deadlocks
$killDeadlockParticipants = $true  # Kill processes involved in deadlocks
$repeatOffenderThreshold = 2  # Kill if same process in N deadlocks
foreach ($path in @("C:\Logs", $deadlockGraphPath)) {
    if (-not (Test-Path $path)) {
        New-Item -Path $path -ItemType Directory -Force | Out-Null
    }
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
        Write-EventLog -LogName Application -Source $eventLogSource -EventId 1005 -Message $logEntry -EntryType $eventType -ErrorAction SilentlyContinue
    } catch {}
}

function Enable-DeadlockGraphTrace {
    param([string]$SqlInstance)
    
    $query = @"
    IF (SELECT value FROM sys.configurations WHERE name = 'default trace enabled') = 0
    BEGIN
        EXEC sp_configure 'default trace enabled', 1
        RECONFIGURE
    END
"@
    
    try {
        Invoke-DbaQuery -SqlInstance $SqlInstance -Query $query -ErrorAction SilentlyContinue
        Log-Message "Deadlock graph tracing enabled on $SqlInstance" "Information"
        return $true
    } catch {
        Log-Message "Error enabling deadlock trace on $SqlInstance : $_" "Warning"
        return $false
    }
}

function Get-RecentDeadlocks {
    param([string]$SqlInstance)
    
    $query = @"
    SELECT 
        trace_event_id,
        event_time,
        spid,
        database_id,
        object_id,
        index_id,
        error_number,
        severity,
        state,
        text = (SELECT text FROM sys.dm_exec_sql_text(sql_handle))
    FROM sys.fn_trace_getinfo(default)
    WHERE event_id = 121
    AND trace_date > DATEADD(MINUTE, -35, GETDATE())
    ORDER BY event_time DESC
"@
    
    try {
        $result = Invoke-DbaQuery -SqlInstance $SqlInstance -Query $query -ErrorAction SilentlyContinue
        return $result
    } catch {
        Log-Message "Error retrieving deadlock information from $SqlInstance : $_" "Error"
        return $null
    }
}

function Get-DeadlockAnalysis {
    param([string]$SqlInstance)
    
    $query = @"
    DECLARE @tracefilename nvarchar(max);
    SELECT @tracefilename = path FROM sys.traces WHERE is_default = 1;
    
    SELECT 
        event_time,
        deadlock_graph = CONVERT(xml, textdata),
        spid,
        database_name
    FROM sys.fn_trace_gettable(@tracefilename, DEFAULT)
    WHERE event_id = 148
    AND event_time > DATEADD(MINUTE, -35, GETDATE())
    ORDER BY event_time DESC
"@
    
    try {
        $result = Invoke-DbaQuery -SqlInstance $SqlInstance -Query $query -ErrorAction SilentlyContinue
        return $result
    } catch {
        Log-Message "Error retrieving deadlock graph analysis: $_" "Error"
        return $null
    }
}

function Extract-SPIDsFromDeadlockGraph {
    param([xml]$DeadlockXml)
    
    try {
        $spids = @()
        
        # Extract process SPIDs from the deadlock graph XML
        # Deadlock graph structure: /deadlock/process-list/process[@id='spid']
        if ($DeadlockXml.deadlock -and $DeadlockXml.deadlock.'process-list') {
            foreach ($process in $DeadlockXml.deadlock.'process-list'.process) {
                $spid = [int]$process.id
                if ($spid -gt 0) {
                    $spids += $spid
                }
            }
        }
        
        return $spids
    } catch {
        Log-Message "Error extracting SPIDs from deadlock graph: $_" "Error"
        return @()
    }
}

function Kill-Session {
    param(
        [string]$SqlInstance,
        [int]$SessionId
    )
    
    try {
        # Verify session exists before killing
        $checkQuery = "SELECT session_id FROM sys.dm_exec_sessions WHERE session_id = $SessionId"
        $sessionExists = Invoke-DbaQuery -SqlInstance $SqlInstance -Query $checkQuery -ErrorAction SilentlyContinue
        
        if ($sessionExists) {
            Log-Message "KILLING DEADLOCK PARTICIPANT - Session ID: $SessionId" "Error"
            
            $killQuery = "KILL $SessionId"
            Invoke-DbaQuery -SqlInstance $SqlInstance -Query $killQuery -ErrorAction Stop
            
            Log-Message "Successfully killed deadlock participant session $SessionId" "Error"
            return $true
        } else {
            Log-Message "Session $SessionId no longer exists (may have already terminated)" "Information"
            return $false
        }
    } catch {
        Log-Message "Error killing session $SessionId : $_" "Warning"
        return $false
    }
}
    $instances = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty InstalledInstances
    
    if (-not $instances) {
        $instances = @("MSSQLSERVER")
    }
    
    Log-Message "=== Deadlock Detection Started ===" "Information"
    
    # Hash table to track sessions involved in deadlocks
    $deadlockParticipants = @{}
    
    foreach ($instance in $instances) {
        Write-Host ""
        Log-Message "Checking for deadlocks on instance: $instance" "Information"
        
        $instanceName = if ($instance -eq "MSSQLSERVER") { "localhost" } else { "localhost\$instance" }
        
        try {
            # Enable deadlock tracing
            Enable-DeadlockGraphTrace -SqlInstance $instanceName
            
            # Get deadlock analysis
            $deadlocks = Get-DeadlockAnalysis -SqlInstance $instanceName
            
            if ($deadlocks -and $deadlocks.Count -gt 0) {
                Log-Message "Found $($deadlocks.Count) deadlock(s) on instance $instance in last 35 minutes" "Warning"
                
                $deadlockCount = 0
                foreach ($deadlock in $deadlocks) {
                    $deadlockCount++
                    $filename = Join-Path $deadlockGraphPath "Deadlock_$instance`_$($deadlock.event_time.ToString('yyyyMMdd_HHmmss'))_$deadlockCount.xml"
                    
                    try {
                        $deadlock.deadlock_graph.OuterXml | Out-File -FilePath $filename -Encoding UTF8
                        
                        $message = @"
Deadlock Detected and Captured:
  Instance: $instance
  Event Time: $($deadlock.event_time)
  Database: $($deadlock.database_name)
  Process: $($deadlock.spid)
  Graph File: $filename
"@
                        Log-Message $message "Warning"
                        
                        # Extract SPIDs involved in this deadlock
                        if ($killDeadlockParticipants) {
                            $involvedSpids = Extract-SPIDsFromDeadlockGraph -DeadlockXml $deadlock.deadlock_graph
                            
                            foreach ($spid in $involvedSpids) {
                                # Track this SPID as a deadlock participant
                                if (-not $deadlockParticipants.ContainsKey($spid)) {
                                    $deadlockParticipants[$spid] = @{
                                        count = 1
                                        instances = @($instance)
                                        lastDeadlock = $deadlock.event_time
                                    }
                                } else {
                                    $deadlockParticipants[$spid].count += 1
                                    $deadlockParticipants[$spid].lastDeadlock = $deadlock.event_time
                                    if ($deadlockParticipants[$spid].instances -notcontains $instance) {
                                        $deadlockParticipants[$spid].instances += $instance
                                    }
                                }
                                
                                # Kill if this session is a repeat offender
                                if ($deadlockParticipants[$spid].count -ge $repeatOffenderThreshold) {
                                    Log-Message "Session $spid is a repeat deadlock participant (involved in $($deadlockParticipants[$spid].count) deadlocks). Attempting to kill session." "Error"
                                    Kill-Session -SqlInstance $instanceName -SessionId $spid
                                }
                            }
                        }
                        
                    } catch {
                        Log-Message "Error saving deadlock graph: $_" "Error"
                    }
                }
                
                # Alert if deadlock frequency is high (more than threshold in monitor window)
                if ($deadlockCount -gt $deadlockThreshold) {
                    Log-Message "ALERT: High deadlock frequency detected! $deadlockCount deadlocks in last $monitorWindow minutes on instance $instance" "Error"
                }
                
            } else {
                Log-Message "No deadlocks detected on instance $instance" "Information"
            }
            
        } catch {
            Log-Message "Error processing instance $instance : $_" "Error"
        }
    }
    
    Log-Message "=== Deadlock Detection Completed ===" "Information"
    exit 0
    
} catch {
    Log-Message "Fatal error in deadlock detection: $_" "Error"
    exit 1
}
