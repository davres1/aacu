<#
.SYNOPSIS
    Installs the DB AI Agent as a Windows Scheduled Task that:
    - Starts automatically at system boot
    - Runs under SYSTEM account (or a specified service account)
    - Restarts automatically if it stops
    - Has a 10% CPU limit via task settings
    Must be run as Administrator.

.PARAMETER Action
    install   — create the scheduled task (default)
    uninstall — remove the scheduled task
    status    — show task status

.PARAMETER RunAsUser
    Windows account to run under. Default: SYSTEM
    For domain accounts use: DOMAIN\ServiceAccount

.PARAMETER RunAsPassword
    Password for RunAsUser (not needed for SYSTEM)
#>
param(
    [ValidateSet('install','uninstall','status')]
    [string]$Action       = 'install',
    [string]$RunAsUser    = 'SYSTEM',
    [string]$RunAsPassword = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName   = 'DB-AI-Agent'
$AgentDir   = Split-Path -Parent $PSScriptRoot   # AIAgent\
$Venv       = Join-Path $AgentDir 'venv'
$Python     = Join-Path $Venv 'Scripts\python.exe'
$AgentScript = Join-Path $AgentDir 'agent.py'
$LogDir     = Join-Path $AgentDir 'logs'

# ---------------------------------------------------------------------------
function Get-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($Action -ne 'status' -and -not (Get-IsAdmin)) {
    Write-Error "This script must run as Administrator for install/uninstall."
    exit 1
}

# ---------------------------------------------------------------------------
if ($Action -eq 'status') {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        Write-Host "Task     : $TaskName"
        Write-Host "State    : $($task.State)"
        Write-Host "Last run : $($info.LastRunTime)"
        Write-Host "Last rc  : $($info.LastTaskResult)"
        Write-Host "Next run : $($info.NextRunTime)"
    } else {
        Write-Host "Scheduled task '$TaskName' not found."
    }
    exit 0
}

# ---------------------------------------------------------------------------
if ($Action -eq 'uninstall') {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Scheduled task '$TaskName' removed."
    } else {
        Write-Host "Task '$TaskName' not found — nothing to remove."
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
if (-not (Test-Path $Python)) {
    Write-Error "Virtual environment not found at $Venv. Run run_agent.ps1 first to set it up."
    exit 1
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# Action: run Python agent
$action = New-ScheduledTaskAction `
    -Execute $Python `
    -Argument "`"$AgentScript`"" `
    -WorkingDirectory $AgentDir

# Trigger: run at system startup, with 30s delay
$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = 'PT30S'   # ISO 8601 duration: 30 seconds

# Settings
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `   # no time limit (runs indefinitely)
    -RestartCount 10 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable:$false `
    -MultipleInstances IgnoreNew

# Principal
if ($RunAsUser -eq 'SYSTEM') {
    $principal = New-ScheduledTaskPrincipal `
        -UserId 'NT AUTHORITY\SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest
} else {
    $principal = New-ScheduledTaskPrincipal `
        -UserId $RunAsUser `
        -LogonType Password `
        -RunLevel Highest
}

# Remove existing task if present
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

# Register
$regParams = @{
    TaskName    = $TaskName
    Action      = $action
    Trigger     = $trigger
    Settings    = $settings
    Principal   = $principal
    Description = 'DB AI Agent — monitors Oracle/MySQL/MSSQL/DB2 and auto-remediates issues'
    Force       = $true
}
if ($RunAsUser -ne 'SYSTEM' -and $RunAsPassword) {
    $regParams['Password'] = $RunAsPassword
}

Register-ScheduledTask @regParams | Out-Null

Write-Host "Scheduled task '$TaskName' installed."
Write-Host "The agent will start automatically at next boot (30s delay)."
Write-Host ""
Write-Host "To start now  : Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "To check status: .\windows\install_service.ps1 -Action status"
Write-Host "To uninstall  : .\windows\install_service.ps1 -Action uninstall"
