<#
.SYNOPSIS
    Shared helpers for the DB AI Agent Windows fix/start scripts.
    Dot-sourced by each script (. "$PSScriptRoot\_common.ps1"); never run directly.

    Provides Save-Action — a persistent audit record of what each script did
    (or skipped), mirroring save_action in the Linux agent_scripts/_common.sh.
    STATUS convention: DONE | SKIP | FAIL | INFO.
#>

# Audit trail location (overridable via ACTION_LOG_DIR).
$script:DbAgentActionDir =
    if ($env:ACTION_LOG_DIR) { $env:ACTION_LOG_DIR }
    else { Join-Path ($env:ProgramData) 'db_agent\action_log' }
try {
    New-Item -ItemType Directory -Force -Path $script:DbAgentActionDir -ErrorAction Stop | Out-Null
} catch {
    $script:DbAgentActionDir = $env:TEMP
}
$script:DbAgentActionLog = Join-Path $script:DbAgentActionDir 'actions.log'

function Save-Action {
    param(
        [ValidateSet('DONE','SKIP','FAIL','INFO')][string]$Status = 'INFO',
        [string]$Message = '',
        [string]$DbName  = ''
    )
    $ts     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $caller = try { (Get-PSCallStack)[1].ScriptName } catch { $null }
    $script = if ($caller) { Split-Path -Leaf $caller } else { 'unknown.ps1' }
    $line   = '{0} | host={1} | user={2} | script={3} | db={4} | {5,-4} | {6}' -f `
              $ts, $env:COMPUTERNAME, $env:USERNAME, $script, $DbName, $Status, $Message
    try { Add-Content -Path $script:DbAgentActionLog -Value $line -ErrorAction Stop } catch {}
    Write-Host "[action:$Status] $Message"
}
