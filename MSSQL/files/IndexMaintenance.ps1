#Requires -Version 5.0
<#
.SYNOPSIS
    Performs index maintenance and analytics on SQL Server databases.
    
.DESCRIPTION
    This script:
    - Analyzes fragmentation levels of all indexes
    - Rebuilds heavily fragmented indexes (>30% fragmentation)
    - Reorganizes moderately fragmented indexes (10-30% fragmentation)
    - Updates statistics on all indexes
    - Generates index health reports
    - Logs maintenance operations
    - Provides fragmentation metrics
    
.NOTES
    Must have dbatools module installed.
    Requires SQL Server sysadmin or db_owner role.
    Designed to run every 30 minutes via scheduled task.
    Can be resource intensive - consider scheduling during off-peak hours.
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
$logFile = "C:\Logs\SQL_Index_Maintenance_$(Get-Date -Format 'yyyyMMdd').log"
$reportPath = "C:\Logs\IndexReports"
$eventLogSource = "SQL Server Health Check"

# Configuration
$rebuildThreshold = 30      # Percent - rebuild if fragmentation > this
$reorganizeThreshold = 10   # Percent - reorganize if fragmentation > this
$minPageCount = 1000        # Only maintain indexes with > this many pages

# Ensure directories exist
foreach ($path in @("C:\Logs", $reportPath)) {
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
        Write-EventLog -LogName Application -Source $eventLogSource -EventId 1006 -Message $logEntry -EntryType $eventType -ErrorAction SilentlyContinue
    } catch {}
}

function Get-IndexFragmentation {
    param([string]$SqlInstance, [string]$DatabaseName)
    
    $query = @"
    SELECT 
        SchemaName = s.name,
        TableName = t.name,
        IndexName = i.name,
        IndexType = i.type_desc,
        Fragmentation = ps.avg_fragmentation_in_percent,
        PageCount = ps.page_count,
        SizeMB = (ps.page_count * 8) / 1024.0
    FROM sys.indexes i
    INNER JOIN sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ps
        ON i.object_id = ps.object_id
        AND i.index_id = ps.index_id
    INNER JOIN sys.tables t ON i.object_id = t.object_id
    INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE ps.avg_fragmentation_in_percent > 0
    AND ps.page_count > $minPageCount
    AND t.is_ms_shipped = 0
    ORDER BY ps.avg_fragmentation_in_percent DESC
"@
    
    try {
        $result = Invoke-DbaQuery -SqlInstance $SqlInstance -Database $DatabaseName -Query $query -ErrorAction SilentlyContinue
        return $result
    } catch {
        Log-Message "Error retrieving index fragmentation from $DatabaseName : $_" "Error"
        return $null
    }
}

function Rebuild-Index {
    param(
        [string]$SqlInstance,
        [string]$DatabaseName,
        [string]$SchemaName,
        [string]$TableName,
        [string]$IndexName
    )
    
    $query = "ALTER INDEX [$IndexName] ON [$SchemaName].[$TableName] REBUILD"
    
    try {
        Invoke-DbaQuery -SqlInstance $SqlInstance -Database $DatabaseName -Query $query -ErrorAction Stop
        return $true
    } catch {
        Log-Message "Error rebuilding index $SchemaName.$TableName.$IndexName : $_" "Error"
        return $false
    }
}

function Reorganize-Index {
    param(
        [string]$SqlInstance,
        [string]$DatabaseName,
        [string]$SchemaName,
        [string]$TableName,
        [string]$IndexName
    )
    
    $query = "ALTER INDEX [$IndexName] ON [$SchemaName].[$TableName] REORGANIZE"
    
    try {
        Invoke-DbaQuery -SqlInstance $SqlInstance -Database $DatabaseName -Query $query -ErrorAction Stop
        return $true
    } catch {
        Log-Message "Error reorganizing index $SchemaName.$TableName.$IndexName : $_" "Error"
        return $false
    }
}

function Update-IndexStatistics {
    param([string]$SqlInstance, [string]$DatabaseName)
    
    $query = "EXEC sp_updatestats @resample = 'RESAMPLE'"
    
    try {
        Invoke-DbaQuery -SqlInstance $SqlInstance -Database $DatabaseName -Query $query -ErrorAction Stop
        return $true
    } catch {
        Log-Message "Error updating statistics on $DatabaseName : $_" "Error"
        return $false
    }
}

try {
    $instances = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty InstalledInstances
    
    if (-not $instances) {
        $instances = @("MSSQLSERVER")
    }
    
    Log-Message "=== Index Maintenance and Analytics Started ===" "Information"
    
    $report = @()
    
    foreach ($instance in $instances) {
        Write-Host ""
        Log-Message "Processing instance: $instance" "Information"
        
        $instanceName = if ($instance -eq "MSSQLSERVER") { "localhost" } else { "localhost\$instance" }
        
        try {
            # Get list of user databases
            $dbQuery = "SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0 ORDER BY name"
            $databases = Invoke-DbaQuery -SqlInstance $instanceName -Query $dbQuery -ErrorAction SilentlyContinue
            
            foreach ($db in $databases) {
                $dbName = $db.name
                Log-Message "Analyzing indexes in database: $dbName" "Information"
                
                try {
                    # Get index fragmentation
                    $indexes = Get-IndexFragmentation -SqlInstance $instanceName -DatabaseName $dbName
                    
                    if ($indexes) {
                        $rebuildCount = 0
                        $reorganizeCount = 0
                        
                        foreach ($idx in $indexes) {
                            $frag = $idx.Fragmentation
                            
                            if ($frag -gt $rebuildThreshold) {
                                Log-Message "Rebuilding index: $($idx.SchemaName).$($idx.TableName).$($idx.IndexName) (Fragmentation: $([Math]::Round($frag, 2))%)" "Information"
                                
                                if (Rebuild-Index -SqlInstance $instanceName -DatabaseName $dbName -SchemaName $idx.SchemaName -TableName $idx.TableName -IndexName $idx.IndexName) {
                                    $rebuildCount++
                                    $report += "REBUILD,$instance,$dbName,$($idx.SchemaName).$($idx.TableName).$($idx.IndexName),$([Math]::Round($frag, 2))%,$timestamp"
                                }
                                
                            } elseif ($frag -gt $reorganizeThreshold) {
                                Log-Message "Reorganizing index: $($idx.SchemaName).$($idx.TableName).$($idx.IndexName) (Fragmentation: $([Math]::Round($frag, 2))%)" "Information"
                                
                                if (Reorganize-Index -SqlInstance $instanceName -DatabaseName $dbName -SchemaName $idx.SchemaName -TableName $idx.TableName -IndexName $idx.IndexName) {
                                    $reorganizeCount++
                                    $report += "REORGANIZE,$instance,$dbName,$($idx.SchemaName).$($idx.TableName).$($idx.IndexName),$([Math]::Round($frag, 2))%,$timestamp"
                                }
                            }
                        }
                        
                        Log-Message "Database $dbName: $rebuildCount indexes rebuilt, $reorganizeCount indexes reorganized" "Information"
                    }
                    
                    # Update statistics
                    Log-Message "Updating statistics for database: $dbName" "Information"
                    if (Update-IndexStatistics -SqlInstance $instanceName -DatabaseName $dbName) {
                        Log-Message "Statistics updated successfully for $dbName" "Information"
                    }
                    
                } catch {
                    Log-Message "Error processing database $dbName : $_" "Error"
                }
            }
            
        } catch {
            Log-Message "Error processing instance $instance : $_" "Error"
        }
    }
    
    # Save report
    if ($report.Count -gt 0) {
        $reportFile = Join-Path $reportPath "IndexMaintenance_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        "Operation,Instance,Database,Index,Fragmentation,Timestamp" + "`r`n" + ($report -join "`r`n") | Out-File -FilePath $reportFile -Encoding UTF8
        Log-Message "Report saved to: $reportFile" "Information"
    }
    
    Log-Message "=== Index Maintenance Completed ===" "Information"
    exit 0
    
} catch {
    Log-Message "Fatal error in index maintenance: $_" "Error"
    exit 1
}
