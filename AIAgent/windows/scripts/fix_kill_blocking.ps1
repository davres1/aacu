<#
.SYNOPSIS
    Kills MSSQL sessions blocking others for more than 30 minutes.
    No service restart required.
#>
param(
    [string]$ServerInstance  = '.',
    [string]$Auth            = 'windows',
    [string]$SqlUser         = '',
    [string]$SqlPassword     = '',
    [string]$DbName          = '',
    [int]   $MinWaitSeconds  = 1800    # kill sessions blocking > 30 min
)

Set-StrictMode -Version Latest

function Invoke-SQL {
    param([string]$Query)
    $a = @('-S', $ServerInstance, '-l', '30')
    if ($Auth -eq 'sql' -and $SqlUser) { $a += @('-U', $SqlUser, '-P', $SqlPassword) }
    else { $a += '-E' }
    $a += @('-Q', $Query, '-h', '-1')
    return (& sqlcmd @a 2>&1) -join "`n"
}

Write-Host "[$DbName] Finding blocking sessions > $($MinWaitSeconds/60) min on $ServerInstance..."

# Get blocking sessions
$findSql = @"
SET NOCOUNT ON;
SELECT
    r.session_id       AS spid,
    r.blocking_session_id AS blocked_by,
    r.wait_time        AS wait_ms,
    s.login_name,
    DB_NAME(r.database_id) AS db_name,
    r.command,
    SUBSTRING(qt.text, (r.statement_start_offset/2)+1,
        ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(qt.text)
          ELSE r.statement_end_offset END - r.statement_start_offset)/2)+1) AS sql_text
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions   s  ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) qt
WHERE r.blocking_session_id > 0
  AND r.wait_time >= $MinWaitSeconds * 1000
ORDER BY r.wait_time DESC;
"@

$rows = Invoke-SQL $findSql
Write-Host "Blocking sessions found:`n$rows"

# Build and execute KILL statements
$killSql = @"
SET NOCOUNT ON;
DECLARE @sql NVARCHAR(200);
DECLARE @killed INT = 0;
DECLARE cur CURSOR FAST_FORWARD FOR
    SELECT r.session_id
    FROM sys.dm_exec_requests r
    WHERE r.blocking_session_id > 0
      AND r.wait_time >= $MinWaitSeconds * 1000;
OPEN cur;
FETCH NEXT FROM cur INTO @spid;
DECLARE @spid INT;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'KILL ' + CAST(@spid AS NVARCHAR(10));
        EXEC sp_executesql @sql;
        SET @killed = @killed + 1;
    END TRY
    BEGIN CATCH
        PRINT 'Could not kill spid ' + CAST(@spid AS VARCHAR(10)) + ': ' + ERROR_MESSAGE();
    END CATCH;
    FETCH NEXT FROM cur INTO @spid;
END;
CLOSE cur; DEALLOCATE cur;
PRINT 'Sessions killed: ' + CAST(@killed AS VARCHAR(10));
"@

$result = Invoke-SQL $killSql
Write-Host $result
Write-Host "[$DbName] Blocking session kill complete."
