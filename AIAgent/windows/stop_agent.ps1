<#
.SYNOPSIS
    Gracefully stops the DB AI Agent on Windows.
    Sends SIGTERM equivalent (closes the process gracefully).
#>

$AgentDir = Split-Path -Parent $PSScriptRoot
$PidFile  = Join-Path $AgentDir 'logs\agent.pid'

if (-not (Test-Path $PidFile)) {
    # Also try to find running agent by process
    $procs = Get-Process -Name python,python3 -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowTitle -like '*agent*' -or
                            (Get-WmiObject Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine -like '*agent.py*' }
    if ($procs) {
        Write-Host "Found agent process(es): $($procs.Id -join ', ')"
        $procs | Stop-Process -Force
        Write-Host "Stopped."
    } else {
        Write-Host "No PID file found and no agent process detected. Agent may not be running."
    }
    exit 0
}

$agentPid = [int](Get-Content $PidFile -Raw -ErrorAction SilentlyContinue)

if ($agentPid -and (Get-Process -Id $agentPid -ErrorAction SilentlyContinue)) {
    Write-Host "Stopping agent (PID $agentPid)..."
    Stop-Process -Id $agentPid -Force
    $timeout = 10
    while ($timeout -gt 0 -and (Get-Process -Id $agentPid -ErrorAction SilentlyContinue)) {
        Start-Sleep -Seconds 1
        $timeout--
    }
    Write-Host "Agent stopped."
} else {
    Write-Host "Process $agentPid not running — removing stale PID file."
}

Remove-Item $PidFile -Force -ErrorAction SilentlyContinue

# Also stop any background jobs
Get-Job | Where-Object { $_.State -ne 'Completed' } |
    Where-Object { $_.Command -like '*agent.py*' } |
    Stop-Job -PassThru | Remove-Job
