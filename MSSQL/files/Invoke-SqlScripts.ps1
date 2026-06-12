#Requires -Version 5.0
<#
.SYNOPSIS
    Run one or more .sql scripts against one or more SQL Server databases.

.DESCRIPTION
    Executes every .sql file found in -ScriptPath (a directory, or the path to a
    single .sql file), in filename order, against each database matched by
    -Database. The -Database argument accepts a comma-separated list and/or
    wildcard patterns:

        -Database abc_1,abc_2        # explicit list
        -Database "abc*"             # every database whose name starts with abc
        -Database "abc*,xyz_1"       # wildcards + explicit names mixed
        -Database *                  # every database on the instance

    System databases (master/model/msdb/tempdb) are skipped unless
    -IncludeSystemDb is supplied. Uses dbatools (Invoke-DbaQuery), which handles
    GO batch separators. Supports -WhatIf and -ContinueOnError, and writes a log
    to $LogDir.

.PARAMETER SqlInstance
    Target instance — e.g. localhost, localhost\SQL2022, SQLPROD01. Default: localhost.

.PARAMETER ScriptPath
    A directory containing .sql files, or the path to a single .sql file.

.PARAMETER Database
    Comma-separated database names and/or wildcard patterns to run against.

.PARAMETER IncludeSystemDb
    Also target master/model/msdb/tempdb when a pattern matches them.

.PARAMETER ContinueOnError
    On a script failure, keep running the remaining scripts on that database.
    By default a failure stops the current database and moves to the next one.

.PARAMETER LogDir
    Directory for the run log. Default: C:\Logs.

.EXAMPLE
    .\Invoke-SqlScripts.ps1 -SqlInstance sqlprod01 -ScriptPath C:\deploy\v2 -Database "app_*"

.EXAMPLE
    .\Invoke-SqlScripts.ps1 -ScriptPath .\patch.sql -Database abc_1,abc_2 -ContinueOnError

.EXAMPLE
    # Preview only — show what would run, change nothing.
    .\Invoke-SqlScripts.ps1 -ScriptPath C:\deploy -Database "abc*" -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$SqlInstance = 'localhost',
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][string]$Database,
    [switch]$IncludeSystemDb,
    [switch]$ContinueOnError,
    [string]$LogDir = 'C:\Logs'
)

try { Import-Module dbatools -ErrorAction Stop } catch { Write-Error "dbatools module is required: $_"; exit 1 }

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$logFile = Join-Path $LogDir ("SQL_RunScripts_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-Log {
    param([string]$Message, [ValidateSet('Information', 'Warning', 'Error')][string]$Level = 'Information')
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'Warning' { Write-Warning $Message }
        'Error'   { Write-Host $entry -ForegroundColor Red }
        default   { Write-Host $entry }
    }
    Add-Content -Path $logFile -Value $entry
}

# --- 1. Resolve the .sql files to run -------------------------------------
if (Test-Path -LiteralPath $ScriptPath -PathType Container) {
    $files = @(Get-ChildItem -LiteralPath $ScriptPath -Filter *.sql -File | Sort-Object Name)
}
elseif (Test-Path -LiteralPath $ScriptPath -PathType Leaf) {
    $files = @(Get-Item -LiteralPath $ScriptPath)
}
else {
    Write-Log "ScriptPath not found: $ScriptPath" 'Error'; exit 2
}
if (-not $files -or $files.Count -eq 0) {
    Write-Log "No .sql files found in: $ScriptPath" 'Error'; exit 2
}

# --- 2. Resolve the target databases (comma list + wildcards) -------------
$patterns = @($Database -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
try {
    $allDbs = Get-DbaDatabase -SqlInstance $SqlInstance -EnableException
}
catch {
    Write-Log "Cannot connect to $SqlInstance or list databases: $_" 'Error'; exit 3
}
if (-not $IncludeSystemDb) {
    $allDbs = $allDbs | Where-Object { -not $_.IsSystemObject }
}

$targets = foreach ($p in $patterns) {
    $matched = $allDbs | Where-Object { $_.Name -like $p }
    if (-not $matched) { Write-Log "No database matched pattern '$p' on $SqlInstance" 'Warning' }
    $matched
}
$targets = @($targets | Sort-Object Name -Unique)

if ($targets.Count -eq 0) {
    Write-Log "No databases matched '$Database' on $SqlInstance (after system-db filter)." 'Error'; exit 3
}

Write-Log ("Instance={0}  Scripts={1}  Databases={2} ({3})" -f `
    $SqlInstance, $files.Count, $targets.Count, ($targets.Name -join ', '))

# --- 3. Execute scripts x databases ---------------------------------------
$results = [System.Collections.ArrayList]@()
$failures = 0

foreach ($db in $targets) {
    if (-not $PSCmdlet.ShouldProcess("$SqlInstance / $($db.Name)", "Run $($files.Count) .sql script(s)")) {
        continue
    }
    foreach ($f in $files) {
        $started = Get-Date
        try {
            Invoke-DbaQuery -SqlInstance $SqlInstance -Database $db.Name -File $f.FullName -EnableException
            $ms = [int]((Get-Date) - $started).TotalMilliseconds
            Write-Log ("OK   {0} -> {1} ({2} ms)" -f $f.Name, $db.Name, $ms)
            [void]$results.Add([pscustomobject]@{ database = $db.Name; script = $f.Name; status = 'ok'; ms = $ms })
        }
        catch {
            $failures++
            Write-Log ("FAIL {0} -> {1}: {2}" -f $f.Name, $db.Name, $_.Exception.Message) 'Error'
            [void]$results.Add([pscustomobject]@{ database = $db.Name; script = $f.Name; status = 'failed'; error = "$($_.Exception.Message)" })
            if (-not $ContinueOnError) {
                Write-Log "Stopping further scripts on $($db.Name) (use -ContinueOnError to override)." 'Warning'
                break
            }
        }
    }
}

# --- 4. Summary -----------------------------------------------------------
$ran = $results.Count
$ok  = @($results | Where-Object status -eq 'ok').Count
Write-Log ("=== Done: {0} run, {1} ok, {2} failed across {3} database(s). Log: {4} ===" -f `
    $ran, $ok, $failures, $targets.Count, $logFile)

if ($failures -gt 0) { exit 1 }
exit 0
