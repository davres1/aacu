#Requires -Version 5.0
<#
.SYNOPSIS
    Collects MSSQL Server facts for Ansible inventory using dbatools module.
    
.DESCRIPTION
    This script gathers comprehensive SQL Server instance information including:
    - Instance names and versions
    - Database list and status
    - Server properties (memory, CPU, etc.)
    - SQL Agent status
    - Backup information
    - Output as JSON for Ansible facts.d plugin

.NOTES
    This script must be placed in C:\ProgramData\ansible\facts.d\ directory
    and executed as a custom facts plugin for Ansible.
#>

# Ensure dbatools module is installed
try {
    if (-not (Get-Module -ListAvailable -Name dbatools)) {
        Write-Error "dbatools module is not installed. Installing..."
        Install-Module -Name dbatools -Force -AllowClobber
    }
    Import-Module dbatools -ErrorAction Stop
} catch {
    Write-Error "Failed to import dbatools module: $_"
    exit 1
}

$ErrorActionPreference = "Continue"
$inventoryData = @{}

try {
    # Get all local SQL Server instances
    $instances = @()
    
    # Check for default instance
    $defaultInstance = Get-DbaInstance -ComputerName $env:COMPUTERNAME -ErrorAction SilentlyContinue
    
    if ($defaultInstance) {
        $instances += $defaultInstance
    }
    
    # Check for named instances
    $namedInstances = Get-DbaSqlInstanceProperty -ComputerName $env:COMPUTERNAME -ErrorAction SilentlyContinue
    if ($namedInstances) {
        $instances += $namedInstances | Where-Object { $_.InstanceName -ne 'MSSQLSERVER' }
    }
    
    if ($instances.Count -eq 0) {
        # Fallback: Use localhost\MSSQLSERVER
        $instances = @("localhost")
    }

    foreach ($instance in $instances) {
        $serverName = if ($instance -is [string]) { $instance } else { $instance.Name }
        
        try {
            $server = Connect-DbaInstance -SqlInstance $serverName -ErrorAction Stop
            
            $instanceInfo = @{
                instance_name = $server.Name
                version = $server.Version.Major
                full_version = $server.Version.ToString()
                edition = $server.Edition
                service_account = $server.ServiceAccount
                state = $server.State
                tcp_enabled = (Get-DbaSpConfigure -SqlInstance $serverName -ConfigName 'network protocol' -ErrorAction SilentlyContinue).ConfiguredValue -eq 1
                total_memory_mb = $server.PhysicalMemory
                processor_count = $server.Processors
                collation = $server.Collation
            }
            
            # Get databases
            $databases = @()
            foreach ($db in $server.Databases | Where-Object { $_.IsSystemObject -eq $false }) {
                $databases += @{
                    name = $db.Name
                    status = $db.Status.ToString()
                    owner = $db.Owner
                    recovery_model = $db.RecoveryModel
                    size_mb = [Math]::Round($db.Size, 2)
                    last_backup_date = if ($db.LastBackupDate -eq [datetime]::MinValue) { "Never" } else { $db.LastBackupDate.ToString("yyyy-MM-dd HH:mm:ss") }
                }
            }
            $instanceInfo.databases = $databases
            
            # Get SQL Server Agent status
            try {
                $agentStatus = Get-DbaAgentJob -SqlInstance $serverName -ErrorAction SilentlyContinue
                $instanceInfo.agent_enabled = if ($agentStatus) { $true } else { $false }
            } catch {
                $instanceInfo.agent_enabled = $false
            }
            
            $inventoryData[$serverName] = $instanceInfo
            
        } catch {
            $inventoryData[$serverName] = @{
                status = "error"
                error_message = $_.Exception.Message
            }
        }
    }

    # Output as JSON for Ansible
    $output = @{
        mssql = $inventoryData
        collection_timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        computer_name = $env:COMPUTERNAME
        os_version = [System.Environment]::OSVersion.Version.ToString()
    }
    
    Write-Output ($output | ConvertTo-Json -Depth 10)

} catch {
    $errorOutput = @{
        error = "Failed to collect MSSQL inventory"
        error_details = $_.Exception.Message
        timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    Write-Output ($errorOutput | ConvertTo-Json)
    exit 1
}
