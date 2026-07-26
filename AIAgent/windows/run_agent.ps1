<#
.SYNOPSIS
    Starts the DB AI Agent as a background PowerShell job on Windows.
    Creates a Python venv, installs dependencies, then runs agent.py in background.
#>
param(
    [switch]$TestOnly   # Run --test mode and exit without starting daemon
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AgentDir = Split-Path -Parent $PSScriptRoot   # AIAgent\
$PidFile  = Join-Path $AgentDir 'logs\agent.pid'
$LogDir   = Join-Path $AgentDir 'logs'
$Venv     = Join-Path $AgentDir 'venv'
$Python   = Join-Path $Venv 'Scripts\python.exe'

# ---------------------------------------------------------------------------
# Ensure log dir
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# ---------------------------------------------------------------------------
# Check Python
# ---------------------------------------------------------------------------
if (-not (Get-Command python -ErrorAction SilentlyContinue) -and
    -not (Get-Command python3 -ErrorAction SilentlyContinue)) {
    Write-Error "Python not found. Install Python 3.9+ from python.org and add to PATH."
    exit 1
}
$pythonExe = if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' } else { 'python' }

# ---------------------------------------------------------------------------
# Create / update virtual environment
# ---------------------------------------------------------------------------
if (-not (Test-Path $Python)) {
    Write-Host "Creating Python virtual environment..."
    & $pythonExe -m venv $Venv
    if ($LASTEXITCODE -ne 0) { Write-Error "venv creation failed"; exit 1 }
}

Write-Host "Installing/updating dependencies..."
& $Python -m pip install -q --upgrade pip
& $Python -m pip install -q -r (Join-Path $AgentDir 'requirements.txt')

# ---------------------------------------------------------------------------
# Test mode
# ---------------------------------------------------------------------------
if ($TestOnly) {
    Write-Host ""
    & $Python (Join-Path $AgentDir 'agent.py') --test
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Validate config first
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Validating configuration..."
& $Python (Join-Path $AgentDir 'agent.py') --test
if ($LASTEXITCODE -ne 0) { Write-Error "Config validation failed — fix agentsetting.yaml first"; exit 1 }

# ---------------------------------------------------------------------------
# Check already running
# ---------------------------------------------------------------------------
if (Test-Path $PidFile) {
    $existingPid = [int](Get-Content $PidFile -Raw -ErrorAction SilentlyContinue)
    if ($existingPid -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
        Write-Host "Agent already running (PID $existingPid). Use stop_agent.ps1 first."
        exit 0
    }
    Remove-Item $PidFile -Force
}

# ---------------------------------------------------------------------------
# Start agent as a background Windows job
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Starting DB AI Agent in background..."

$stdoutLog = Join-Path $LogDir 'stdout.log'

$job = Start-Job -ScriptBlock {
    param($py, $agentScript, $logFile)
    & $py $agentScript 2>&1 | Tee-Object -FilePath $logFile -Append
} -ArgumentList $Python, (Join-Path $AgentDir 'agent.py'), $stdoutLog

# Wait briefly then check PID file was written
Start-Sleep -Seconds 2

if (Test-Path $PidFile) {
    $pid = Get-Content $PidFile -Raw
    Write-Host "Agent started (PID $($pid.Trim()), Job ID $($job.Id))"
} else {
    Write-Host "Agent started as Job ID $($job.Id)"
}

Write-Host "Agent log : $LogDir\agent.log"
Write-Host "Stdout    : $stdoutLog"
Write-Host ""
Write-Host "To stop   : .\windows\stop_agent.ps1"
Write-Host "To install as Windows service: .\windows\install_service.ps1"
