#Requires -Version 5.0
param(
    [int]$StaleLoginDays = 90
)
<#
.SYNOPSIS
    Comprehensive SQL Server security audit. Reports (does NOT change) on:
      - sysadmin role members (and how many)
      - sa account state (enabled? renamed?)
      - xp_cmdshell, Ad Hoc Distributed Queries, CLR, Database Mail config
      - FORCE ENCRYPTION on each instance
      - Logins missing CHECK_POLICY / CHECK_EXPIRATION
      - Stale logins (no login activity in $StaleLoginDays)
      - Orphaned database users (no matching login)
      - PUBLIC role with non-default permissions on user databases
      - Service Master Key / Database Master Key / certificate expiry
      - TDE state for each database
.NOTES
    Read-only. Safe to run on production. Aim weekly.
#>

try { Import-Module dbatools -ErrorAction Stop } catch { Write-Error "dbatools missing: $_"; exit 1 }

$ErrorActionPreference = "Continue"
$logFile = "C:\Logs\SQL_SecurityAudit_$(Get-Date -Format 'yyyyMMdd').log"
if (-not (Test-Path "C:\Logs")) { New-Item -Path "C:\Logs" -ItemType Directory -Force | Out-Null }
$eventSource = "SQL Server Health Check"

function Log-Message {
    param([string]$Message, [ValidateSet("Information","Warning","Error")][string]$Level = "Information")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
    try { Write-EventLog -LogName Application -Source $eventSource -EventId 1016 -Message $entry -EntryType $Level -ErrorAction SilentlyContinue } catch {}
}

$instances = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty InstalledInstances
if (-not $instances) { $instances = @("MSSQLSERVER") }

$report = [System.Collections.ArrayList]@()

foreach ($instance in $instances) {
    $sqlInstance = if ($instance -eq "MSSQLSERVER") { "localhost" } else { "localhost\$instance" }
    Log-Message "Instance: $sqlInstance"

    $finding = [ordered]@{
        instance = $sqlInstance
        sysadmins = @()
        sa_state = $null
        config = @{}
        force_encryption = $null
        weak_logins = @()
        stale_logins = @()
        orphaned_users = @()
        public_perms = @()
        tde_databases = @()
        cert_expiry = @()
        issues = [System.Collections.ArrayList]@()
    }

    try {
        # 1. sysadmin role membership
        $sa = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT login_name = p.name, is_disabled = p.is_disabled, login_type = p.type_desc,
       last_login = (SELECT MAX(login_time) FROM sys.dm_exec_sessions WHERE login_name = p.name)
FROM sys.server_role_members rm
JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id AND r.name = 'sysadmin'
JOIN sys.server_principals p ON p.principal_id = rm.member_principal_id
"@
        $finding.sysadmins = @($sa | ForEach-Object { [pscustomobject]@{
            login = "$($_.login_name)"; disabled = [bool]$_.is_disabled; type = "$($_.login_type)"; last_login = "$($_.last_login)"
        } })
        if ($finding.sysadmins.Count -gt 5) { [void]$finding.issues.Add("Sysadmin role has $($finding.sysadmins.Count) members") }

        # 2. sa account state
        $saRow = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT name, is_disabled FROM sys.server_principals WHERE principal_id = 1
"@
        if ($saRow) {
            $finding.sa_state = @{ name = "$($saRow.name)"; disabled = [bool]$saRow.is_disabled }
            if ($saRow.name -ieq 'sa') { [void]$finding.issues.Add("'sa' login not renamed") }
            if (-not $saRow.is_disabled) { [void]$finding.issues.Add("'sa' login is enabled") }
        }

        # 3. Dangerous server config
        $cfg = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT name, value_in_use
FROM sys.configurations
WHERE name IN ('xp_cmdshell','Ad Hoc Distributed Queries','clr enabled','Database Mail XPs','remote access','cross db ownership chaining','Ole Automation Procedures')
"@
        foreach ($r in $cfg) { $finding.config["$($r.name)"] = [int]$r.value_in_use }
        foreach ($k in 'xp_cmdshell','Ad Hoc Distributed Queries','Ole Automation Procedures','cross db ownership chaining') {
            if ($finding.config[$k] -eq 1) { [void]$finding.issues.Add("$k is enabled") }
        }

        # 4. FORCE ENCRYPTION
        try {
            $instKey = if ($instance -eq 'MSSQLSERVER') { 'MSSQLServer' } else { $instance }
            $forceEnc = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instance\MSSQLServer\SuperSocketNetLib" -Name ForceEncryption -ErrorAction SilentlyContinue).ForceEncryption
            $finding.force_encryption = [int]$forceEnc
            if (-not $forceEnc) { [void]$finding.issues.Add("FORCE_ENCRYPTION is OFF") }
        } catch {}

        # 5. Logins without policy / expiration
        $weak = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT name, is_policy_checked, is_expiration_checked, type_desc
FROM sys.sql_logins
WHERE is_disabled = 0
  AND (is_policy_checked = 0 OR is_expiration_checked = 0)
"@
        $finding.weak_logins = @($weak | ForEach-Object { [pscustomobject]@{
            login = "$($_.name)"; policy_checked = [bool]$_.is_policy_checked; expiration_checked = [bool]$_.is_expiration_checked
        } })
        if ($finding.weak_logins.Count) { [void]$finding.issues.Add("$($finding.weak_logins.Count) SQL logins missing CHECK_POLICY/CHECK_EXPIRATION") }

        # 6. Stale logins
        $stale = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT p.name, last_login = MAX(s.login_time)
FROM sys.server_principals p
LEFT JOIN sys.dm_exec_sessions s ON s.login_name = p.name
WHERE p.type IN ('S','U','G') AND p.is_disabled = 0
GROUP BY p.name
HAVING MAX(s.login_time) IS NULL OR MAX(s.login_time) < DATEADD(DAY, -$StaleLoginDays, GETDATE())
"@
        $finding.stale_logins = @($stale | ForEach-Object { [pscustomobject]@{ login = "$($_.name)"; last_login = "$($_.last_login)" } })

        # 7. Orphaned users + 8. public role grants + 9. TDE state
        $orphaned = [System.Collections.ArrayList]@()
        $publicPerms = [System.Collections.ArrayList]@()
        $tde = [System.Collections.ArrayList]@()
        $databases = Get-DbaDatabase -SqlInstance $sqlInstance -ExcludeSystem -ErrorAction SilentlyContinue |
            Where-Object { $_.IsAccessible -and $_.Status -eq 'Normal' }

        foreach ($db in $databases) {
            try {
                $o = Invoke-DbaQuery -SqlInstance $sqlInstance -Database $db.Name -Query @"
SELECT u.name FROM sys.database_principals u
LEFT JOIN sys.server_principals s ON u.sid = s.sid
WHERE u.type IN ('S','U','G') AND s.sid IS NULL
  AND u.principal_id > 4 AND u.authentication_type IN (1,3)
"@
                foreach ($r in $o) { [void]$orphaned.Add([pscustomobject]@{ database = $db.Name; user = "$($r.name)" }) }

                $pp = Invoke-DbaQuery -SqlInstance $sqlInstance -Database $db.Name -Query @"
SELECT permission_name, state_desc, class_desc, object = OBJECT_NAME(major_id)
FROM sys.database_permissions
WHERE grantee_principal_id = USER_ID('public')
  AND state_desc IN ('GRANT','GRANT_WITH_GRANT_OPTION')
  AND class_desc IN ('OBJECT_OR_COLUMN','SCHEMA','DATABASE')
  AND permission_name NOT IN ('SELECT')  -- public SELECT on system objects is normal
"@
                foreach ($r in $pp) { [void]$publicPerms.Add([pscustomobject]@{
                    database = $db.Name; permission = "$($r.permission_name)"
                    state = "$($r.state_desc)"; class = "$($r.class_desc)"; object = "$($r.object)"
                }) }
            } catch {}
            [void]$tde.Add([pscustomobject]@{
                database = $db.Name
                encrypted = [bool]$db.EncryptionEnabled
            })
        }
        $finding.orphaned_users = @($orphaned)
        $finding.public_perms   = @($publicPerms)
        $finding.tde_databases  = @($tde)

        if ($finding.orphaned_users.Count) { [void]$finding.issues.Add("$($finding.orphaned_users.Count) orphaned database users") }
        if ($finding.public_perms.Count)   { [void]$finding.issues.Add("$($finding.public_perms.Count) PUBLIC role grants on user objects") }

        # 10. Certificate expiry across all databases
        $certs = [System.Collections.ArrayList]@()
        foreach ($db in $databases) {
            try {
                $c = Invoke-DbaQuery -SqlInstance $sqlInstance -Database $db.Name -Query @"
SELECT name, expiry_date, start_date FROM sys.certificates
"@
                foreach ($r in $c) {
                    $daysToExpiry = if ($r.expiry_date) { [int]((($r.expiry_date) - (Get-Date)).TotalDays) } else { $null }
                    [void]$certs.Add([pscustomobject]@{
                        database = $db.Name; certificate = "$($r.name)"
                        expiry = "$($r.expiry_date)"; days_to_expiry = $daysToExpiry
                    })
                    if ($daysToExpiry -ne $null -and $daysToExpiry -lt 60) {
                        [void]$finding.issues.Add("Cert '$($r.name)' in $($db.Name) expires in ${daysToExpiry}d")
                    }
                }
            } catch {}
        }
        $finding.cert_expiry = @($certs)

    } catch { Log-Message "Audit failed on $sqlInstance : $_" "Error"; [void]$finding.issues.Add("Audit error: $($_.Exception.Message)") }

    Log-Message "$sqlInstance issues: $($finding.issues.Count)"
    [void]$report.Add([pscustomobject]$finding)
}

$summary = [pscustomobject]@{
    timestamp = (Get-Date -Format 'o')
    instances = @($report)
    total_issues = ($report | ForEach-Object { $_.issues.Count } | Measure-Object -Sum).Sum
}
$summary | ConvertTo-Json -Depth 8 -Compress
Log-Message "=== SecurityAudit issues=$($summary.total_issues) ==="
exit $(if ($summary.total_issues -gt 0) { 1 } else { 0 })
