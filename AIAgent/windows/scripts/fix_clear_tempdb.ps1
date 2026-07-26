<#
.SYNOPSIS
    Frees TempDB space by clearing procedure cache and shrinking data files.
    Safe approach — shrinks only free space, does not truncate.
    No service restart required.
#>
param(
    [string]$ServerInstance = '.',
    [string]$Auth           = 'windows',
    [string]$SqlUser        = '',
    [string]$SqlPassword    = '',
    [string]$DbName         = ''
)

Set-StrictMode -Version Latest

function Invoke-SQL {
    param([string]$Query)
    $a = @('-S', $ServerInstance, '-l', '60', '-b')
    if ($Auth -eq 'sql' -and $SqlUser) { $a += @('-U', $SqlUser, '-P', $SqlPassword) }
    else { $a += '-E' }
    $a += @('-Q', $Query, '-h', '-1')
    return (& sqlcmd @a 2>&1) -join "`n"
}

Write-Host "[$DbName] Checking TempDB usage on $ServerInstance..."

# Report current TempDB usage
$checkSql = @"
SET NOCOUNT ON;
SELECT
    'TempDB file: ' + name +
    ' size_mb='  + CAST(CAST(size * 8.0 / 1024 AS INT) AS VARCHAR) +
    ' used_mb='  + CAST(CAST(FILEPROPERTY(name,'SpaceUsed') * 8.0 / 1024 AS INT) AS VARCHAR) +
    ' free_mb='  + CAST(CAST((size - FILEPROPERTY(name,'SpaceUsed')) * 8.0 / 1024 AS INT) AS VARCHAR)
FROM tempdb.sys.database_files;
SELECT 'TempDB version store: ' +
    CAST(SUM(version_store_reserved_page_count) * 8 / 1024 AS VARCHAR) + ' MB'
FROM sys.dm_db_file_space_usage;
SELECT 'TempDB internal objects: ' +
    CAST(SUM(internal_object_reserved_page_count) * 8 / 1024 AS VARCHAR) + ' MB'
FROM sys.dm_db_session_space_usage;
"@
Write-Host (Invoke-SQL $checkSql)

# Step 1: Flush procedure cache (frees shared memory pressure)
Write-Host "Flushing procedure cache..."
$r = Invoke-SQL "DBCC FREEPROCCACHE WITH NO_INFOMSGS;"
Write-Host $r

# Step 2: Shrink each TempDB file (only free space)
$shrinkSql = @"
SET NOCOUNT ON;
DECLARE @name NVARCHAR(128), @sql NVARCHAR(500);
DECLARE cur CURSOR FAST_FORWARD FOR
    SELECT name FROM tempdb.sys.database_files WHERE type_desc = 'ROWS';
OPEN cur; FETCH NEXT FROM cur INTO @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'USE tempdb; DBCC SHRINKFILE(''' + @name + N''', 0) WITH NO_INFOMSGS;';
    PRINT 'Shrinking: ' + @name;
    EXEC sp_executesql @sql;
    FETCH NEXT FROM cur INTO @name;
END;
CLOSE cur; DEALLOCATE cur;
PRINT 'TempDB shrink complete';
"@
Write-Host "Shrinking TempDB files..."
Write-Host (Invoke-SQL $shrinkSql)

Write-Host "[$DbName] TempDB cleanup complete."
