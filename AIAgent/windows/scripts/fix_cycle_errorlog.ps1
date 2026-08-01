<#
.SYNOPSIS
    Cycles the MSSQL error log and SQL Agent log.
    Equivalent to: EXEC sp_cycle_errorlog; EXEC sp_cycle_agent_errorlog
    No service restart required.
#>
param(
    [string]$ServerInstance = '.',
    [string]$Auth           = 'windows',
    [string]$SqlUser        = '',
    [string]$SqlPassword    = '',
    [string]$DbName         = ''     # informational only
)

Set-StrictMode -Version Latest
. "$PSScriptRoot\_common.ps1"

function Invoke-SQL {
    param([string]$Query)
    $args = @('-S', $ServerInstance, '-l', '15')
    if ($Auth -eq 'sql' -and $SqlUser) {
        $args += @('-U', $SqlUser, '-P', $SqlPassword)
    } else { $args += '-E' }
    $args += @('-Q', $Query, '-h', '-1')
    $out = & sqlcmd @args 2>&1
    return $out -join "`n"
}

# --- Check: sqlcmd must be available before touching the server ---
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    Save-Action -Status SKIP -DbName $DbName -Message "sqlcmd not found — cannot cycle error log"
    exit 0
}

Write-Host "[$DbName] Cycling error log on $ServerInstance..."

# Log sizes before
$before = Get-ChildItem 'C:\Program Files\Microsoft SQL Server' -Recurse -Filter 'ERRORLOG' -ErrorAction SilentlyContinue |
    Select-Object FullName, @{N='MB';E={[math]::Round($_.Length/1MB,2)}} |
    Out-String

$r1 = Invoke-SQL "EXEC sp_cycle_errorlog;"
Write-Host "sp_cycle_errorlog: $($r1.Trim())"

$r2 = Invoke-SQL "EXEC msdb.dbo.sp_cycle_agent_errorlog;"
Write-Host "sp_cycle_agent_errorlog: $($r2.Trim())"

# Log sizes after
$after = Get-ChildItem 'C:\Program Files\Microsoft SQL Server' -Recurse -Filter 'ERRORLOG' -ErrorAction SilentlyContinue |
    Select-Object FullName, @{N='MB';E={[math]::Round($_.Length/1MB,2)}} |
    Out-String

Write-Host "Before:`n$before"
Write-Host "After:`n$after"

# --- Save: record that the error log was cycled ---
Save-Action -Status DONE -DbName $DbName -Message "cycled MSSQL error log and SQL Agent log on $ServerInstance"
Write-Host "[$DbName] Error log cycled successfully."
