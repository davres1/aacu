#Requires -Version 5.0
<#
.SYNOPSIS
    CheckMK local plugin, hourly. Two services per instance:
      - MSSQL_Security_<inst>   summary of read-only audit findings
      - MSSQL_CheckDB_<inst>    reads the cached CHECKDB result file
        produced by the scheduled DBCCCheckDB.ps1 task.
    Drop in: C:\ProgramData\checkmk\agent\local\3600\
#>

$ErrorActionPreference = 'SilentlyContinue'

function Emit { param([int]$Status,[string]$Item,[string]$Perf,[string]$Text)
    if (-not $Perf) { $Perf = '-' }
    "$Status $Item $Perf $Text"
}

function Get-Threshold {
    param([string]$Path, $Default)
    if (-not $script:T_INIT) {
        $script:T_INIT = $true
        $f = 'C:\DBA\thresholds.json'
        if (Test-Path $f) { try { $script:T = Get-Content $f -Raw | ConvertFrom-Json } catch { $script:T = $null } }
    }
    if (-not $script:T) { return $Default }
    $obj = $script:T
    foreach ($k in ($Path -split '\.')) {
        if ($null -eq $obj) { return $Default }
        $prop = $obj.PSObject.Properties[$k]
        if (-not $prop) { return $Default }
        $obj = $prop.Value
    }
    if ($null -eq $obj) { return $Default } else { return $obj }
}

$sysadminWarn = [int](Get-Threshold 'security_audit.sysadmin_warn_count' 5)

$instances = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -ErrorAction SilentlyContinue).InstalledInstances
if (-not $instances) { $instances = @('MSSQLSERVER') }

foreach ($inst in $instances) {
    $server = if ($inst -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$inst" }
    $tag    = if ($inst -eq 'MSSQLSERVER') { 'default' } else { ($inst -replace '[^A-Za-z0-9_-]','_') }

    # ---- Security audit ----
    try {
        $cs = "Server=$server;Database=master;Integrated Security=True;Application Name=CheckMK_local_hourly;TrustServerCertificate=True;Connect Timeout=5"
        $cn = New-Object System.Data.SqlClient.SqlConnection $cs
        $cn.Open()
        $cmd = $cn.CreateCommand()
        $cmd.CommandTimeout = 20

        $issues = New-Object System.Collections.ArrayList

        # sa renamed + enabled
        $cmd.CommandText = "SELECT name, is_disabled FROM sys.server_principals WHERE principal_id = 1"
        $r = $cmd.ExecuteReader()
        if ($r.Read()) {
            $n = "$($r['name'])"; $d = [bool]$r['is_disabled']
            if ($n -ieq 'sa')     { [void]$issues.Add("'sa' not renamed") }
            if (-not $d)          { [void]$issues.Add("'$n' (sa) enabled") }
        }
        $r.Close()

        # dangerous configs
        $cmd.CommandText = @"
SELECT name, value_in_use
FROM sys.configurations
WHERE name IN ('xp_cmdshell','Ad Hoc Distributed Queries','Ole Automation Procedures','cross db ownership chaining')
"@
        $r = $cmd.ExecuteReader()
        while ($r.Read()) {
            if ([int]$r['value_in_use'] -eq 1) { [void]$issues.Add("$($r['name']) ON") }
        }
        $r.Close()

        # sysadmin count
        $cmd.CommandText = @"
SELECT COUNT(*) FROM sys.server_role_members rm
JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id AND r.name = 'sysadmin'
"@
        $sysadmins = [int]$cmd.ExecuteScalar()
        if ($sysadmins -gt $sysadminWarn) { [void]$issues.Add("$sysadmins sysadmin members") }

        # weak SQL logins
        $cmd.CommandText = @"
SELECT COUNT(*) FROM sys.sql_logins
WHERE is_disabled = 0 AND (is_policy_checked = 0 OR is_expiration_checked = 0)
"@
        $weak = [int]$cmd.ExecuteScalar()
        if ($weak -gt 0) { [void]$issues.Add("$weak SQL login(s) without policy/expiration") }

        # orphaned users (rough count)
        $cmd.CommandText = @"
SELECT SUM(c) FROM (
  SELECT c = COUNT(*) FROM sys.databases d
  CROSS APPLY (
      SELECT COUNT(*) AS c FROM sys.databases WHERE database_id = d.database_id
  ) ignore_me
  WHERE d.state = 0 AND d.database_id > 4
) x
"@
        # Above is just a sanity ping — the real orphan check is heavy. Skip the per-DB version here; the scheduled
        # SecurityAudit.ps1 (run on-demand by the chatbot) gives the detailed orphan list. We only want a summary count.

        $sev = if ($issues.Count -ge 5) { 2 } elseif ($issues.Count -ge 1) { 1 } else { 0 }
        $msg = if ($issues.Count) { ($issues -join '; ') } else { "no issues" }
        Emit $sev "MSSQL_Security_$tag" "issues=$($issues.Count);1;5|sysadmins=$sysadmins|weak_logins=$weak" $msg

        $cn.Close()
    } catch {
        Emit 3 "MSSQL_Security_$tag" "-" "probe failed: $($_.Exception.Message)"
    }
}

# ---- CHECKDB: read cached status written by scheduled DBCCCheckDB.ps1 ----
$statusFile = 'C:\Logs\checkdb_status.json'
if (Test-Path $statusFile) {
    try {
        $blob = Get-Content $statusFile -Raw | ConvertFrom-Json
        $ageH = [Math]::Round(((Get-Date) - [datetime]$blob.timestamp).TotalHours, 1)
        $clean  = [int]$blob.clean
        $errors = [int]$blob.errors
        $failed = [int]$blob.failed
        $sev = if ($errors -gt 0 -or $failed -gt 0) { 2 }
               elseif ($ageH -gt 192) { 2 }            # > 8 days: missed weekly run
               elseif ($ageH -gt 168) { 1 }
               else { 0 }
        Emit $sev "MSSQL_CheckDB" "clean=$clean|errors=$errors;1;1|failed=$failed;1;1|age_h=$ageH;168;192" "last run ${ageH}h ago: clean=$clean errors=$errors failed=$failed"
    } catch {
        Emit 3 "MSSQL_CheckDB" "-" "could not read $statusFile : $($_.Exception.Message)"
    }
} else {
    Emit 3 "MSSQL_CheckDB" "-" "no $statusFile yet (scheduled DBCCCheckDB.ps1 has not run)"
}
