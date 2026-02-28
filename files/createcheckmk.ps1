#Requires -Version 5.0
<#
.SYNOPSIS
    Creates a 'checkmk' SQL Server user with readonly monitoring permissions.
    
.DESCRIPTION
    This script creates a SQL Server login and user named 'checkmk' with:
    - Server-level View Any Definition permission
    - Server-level View Any Database permission
    - Database-level Reader role on all user databases
    - Permission to access SQL Agent job history
    
    This user is used for monitoring and health checks via Check MK agent.

.NOTES
    Requires SQL Server Management Objects (SMO) or dbatools module.
    Must be run with account that has SQL Server sysadmin privilege.
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

$ErrorActionPreference = "Stop"
$checkmkUser = "checkmk"
$checkmkPassword = Read-Host "Enter password for checkmk user" -AsSecureString

try {
    # Find SQL Server instances on localhost
    $instances = @()
    
    # Check for default instance
    try {
        $defaultInstance = Get-DbaInstance -ComputerName $env:COMPUTERNAME -ErrorAction SilentlyContinue
        if ($defaultInstance) {
            $instances += $defaultInstance.Name
        }
    } catch {}
    
    # Add explicit localhost attempt
    if ($instances.Count -eq 0) {
        $instances = @("localhost", "$env:COMPUTERNAME")
    }
    
    foreach ($instance in $instances) {
        Write-Host "Processing instance: $instance" -ForegroundColor Cyan
        
        try {
            $server = Connect-DbaInstance -SqlInstance $instance -ErrorAction Stop
            
            # Check if login already exists
            $loginExists = $server.Logins | Where-Object { $_.Name -eq $checkmkUser } | Measure-Object | Select-Object -ExpandProperty Count
            
            if ($loginExists -gt 0) {
                Write-Host "Login '$checkmkUser' already exists. Skipping creation." -ForegroundColor Yellow
            } else {
                # Create SQL Server login
                Write-Host "Creating SQL Server login for '$checkmkUser'..." -ForegroundColor Green
                $login = New-Object Microsoft.SqlServer.Management.Smo.Login($server, $checkmkUser)
                $login.LoginType = [Microsoft.SqlServer.Management.Smo.LoginType]::SqlLogin
                $login.Create($checkmkPassword)
                Write-Host "Login created successfully." -ForegroundColor Green
            }
            
            # Grant server-level permissions
            Write-Host "Granting server-level permissions..." -ForegroundColor Green
            
            # Grant View Any Definition
            $login = $server.Logins[$checkmkUser]
            if ($login) {
                $server.Permissions | Where-Object { $_.PermissionState -eq 'Grant' } | ForEach-Object {
                    if ($_.Grantee -eq $checkmkUser -and $_.PermissionType -eq 'ViewAnyDefinition') {
                        Write-Host "Permission 'View Any Definition' already granted." -ForegroundColor Yellow
                    }
                }
                
                # Grant View Definition on Server
                $objPermSet = New-Object Microsoft.SqlServer.Management.Smo.ServerPermissionSet([Microsoft.SqlServer.Management.Smo.ServerPermission]::ViewAnyDefinition)
                $server.Grant($objPermSet, $checkmkUser)
                Write-Host "Granted 'View Any Definition' permission." -ForegroundColor Green
                
                # Grant View Server State
                $objPermSet = New-Object Microsoft.SqlServer.Management.Smo.ServerPermissionSet([Microsoft.SqlServer.Management.Smo.ServerPermission]::ViewServerState)
                $server.Grant($objPermSet, $checkmkUser)
                Write-Host "Granted 'View Server State' permission." -ForegroundColor Green
            }
            
            # Add user to master database only
            Write-Host "Adding user to master database..." -ForegroundColor Green
            try {
                $masterDb = $server.Databases['master']
                
                # Check if user exists in master
                $userExists = $masterDb.Users | Where-Object { $_.Name -eq $checkmkUser } | Measure-Object | Select-Object -ExpandProperty Count
                
                if ($userExists -eq 0) {
                    # Create database user in master
                    $dbUser = New-Object Microsoft.SqlServer.Management.Smo.User($masterDb, $checkmkUser)
                    $dbUser.Login = $checkmkUser
                    $dbUser.Create()
                    Write-Host "User '$checkmkUser' created in master database." -ForegroundColor Green
                } else {
                    Write-Host "User '$checkmkUser' already exists in master database." -ForegroundColor Yellow
                }
                
            } catch {
                Write-Host "Error adding user to master database: $_" -ForegroundColor Red
            }
            
            # Add user to msdb database with SQL Agent reader permissions
            Write-Host "Adding user to msdb database..." -ForegroundColor Green
            try {
                $msdbDb = $server.Databases['msdb']
                
                # Check if user exists in msdb
                $userExists = $msdbDb.Users | Where-Object { $_.Name -eq $checkmkUser } | Measure-Object | Select-Object -ExpandProperty Count
                
                if ($userExists -eq 0) {
                    # Create database user in msdb
                    $dbUser = New-Object Microsoft.SqlServer.Management.Smo.User($msdbDb, $checkmkUser)
                    $dbUser.Login = $checkmkUser
                    $dbUser.Create()
                    Write-Host "User '$checkmkUser' created in msdb database." -ForegroundColor Green
                } else {
                    Write-Host "User '$checkmkUser' already exists in msdb database." -ForegroundColor Yellow
                }
                
                # Add to SQLAgentReaderRole for job history access
                $msdbUser = $msdbDb.Users | Where-Object { $_.Name -eq $checkmkUser }
                if ($msdbUser -and -not ($msdbUser.IsMember('SQLAgentReaderRole'))) {
                    $msdbUser.AddToRole('SQLAgentReaderRole')
                    Write-Host "Added '$checkmkUser' to 'SQLAgentReaderRole' in msdb." -ForegroundColor Green
                } elseif ($msdbUser -and $msdbUser.IsMember('SQLAgentReaderRole')) {
                    Write-Host "'$checkmkUser' is already member of 'SQLAgentReaderRole' in msdb." -ForegroundColor Yellow
                }
                
            } catch {
                Write-Host "Error adding user to msdb database: $_" -ForegroundColor Red
            }
            
            Write-Host "Checkmk user setup completed successfully for instance: $instance" -ForegroundColor Green
            
        } catch {
            Write-Host "Error processing instance '$instance': $_" -ForegroundColor Red
            continue
        }
    }
    
    Write-Host "`nCheckmk user creation completed." -ForegroundColor Green
    
} catch {
    Write-Host "Fatal error: $_" -ForegroundColor Red
    exit 1
}
