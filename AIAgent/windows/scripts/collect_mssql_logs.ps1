<#
.SYNOPSIS
    Collects new MSSQL log lines since the last saved byte position.
    Deployed and called by agent.py via subprocess.
    Also queries DMVs for blocking sessions and database health.

.PARAMETER ParamsJson
    JSON string with: db_name, db_type, log_files (dict), positions (dict),
    max_lines, server_instance, auth, sql_user, sql_password, output_file
#>
param(
    [Parameter(Mandatory)][string]$ParamsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Parse input
# ---------------------------------------------------------------------------
$p           = $ParamsJson | ConvertFrom-Json
$dbName      = $p.db_name
$dbType      = $p.db_type
$logFiles    = $p.log_files      # PSCustomObject: key -> path
$positions   = $p.positions      # PSCustomObject: key -> byte offset
$maxLines    = [int]$p.max_lines
$server      = $p.server_instance
$auth        = $p.auth           # "windows" | "sql"
$sqlUser     = $p.sql_user
$sqlPass     = $p.sql_password
$outFile     = $p.output_file

$entries      = [System.Collections.Generic.List[hashtable]]::new()
$newPositions = @{}

# ---------------------------------------------------------------------------
# Helper: read new bytes from a locked file since saved position
# ---------------------------------------------------------------------------
function Read-NewLogLines {
    param([string]$Path, [long]$SavedPos, [int]$MaxLines)

    if (-not (Test-Path $Path)) { return @(), $SavedPos }

    try {
        $fs = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite  # allows reading locked MSSQL files
        )
    } catch { return @(), $SavedPos }

    $currentSize = $fs.Length

    # File was rotated / truncated
    if ($currentSize -lt $SavedPos) { $SavedPos = 0 }

    if ($currentSize -le $SavedPos) {
        $fs.Close()
        return @(), $currentSize
    }

    $fs.Seek($SavedPos, [System.IO.SeekOrigin]::Begin) | Out-Null
    $reader = [System.IO.StreamReader]::new(
        $fs, [System.Text.Encoding]::UTF8, $false, 8192
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if ($line -and $line.Trim()) { $lines.Add($line.Trim()) }
    }
    $reader.Close()
    $fs.Close()

    # Return only last N lines to cap token usage
    $sliced = if ($lines.Count -gt $MaxLines) {
        $lines.GetRange($lines.Count - $MaxLines, $MaxLines)
    } else { $lines }

    return $sliced, $currentSize
}

# ---------------------------------------------------------------------------
# Helper: build sqlcmd connection args
# ---------------------------------------------------------------------------
function Get-SqlArgs {
    $args = @('-S', $server, '-l', '10')
    if ($auth -eq 'sql' -and $sqlUser) {
        $args += @('-U', $sqlUser, '-P', $sqlPass)
    } else {
        $args += '-E'   # Windows auth
    }
    return $args
}

# ---------------------------------------------------------------------------
# 1. Read log files (ERRORLOG, SQLAGENT.OUT, etc.)
# ---------------------------------------------------------------------------
foreach ($prop in $logFiles.PSObject.Properties) {
    $logKey  = $prop.Name
    $logPath = $prop.Value
    $savedP  = if ($positions.PSObject.Properties[$logKey]) {
                   [long]($positions.$logKey)
               } else { 0L }

    $lines, $newPos = Read-NewLogLines -Path $logPath -SavedPos $savedP -MaxLines $maxLines
    $newPositions[$logKey] = $newPos

    foreach ($line in $lines) {
        $entries.Add(@{
            db_name  = $dbName
            db_type  = $dbType
            log_type = $logKey
            content  = $line
        })
    }
}

# ---------------------------------------------------------------------------
# 2. Live DMV checks via sqlcmd (blocking, offline DBs, low disk)
# ---------------------------------------------------------------------------
if ($server) {
    $sqlArgs = Get-SqlArgs

    # 2a. Blocking sessions > 30 seconds
    $blockSql = @"
SET NOCOUNT ON;
SELECT TOP 20
    'BLOCKING: spid=' + CAST(r.session_id AS VARCHAR(10)) +
    ' blocked_by=' + CAST(r.blocking_session_id AS VARCHAR(10)) +
    ' wait_sec=' + CAST(r.wait_time/1000 AS VARCHAR(10)) +
    ' db=' + ISNULL(DB_NAME(r.database_id),'?') +
    ' login=' + ISNULL(s.login_name,'?') +
    ' cmd=' + ISNULL(r.command,'?')
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions   s ON s.session_id = r.session_id
WHERE r.blocking_session_id > 0
  AND r.wait_time > 30000
ORDER BY r.wait_time DESC;
"@
    $blockOut = & sqlcmd @sqlArgs -Q $blockSql -h -1 2>$null
    foreach ($line in $blockOut) {
        $t = $line.Trim()
        if ($t -and $t -notmatch '^-+$' -and $t -ne '') {
            $entries.Add(@{
                db_name  = $dbName
                db_type  = $dbType
                log_type = 'blocking_check'
                content  = $t
            })
        }
    }

    # 2b. Offline / suspect databases
    $dbSql = @"
SET NOCOUNT ON;
SELECT TOP 20
    'DB_STATE: database=' + name +
    ' state=' + state_desc +
    ' recovery=' + recovery_model_desc
FROM sys.databases
WHERE state_desc NOT IN ('ONLINE') OR is_in_standby = 1;
"@
    $dbOut = & sqlcmd @sqlArgs -Q $dbSql -h -1 2>$null
    foreach ($line in $dbOut) {
        $t = $line.Trim()
        if ($t -and $t -notmatch '^-+$' -and $t -ne '') {
            $entries.Add(@{
                db_name  = $dbName
                db_type  = $dbType
                log_type = 'database_state'
                content  = $t
            })
        }
    }

    # 2c. Transaction log files > 80% full
    $logSql = @"
SET NOCOUNT ON;
SELECT TOP 10
    'LOG_FULL: db=' + DB_NAME(l.database_id) +
    ' log_used_pct=' + CAST(CAST(l.log_reuse_wait_desc AS VARCHAR(30)) AS VARCHAR(40)) +
    ' size_mb=' + CAST(CAST(l.log_size_mb AS INT) AS VARCHAR(10)) +
    ' used_mb=' + CAST(CAST(l.log_used_mb AS INT) AS VARCHAR(10))
FROM (
    SELECT database_id,
           log_reuse_wait_desc,
           SUM(size * 8.0 / 1024) AS log_size_mb,
           SUM(FILEPROPERTY(name,'SpaceUsed') * 8.0 / 1024) AS log_used_mb
    FROM sys.master_files
    WHERE type_desc = 'LOG'
    GROUP BY database_id, log_reuse_wait_desc
) l
WHERE l.log_size_mb > 0
  AND (l.log_used_mb / l.log_size_mb) > 0.80;
"@
    $logOut = & sqlcmd @sqlArgs -Q $logSql -h -1 2>$null
    foreach ($line in $logOut) {
        $t = $line.Trim()
        if ($t -and $t -notmatch '^-+$' -and $t -ne '') {
            $entries.Add(@{
                db_name  = $dbName
                db_type  = $dbType
                log_type = 'log_space_check'
                content  = $t
            })
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Write output JSON
# ---------------------------------------------------------------------------
$result = @{
    db_name     = $dbName
    db_type     = $dbType
    log_entries = @($entries)
    positions   = $newPositions
}

$json = $result | ConvertTo-Json -Depth 6 -Compress
if ($outFile) {
    $json | Set-Content -Path $outFile -Encoding UTF8
} else {
    Write-Output $json
}
