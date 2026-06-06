#Requires -Version 5.0
param(
    [ValidateSet("All","L1","L2")] [string]$Level = "All",
    [string]$ReportPath = "C:\Logs\SQL_CIS2022_$(Get-Date -Format 'yyyyMMdd_HHmmss').json",
    [string]$RollbackPath = "C:\Logs\SQL_CIS2022_$(Get-Date -Format 'yyyyMMdd_HHmmss')_rollback.sql",
    [string[]]$Controls = @(),
    [switch]$Remediate,
    [switch]$WhatIf,
    [switch]$AsAnsibleFact
)
<#
.SYNOPSIS
    CIS Microsoft SQL Server 2022 Benchmark v1.0.0 - audit & remediation script.

.DESCRIPTION
    Walks every local SQL Server 2022 instance and evaluates each automatable
    CIS control across these sections:

      1. Installation, Updates and Patches
      2. Surface Area Reduction
      3. Authentication and Authorization
      4. Password Policies
      5. Auditing and Logging
      6. Application Development
      7. Encryption
      8. Appendix - Additional Considerations

    Each control is recorded with id, title, CIS level, status (Pass/Fail/Manual),
    the observed value, and the CIS-recommended setting. Output is JSON written
    to $ReportPath and (optionally) emitted to stdout for Ansible facts.d.

    With -Remediate, the script ALSO applies fixes for the controls that have
    a safe, well-defined remediation. Before any change is made it:
      1. Captures the current/observed value into the log
      2. Appends a REVERT command (T-SQL or PowerShell) to a rollback file so
         every change can be undone by running the rollback file alone
      3. Executes the fix and logs the AFTER state

.PARAMETER Level
    Filter controls by CIS level. L1 = baseline server, L2 = high-security
    (more restrictive, may impact functionality). Default 'All'.

.PARAMETER ReportPath
    Where to write the JSON report. Defaults to C:\Logs\SQL_CIS2022_<ts>.json.

.PARAMETER RollbackPath
    Where to write the cumulative T-SQL/PowerShell rollback script. Running
    this file restores every captured BEFORE-state. Defaults to
    C:\Logs\SQL_CIS2022_<ts>_rollback.sql.

.PARAMETER Controls
    Optional list of CIS control IDs to act on (e.g. 2.1,2.9,4.3). When set,
    only these controls are evaluated/remediated. Empty = all controls.

.PARAMETER Remediate
    Apply fixes for failing controls that support safe auto-remediation. When
    omitted, the script is strictly read-only.

.PARAMETER WhatIf
    With -Remediate, log the BEFORE state and the proposed fix + revert
    commands, but do NOT execute the fix. Useful for change-management review
    before running for real.

.PARAMETER AsAnsibleFact
    Also write the JSON to stdout so Ansible's facts.d / win_shell can capture
    it directly into ansible_facts.

.NOTES
    Designed to be copied to Windows targets via an Ansible playbook
    (win_copy + win_shell) and run on demand or on a schedule. Requires the
    dbatools PowerShell module and an account with VIEW SERVER STATE
    (plus ALTER SETTINGS / ALTER ANY LOGIN / ALTER DATABASE when remediating).

    Distribute via Ansible task:
        - name: Drop CIS benchmark script
          win_copy:
            src: files/CISBenchmarkSQL2022.ps1
            dest: C:\\ProgramData\\Ansible\\CISBenchmarkSQL2022.ps1
        - name: Run CIS benchmark (audit only)
          win_shell: |
            powershell.exe -ExecutionPolicy Bypass `
              -File C:\\ProgramData\\Ansible\\CISBenchmarkSQL2022.ps1 -AsAnsibleFact
          register: cis_result
        - name: Remediate (only after change approval)
          win_shell: |
            powershell.exe -ExecutionPolicy Bypass `
              -File C:\\ProgramData\\Ansible\\CISBenchmarkSQL2022.ps1 `
              -Remediate -Controls 2.1,2.2,2.4,2.5
#>

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
try {
    if (-not (Get-Module -ListAvailable -Name dbatools)) {
        Install-Module -Name dbatools -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
    }
    Import-Module dbatools -ErrorAction Stop -DisableNameChecking | Out-Null
    try { Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true -ErrorAction SilentlyContinue } catch {}
} catch {
    Write-Error "dbatools module unavailable: $_"
    exit 1
}

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

if (-not (Test-Path "C:\Logs")) { New-Item -Path "C:\Logs" -ItemType Directory -Force | Out-Null }
$logFile     = "C:\Logs\SQL_CIS2022_$(Get-Date -Format 'yyyyMMdd').log"
$eventSource = "SQL Server Health Check"

function Log-Message {
    param([string]$Message, [ValidateSet("Information","Warning","Error")][string]$Level = "Information")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($eventSource)) {
            New-EventLog -LogName Application -Source $eventSource -ErrorAction SilentlyContinue
        }
        Write-EventLog -LogName Application -Source $eventSource -EventId 1020 -Message $entry -EntryType $Level -ErrorAction SilentlyContinue
    } catch {}
}

# ---------------------------------------------------------------------------
# Rollback file - seeded with a header. Every applied remediation appends a
# section here containing the captured BEFORE state and the T-SQL/PowerShell
# needed to revert. Running this file end-to-end fully undoes the run.
# ---------------------------------------------------------------------------
if ($Remediate) {
    $header = @(
        "-- =====================================================================",
        "-- CIS SQL Server 2022 Benchmark - ROLLBACK script",
        "-- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "-- Host:      $env:COMPUTERNAME",
        "-- Operator:  $env:USERDOMAIN\$env:USERNAME",
        "-- WhatIf:    $WhatIf",
        "-- Controls:  $($Controls -join ',')",
        "-- ",
        "-- To revert every change captured during this run, execute this file",
        "-- end-to-end (sqlcmd -E -S <instance> -i <this-file>) or copy each",
        "-- block back into the relevant instance via SSMS.",
        "-- =====================================================================",
        ""
    ) -join "`r`n"
    Set-Content -Path $RollbackPath -Value $header -Encoding UTF8
    Log-Message "Remediation mode ENABLED (WhatIf=$WhatIf). Rollback file: $RollbackPath" "Warning"
}

function Add-RollbackEntry {
    param(
        [string]$Instance, [string]$ControlId, [string]$Title,
        [string]$BeforeState, [string]$RevertSql, [string]$Database = $null
    )
    if (-not $Remediate) { return }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $block = @(
        "-- ---------------------------------------------------------------------"
        "-- Control: $ControlId  $Title"
        "-- Instance: $Instance$(if ($Database) { "   Database: $Database" })"
        "-- Captured: $stamp"
        "-- BEFORE  : $BeforeState"
        "-- ---------------------------------------------------------------------"
        $(if ($Database) { ":CONNECT $Instance`r`nUSE [$Database];" } else { ":CONNECT $Instance" })
        $RevertSql
        "GO"
        ""
    ) -join "`r`n"
    Add-Content -Path $RollbackPath -Value $block -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Result recorder + auto-remediation dispatcher
# ---------------------------------------------------------------------------
$global:Findings   = [System.Collections.ArrayList]@()
$global:Remediated = [System.Collections.ArrayList]@()

function Invoke-Remediation {
    param(
        [string]$Instance, [string]$ControlId, [string]$Title,
        [string]$BeforeState, [string]$FixSql, [string]$RevertSql,
        [string]$Database = $null,
        [scriptblock]$FixScript, [scriptblock]$RevertScript
    )
    # Honour -Controls filter
    if ($Controls.Count -gt 0 -and ($Controls -notcontains $ControlId)) { return $false }

    Log-Message "REMEDIATE $ControlId : $Title$(if ($Database) { " [db=$Database]" })" "Warning"
    Log-Message "  BEFORE: $BeforeState"
    if ($FixSql)    { Log-Message "  FIX   : $FixSql" }
    if ($RevertSql) { Log-Message "  REVERT: $RevertSql" }

    # Capture rollback BEFORE running fix - if fix succeeds we already have undo
    if ($RevertSql) {
        Add-RollbackEntry -Instance $Instance -ControlId $ControlId -Title $Title `
                          -BeforeState $BeforeState -RevertSql $RevertSql -Database $Database
    } elseif ($RevertScript) {
        $psBlock = "<# PowerShell revert for $ControlId on $Instance ($BeforeState) #>`r`n$($RevertScript.ToString())"
        Add-RollbackEntry -Instance $Instance -ControlId $ControlId -Title $Title `
                          -BeforeState $BeforeState -RevertSql $psBlock -Database $Database
    }

    if ($WhatIf) {
        Log-Message "  WHATIF: skipped execution"
        [void]$global:Remediated.Add([pscustomobject]@{
            instance=$Instance; cis_id=$ControlId; title=$Title; database=$Database
            before_state=$BeforeState; fix=$FixSql; revert=$RevertSql
            applied=$false; whatif=$true; at=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        })
        return $true
    }

    try {
        if ($FixSql) {
            if ($Database) {
                Invoke-DbaQuery -SqlInstance $Instance -Database $Database -Query $FixSql -EnableException -ErrorAction Stop | Out-Null
            } else {
                Invoke-DbaQuery -SqlInstance $Instance -Query $FixSql -EnableException -ErrorAction Stop | Out-Null
            }
        } elseif ($FixScript) {
            & $FixScript
        }
        Log-Message "  APPLIED: $ControlId fixed"
        [void]$global:Remediated.Add([pscustomobject]@{
            instance=$Instance; cis_id=$ControlId; title=$Title; database=$Database
            before_state=$BeforeState; fix=$FixSql; revert=$RevertSql
            applied=$true; whatif=$false; at=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        })
        return $true
    } catch {
        Log-Message "  FAILED: $($_.Exception.Message)" "Error"
        [void]$global:Remediated.Add([pscustomobject]@{
            instance=$Instance; cis_id=$ControlId; title=$Title; database=$Database
            before_state=$BeforeState; fix=$FixSql; revert=$RevertSql
            applied=$false; error=$_.Exception.Message; at=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        })
        return $false
    }
}

function Add-Check {
    param(
        [string]$Instance,
        [string]$Id,
        [string]$Title,
        [ValidateSet("L1","L2")]  [string]$CisLevel = "L1",
        [ValidateSet("Pass","Fail","Manual","Error","NotApplicable")] [string]$Status,
        [string]$Observed,
        [string]$Recommendation,
        [string]$Rationale  = "",
        [string]$FixSql     = $null,
        [string]$RevertSql  = $null,
        [string]$Database   = $null
    )
    if ($script:Level -ne "All" -and $CisLevel -ne $script:Level) { return }
    if ($Controls.Count -gt 0 -and ($Controls -notcontains $Id))   { return }

    $applied = $false
    # Auto-remediate when allowed, the control failed, and we know a safe fix
    if ($Status -eq "Fail" -and $Remediate -and $FixSql -and $RevertSql) {
        $applied = Invoke-Remediation -Instance $Instance -ControlId $Id -Title $Title `
                                      -BeforeState $Observed -FixSql $FixSql -RevertSql $RevertSql -Database $Database
    }

    [void]$global:Findings.Add([pscustomobject]@{
        instance         = $Instance
        cis_id           = $Id
        title            = $Title
        cis_level        = $CisLevel
        status           = $Status
        observed         = $Observed
        recommendation   = $Recommendation
        rationale        = $Rationale
        fix_sql          = $FixSql
        revert_sql       = $RevertSql
        database         = $Database
        remediation_applied = $applied
        checked_at       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    })
}

function Invoke-SqlScalar {
    param($Instance, [string]$Query, $Default = $null)
    try {
        $r = Invoke-DbaQuery -SqlInstance $Instance -Query $Query -EnableException -ErrorAction Stop
        if ($null -eq $r) { return $Default }
        if ($r -is [System.Array]) { return $r[0].PSObject.Properties.Value | Select-Object -First 1 }
        return ($r | Select-Object -First 1 | ForEach-Object { $_.PSObject.Properties.Value | Select-Object -First 1 })
    } catch { return $Default }
}

# ---------------------------------------------------------------------------
# Instance discovery
# ---------------------------------------------------------------------------
$instances = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty InstalledInstances -ErrorAction SilentlyContinue
if (-not $instances) { $instances = @("MSSQLSERVER") }

foreach ($instance in $instances) {
    $sqlInstance = if ($instance -eq "MSSQLSERVER") { "localhost" } else { "localhost\$instance" }
    Log-Message "===== CIS SQL 2022 Benchmark - $sqlInstance ====="

    try {
        $server = Connect-DbaInstance -SqlInstance $sqlInstance -TrustServerCertificate -ErrorAction Stop
    } catch {
        Add-Check -Instance $sqlInstance -Id "0.0" -Title "Connectivity" -Status Error `
                  -Observed $_.Exception.Message -Recommendation "Verify SQL connectivity and permissions"
        continue
    }

    # =======================================================================
    # 1. INSTALLATION, UPDATES AND PATCHES
    # =======================================================================
    try {
        $build = Get-DbaBuild -SqlInstance $sqlInstance -ErrorAction Stop
        $isLatest = $build.SupportedUntil -gt (Get-Date) -and (-not $build.SPTarget -or $build.BuildLevel -ge $build.SPTarget)
        Add-Check -Instance $sqlInstance -Id "1.1" `
            -Title "Ensure Latest SQL Server CU/Security Updates are installed" `
            -Status ($(if ($isLatest) { "Pass" } else { "Fail" })) `
            -Observed "Build $($build.Build) ($($build.NameLevel) $($build.SPLevel) $($build.CULevel))" `
            -Recommendation "Apply latest SQL Server 2022 Cumulative Update / Security Update from Microsoft" `
            -Rationale "Out-of-date instances are exposed to known CVEs and bugs"
    } catch {
        Add-Check -Instance $sqlInstance -Id "1.1" -Title "Latest CU/Security Updates" -Status Error -Observed $_.Exception.Message -Recommendation "Verify Get-DbaBuild can reach Microsoft build catalog"
    }

    # =======================================================================
    # 2. SURFACE AREA REDUCTION (sp_configure based)
    # =======================================================================
    $configChecks = @(
        @{ Id="2.1"; Name="Ad Hoc Distributed Queries"; Expected=0; Level="L1"; Title="Ensure 'Ad Hoc Distributed Queries' Server Configuration Option is set to '0'" }
        @{ Id="2.2"; Name="clr enabled";                Expected=0; Level="L1"; Title="Ensure 'CLR Enabled' Server Configuration Option is set to '0'" }
        @{ Id="2.3"; Name="cross db ownership chaining"; Expected=0; Level="L1"; Title="Ensure 'Cross DB Ownership Chaining' is set to '0'" }
        @{ Id="2.4"; Name="Database Mail XPs";          Expected=0; Level="L1"; Title="Ensure 'Database Mail XPs' is set to '0'" }
        @{ Id="2.5"; Name="Ole Automation Procedures";  Expected=0; Level="L1"; Title="Ensure 'Ole Automation Procedures' is set to '0'" }
        @{ Id="2.6"; Name="remote access";              Expected=0; Level="L1"; Title="Ensure 'Remote Access' is set to '0'" }
        @{ Id="2.7"; Name="remote admin connections";   Expected=0; Level="L1"; Title="Ensure 'Remote Admin Connections' is set to '0' (Non-Clustered)" }
        @{ Id="2.8"; Name="scan for startup procs";     Expected=0; Level="L1"; Title="Ensure 'Scan For Startup Procs' is set to '0'" }
        @{ Id="2.17"; Name="clr strict security";       Expected=1; Level="L1"; Title="Ensure 'clr strict security' is set to '1'" }
    )
    foreach ($cfg in $configChecks) {
        try {
            if ($cfg.Id -eq "2.7" -and $server.IsClustered) {
                Add-Check -Instance $sqlInstance -Id $cfg.Id -Title $cfg.Title -CisLevel $cfg.Level `
                          -Status NotApplicable -Observed "Clustered instance" `
                          -Recommendation "On clustered instances DAC must be enabled - leave at 1"
                continue
            }
            $v = (Get-DbaSpConfigure -SqlInstance $sqlInstance -Name $cfg.Name -ErrorAction Stop).ConfiguredValue
            $st = if ($v -eq $cfg.Expected) { "Pass" } else { "Fail" }
            # Build fix + revert SQL so -Remediate can act AND we capture undo
            $advanced = $false
            $advancedNames = @('clr enabled','clr strict security','Ole Automation Procedures','remote access','scan for startup procs','Database Mail XPs','Ad Hoc Distributed Queries','cross db ownership chaining','remote admin connections')
            if ($advancedNames -contains $cfg.Name) { $advanced = $true }
            $fixSql = @"
$(if ($advanced) { "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;`r`n" })EXEC sp_configure '$($cfg.Name)', $($cfg.Expected); RECONFIGURE;
"@
            $revertSql = @"
$(if ($advanced) { "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;`r`n" })EXEC sp_configure '$($cfg.Name)', $v; RECONFIGURE;
"@
            Add-Check -Instance $sqlInstance -Id $cfg.Id -Title $cfg.Title -CisLevel $cfg.Level -Status $st `
                      -Observed "value=$v" `
                      -Recommendation "EXEC sp_configure '$($cfg.Name)', $($cfg.Expected); RECONFIGURE;" `
                      -FixSql $fixSql -RevertSql $revertSql
        } catch {
            Add-Check -Instance $sqlInstance -Id $cfg.Id -Title $cfg.Title -CisLevel $cfg.Level -Status Error -Observed $_.Exception.Message -Recommendation "Verify sp_configure permissions"
        }
    }

    # 2.9 Trustworthy database property
    try {
        $tw = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT name FROM sys.databases
WHERE is_trustworthy_on = 1 AND name NOT IN ('msdb','model','tempdb','master')
"@ -ErrorAction Stop
        if (-not $tw -or $tw.Count -eq 0) {
            Add-Check -Instance $sqlInstance -Id "2.9" -Title "Ensure 'Trustworthy Database Property' is set to 'Off'" -Status "Pass" `
                      -Observed "No user DBs with TRUSTWORTHY=ON" `
                      -Recommendation "ALTER DATABASE [<db>] SET TRUSTWORTHY OFF"
        } else {
            foreach ($row in $tw) {
                Add-Check -Instance $sqlInstance -Id "2.9" -Title "Ensure 'Trustworthy Database Property' is set to 'Off'" -Status "Fail" `
                          -Observed "TRUSTWORTHY=ON" -Database $row.name `
                          -Recommendation "ALTER DATABASE [$($row.name)] SET TRUSTWORTHY OFF" `
                          -FixSql "ALTER DATABASE [$($row.name)] SET TRUSTWORTHY OFF;" `
                          -RevertSql "ALTER DATABASE [$($row.name)] SET TRUSTWORTHY ON;"
            }
        }
    } catch { Add-Check -Instance $sqlInstance -Id "2.9" -Title "Trustworthy DB Property" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # 2.10 Unnecessary SQL Server protocols disabled (Named Pipes / Shared Memory beyond TCP)
    try {
        $proto = Get-DbaInstanceProtocol -ComputerName $env:COMPUTERNAME -ErrorAction SilentlyContinue |
                 Where-Object { $_.InstanceName -eq $instance }
        $namedPipes = ($proto | Where-Object { $_.DisplayName -eq 'Named Pipes' }).IsEnabled
        $st = if ($namedPipes -eq $false) { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "2.10" -Title "Ensure Unnecessary SQL Server Protocols are set to Disabled" -Status $st `
                  -Observed "NamedPipes=$namedPipes" -Recommendation "Disable Named Pipes / Shared Memory unless required"
    } catch { Add-Check -Instance $sqlInstance -Id "2.10" -Title "Unnecessary Protocols Disabled" -Status Manual -Observed "WMI unavailable" -Recommendation "Verify via SQL Server Configuration Manager" }

    # 2.11 Non-standard TCP port
    try {
        $port = Get-DbaTcpPort -SqlInstance $sqlInstance -ErrorAction SilentlyContinue
        $portVal = if ($port) { $port.Port } else { 1433 }
        $st = if ($portVal -and $portVal -ne 1433) { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "2.11" -Title "Ensure SQL Server is configured to use non-standard ports" -Status $st `
                  -Observed "TCP Port=$portVal" -Recommendation "Change static TCP port from 1433 to a custom value in SQL Server Configuration Manager"
    } catch { Add-Check -Instance $sqlInstance -Id "2.11" -Title "Non-standard TCP port" -Status Manual -Observed $_.Exception.Message -Recommendation "" }

    # 2.12 Hide Instance (L2)
    try {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($server.ServiceName)\MSSQLServer\SuperSocketNetLib"
        $hide = (Get-ItemProperty -Path $regPath -Name HideInstance -ErrorAction SilentlyContinue).HideInstance
        $st = if ($hide -eq 1) { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "2.12" -Title "Ensure 'Hide Instance' option is set to 'Yes' for Production SQL Servers" -CisLevel L2 -Status $st `
                  -Observed "HideInstance=$hide" -Recommendation "Set HideInstance=1 in SQL Server Configuration Manager (Protocols -> Properties -> Flags)"
    } catch { Add-Check -Instance $sqlInstance -Id "2.12" -Title "Hide Instance" -CisLevel L2 -Status Manual -Observed $_.Exception.Message -Recommendation "" }

    # 2.13 sa disabled
    try {
        $sa = Invoke-DbaQuery -SqlInstance $sqlInstance -Query "SELECT name, is_disabled FROM sys.server_principals WHERE sid = 0x01" -ErrorAction Stop
        $st = if ($sa.is_disabled -eq 1) { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "2.13" -Title "Ensure 'sa' Login Account is set to 'Disabled'" -Status $st `
                  -Observed "name=$($sa.name) disabled=$($sa.is_disabled)" -Recommendation "ALTER LOGIN [sa] DISABLE;" `
                  -FixSql    "ALTER LOGIN [$($sa.name)] DISABLE;" `
                  -RevertSql "ALTER LOGIN [$($sa.name)] ENABLE;"
        $st2 = if ($sa.name -ne 'sa') { "Pass" } else { "Fail" }
        # Renaming sa is high-risk - report only, never auto-remediate
        Add-Check -Instance $sqlInstance -Id "2.14" -Title "Ensure 'sa' Login Account has been renamed" -Status $st2 `
                  -Observed "current name=$($sa.name)" -Recommendation "ALTER LOGIN sa WITH NAME = <newname>;"
        Add-Check -Instance $sqlInstance -Id "2.16" -Title "Ensure no login exists with the name 'sa'" `
                  -Status ($(if ($sa.name -ne 'sa') { "Pass" } else { "Fail" })) `
                  -Observed "principal_id 1 name=$($sa.name)" -Recommendation "Rename sa principal; do not recreate a login named 'sa'"
    } catch { Add-Check -Instance $sqlInstance -Id "2.13" -Title "sa account state" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # 2.15 AUTO_CLOSE off on contained databases
    try {
        $ac = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT name FROM sys.databases
WHERE containment <> 0 AND is_auto_close_on = 1
"@ -ErrorAction Stop
        if (-not $ac) {
            Add-Check -Instance $sqlInstance -Id "2.15" -Title "Ensure 'AUTO_CLOSE' is set to 'OFF' on contained databases" -Status "Pass" `
                      -Observed "No offenders" -Recommendation "ALTER DATABASE [<db>] SET AUTO_CLOSE OFF;"
        } else {
            foreach ($row in $ac) {
                Add-Check -Instance $sqlInstance -Id "2.15" -Title "Ensure 'AUTO_CLOSE' is set to 'OFF' on contained databases" -Status "Fail" `
                          -Observed "AUTO_CLOSE=ON contained DB" -Database $row.name `
                          -Recommendation "ALTER DATABASE [$($row.name)] SET AUTO_CLOSE OFF;" `
                          -FixSql    "ALTER DATABASE [$($row.name)] SET AUTO_CLOSE OFF;" `
                          -RevertSql "ALTER DATABASE [$($row.name)] SET AUTO_CLOSE ON;"
            }
        }
    } catch { Add-Check -Instance $sqlInstance -Id "2.15" -Title "AUTO_CLOSE contained DBs" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # =======================================================================
    # 3. AUTHENTICATION AND AUTHORIZATION
    # =======================================================================
    # 3.1 Server Authentication = Windows only
    try {
        $mode = Invoke-DbaQuery -SqlInstance $sqlInstance -Query "SELECT CASE SERVERPROPERTY('IsIntegratedSecurityOnly') WHEN 1 THEN 'Windows' ELSE 'Mixed' END AS m" -ErrorAction Stop
        $st = if ($mode.m -eq 'Windows') { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "3.1" -Title "Ensure 'Server Authentication' Property is set to 'Windows Authentication Mode'" -Status $st `
                  -Observed "Mode=$($mode.m)" -Recommendation "Set authentication to Windows-only via SSMS server properties or registry LoginMode=1"
    } catch { Add-Check -Instance $sqlInstance -Id "3.1" -Title "Server Auth Mode" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # 3.2 Revoke CONNECT from guest on user databases
    try {
        $guest = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT DB_NAME() AS db, dp.permission_name, dp.state_desc
FROM sys.database_permissions dp
JOIN sys.database_principals pr ON dp.grantee_principal_id = pr.principal_id
WHERE pr.name = 'guest' AND dp.permission_name = 'CONNECT' AND dp.state_desc = 'GRANT'
"@ -Database master -ErrorAction Stop
        # broader: scan user DBs
        $bad = @()
        foreach ($db in (Get-DbaDatabase -SqlInstance $sqlInstance -ExcludeSystem -ErrorAction SilentlyContinue)) {
            try {
                $r = Invoke-DbaQuery -SqlInstance $sqlInstance -Database $db.Name -Query @"
SELECT DB_NAME() AS db FROM sys.database_permissions dp
JOIN sys.database_principals pr ON dp.grantee_principal_id = pr.principal_id
WHERE pr.name = 'guest' AND dp.permission_name = 'CONNECT' AND dp.state_desc = 'GRANT'
"@ -ErrorAction Stop
                if ($r) { $bad += $db.Name }
            } catch {}
        }
        if ($bad.Count -eq 0) {
            Add-Check -Instance $sqlInstance -Id "3.2" -Title "Ensure CONNECT permissions on the 'guest' user is Revoked within all SQL Server databases" -Status "Pass" `
                      -Observed "No user DBs grant CONNECT to guest" -Recommendation "USE [<db>]; REVOKE CONNECT FROM guest;"
        } else {
            foreach ($dbName in $bad) {
                Add-Check -Instance $sqlInstance -Id "3.2" -Title "Ensure CONNECT permissions on the 'guest' user is Revoked within all SQL Server databases" -Status "Fail" `
                          -Observed "guest has CONNECT" -Database $dbName `
                          -Recommendation "USE [$dbName]; REVOKE CONNECT FROM guest;" `
                          -FixSql    "USE [$dbName]; REVOKE CONNECT FROM guest;" `
                          -RevertSql "USE [$dbName]; GRANT CONNECT TO guest;"
            }
        }
    } catch { Add-Check -Instance $sqlInstance -Id "3.2" -Title "Guest CONNECT revoke" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # 3.3 Orphaned users
    try {
        $orphans = @()
        foreach ($db in (Get-DbaDatabase -SqlInstance $sqlInstance -ExcludeSystem -ErrorAction SilentlyContinue)) {
            try {
                $o = Get-DbaDbOrphanUser -SqlInstance $sqlInstance -Database $db.Name -ErrorAction SilentlyContinue
                if ($o) { $orphans += $o | ForEach-Object { "$($db.Name)\$($_.User)" } }
            } catch {}
        }
        $st = if ($orphans.Count -eq 0) { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "3.3" -Title "Ensure 'Orphaned Users' are Dropped from SQL Server Databases" -Status $st `
                  -Observed ($(if ($orphans) { $orphans -join ', ' } else { "None" })) `
                  -Recommendation "Drop orphaned users or map them to a real login (sp_change_users_login / ALTER USER WITH LOGIN)"
    } catch { Add-Check -Instance $sqlInstance -Id "3.3" -Title "Orphaned users" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # 3.4 SQL Authentication not used in contained databases
    try {
        $cs = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT name FROM sys.databases WHERE containment <> 0
"@ -ErrorAction Stop
        $bad = @()
        foreach ($db in $cs) {
            $u = Invoke-DbaQuery -SqlInstance $sqlInstance -Database $db.name -Query @"
SELECT name FROM sys.database_principals WHERE authentication_type_desc = 'DATABASE'
"@ -ErrorAction SilentlyContinue
            if ($u) { $bad += "$($db.name): $(($u | ForEach-Object {$_.name}) -join ',')" }
        }
        $st = if ($bad.Count -eq 0) { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "3.4" -Title "Ensure SQL Authentication is not used in contained databases" -Status $st `
                  -Observed ($(if ($bad) { $bad -join '; ' } else { "No contained DB has SQL-auth users" })) `
                  -Recommendation "Use Windows authentication for contained DB users instead of password-based DB users"
    } catch { Add-Check -Instance $sqlInstance -Id "3.4" -Title "Contained DB SQL Auth" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # 3.5-3.7 Service accounts not local admins
    try {
        $localAdmins = (Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue).Name
        foreach ($svcCheck in @(
            @{ Id="3.5"; Title="Ensure the SQL Server's MSSQL Service Account is Not an Administrator"; SvcLike="MSSQL$*","MSSQLSERVER" }
            @{ Id="3.6"; Title="Ensure the SQL Server's SQLAgent Service Account is Not an Administrator"; SvcLike="SQLAgent$*","SQLSERVERAGENT" }
            @{ Id="3.7"; Title="Ensure the SQL Server's Full-Text Service Account is Not an Administrator"; SvcLike="MSSQLFDLauncher$*","MSSQLFDLauncher" }
        )) {
            $svc = $null
            foreach ($pattern in $svcCheck.SvcLike) {
                $svc = Get-CimInstance Win32_Service -Filter "Name like '$($pattern.Replace('*','%'))' AND PathName like '%sqlservr.exe%' OR Name like '$($pattern.Replace('*','%'))'" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($svc) { break }
            }
            if (-not $svc) {
                Add-Check -Instance $sqlInstance -Id $svcCheck.Id -Title $svcCheck.Title -Status NotApplicable -Observed "Service not installed" -Recommendation "n/a"
                continue
            }
            $acct = $svc.StartName
            $isAdmin = $false
            if ($localAdmins -and $acct) {
                foreach ($la in $localAdmins) {
                    if ($la -and ($la -ieq $acct -or $la -ilike "*\$(($acct -split '\\')[-1])")) { $isAdmin = $true; break }
                }
            }
            $st = if ($isAdmin) { "Fail" } else { "Pass" }
            Add-Check -Instance $sqlInstance -Id $svcCheck.Id -Title $svcCheck.Title -Status $st `
                      -Observed "Account=$acct, LocalAdmin=$isAdmin" -Recommendation "Run service under a least-privilege Managed Service Account; remove from local Administrators"
        }
    } catch { Add-Check -Instance $sqlInstance -Id "3.5" -Title "Service account admin checks" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # 3.8 Only public role granted in default databases (master, msdb, tempdb, model)
    try {
        $bad = @()
        foreach ($sysdb in @('master','msdb','tempdb','model')) {
            $r = Invoke-DbaQuery -SqlInstance $sqlInstance -Database $sysdb -Query @"
SELECT dp.permission_name, pr.name AS principal, dp.state_desc
FROM sys.database_permissions dp
JOIN sys.database_principals pr ON dp.grantee_principal_id = pr.principal_id
WHERE pr.name = 'public' AND dp.state_desc = 'GRANT'
  AND dp.permission_name NOT IN ('CONNECT','VIEW DATABASE STATE','SELECT','EXECUTE')
"@ -ErrorAction SilentlyContinue
            if ($r) { $bad += "$sysdb: $($r.Count) non-default grants to public" }
        }
        $st = if ($bad.Count -eq 0) { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "3.8" -Title "Ensure only the default permissions specified by Microsoft are granted to the public server role" -Status $st `
                  -Observed ($(if ($bad) { $bad -join '; ' } else { "Default permissions only" })) `
                  -Recommendation "REVOKE non-default permissions granted to public in system databases"
    } catch { Add-Check -Instance $sqlInstance -Id "3.8" -Title "Public role default perms" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # 3.9 / 3.10 BUILTIN groups / Windows local groups as SQL logins
    try {
        $builtins = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT name FROM sys.server_principals
WHERE type_desc = 'WINDOWS_GROUP'
  AND name LIKE 'BUILTIN\%'
"@ -ErrorAction Stop
        $st = if (-not $builtins) { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "3.9" -Title "Ensure Windows BUILTIN groups are not SQL Logins" -Status $st `
                  -Observed ($(if ($builtins) { ($builtins | ForEach-Object { $_.name }) -join ',' } else { "None" })) `
                  -Recommendation "DROP LOGIN [BUILTIN\<group>] and grant access to specific AD groups instead"

        $locals = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT name FROM sys.server_principals
WHERE type_desc = 'WINDOWS_GROUP'
  AND name LIKE CAST(SERVERPROPERTY('MachineName') AS sysname) + '\%'
"@ -ErrorAction Stop
        $st2 = if (-not $locals) { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "3.10" -Title "Ensure Windows local groups are not SQL Logins" -Status $st2 `
                  -Observed ($(if ($locals) { ($locals | ForEach-Object { $_.name }) -join ',' } else { "None" })) `
                  -Recommendation "Use domain groups instead of local Windows groups for SQL access"
    } catch { Add-Check -Instance $sqlInstance -Id "3.9" -Title "BUILTIN/local groups as logins" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # 3.11 public role in msdb not granted SQL Agent proxies
    try {
        $proxies = Invoke-DbaQuery -SqlInstance $sqlInstance -Database msdb -Query @"
SELECT pr.name AS proxy, p.name AS principal
FROM dbo.sysproxylogin sl
JOIN sys.database_principals p ON sl.sid = p.sid
JOIN dbo.sysproxies pr ON sl.proxy_id = pr.proxy_id
WHERE p.name = 'public'
"@ -ErrorAction SilentlyContinue
        $st = if (-not $proxies) { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "3.11" -Title "Ensure the public role in the msdb database is not granted access to SQL Agent proxies" -Status $st `
                  -Observed ($(if ($proxies) { ($proxies | ForEach-Object { $_.proxy }) -join ',' } else { "None" })) `
                  -Recommendation "EXEC msdb.dbo.sp_revoke_login_from_proxy @name=N'public', @proxy_name=N'<proxy>'"
    } catch { Add-Check -Instance $sqlInstance -Id "3.11" -Title "msdb public proxy access" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # =======================================================================
    # 4. PASSWORD POLICIES
    # =======================================================================
    try {
        $logins = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT name, is_policy_checked, is_expiration_checked,
       LOGINPROPERTY(name, 'PasswordLastSetTime') AS pwd_last_set
FROM sys.sql_logins WHERE is_disabled = 0
"@ -ErrorAction Stop

        $mustChangeBad = $logins | Where-Object {
            $_.is_policy_checked -eq $true -and (
                [string]::IsNullOrEmpty($_.pwd_last_set) -or
                ([datetime]$_.pwd_last_set) -gt (Get-Date).AddYears(-50)
            )
        }
        # MUST_CHANGE is policy-driven; reporting accounts where it might not be set
        Add-Check -Instance $sqlInstance -Id "4.1" -Title "Ensure 'MUST_CHANGE' Option is set to 'ON' for All SQL Authenticated Logins (within installer/initial creation)" `
                  -Status "Manual" `
                  -Observed "$($logins.Count) SQL logins present; MUST_CHANGE is only inspectable at creation time" `
                  -Recommendation "CREATE LOGIN ... WITH PASSWORD = '...' MUST_CHANGE; for newly provisioned SQL logins"

        $sysadmins = (Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT p.name FROM sys.sql_logins p
JOIN sys.server_role_members rm ON rm.member_principal_id = p.principal_id
JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
WHERE r.name = 'sysadmin' AND p.is_disabled = 0
"@ -ErrorAction Stop)
        $badExp = $logins | Where-Object { $sysadmins.name -contains $_.name -and $_.is_expiration_checked -eq $false }
        Add-Check -Instance $sqlInstance -Id "4.2" -Title "Ensure CHECK_EXPIRATION is set to ON for all SQL Authenticated Logins within the Sysadmin Role" `
                  -Status ($(if (-not $badExp) { "Pass" } else { "Fail" })) `
                  -Observed ($(if ($badExp) { ($badExp | ForEach-Object { $_.name }) -join ',' } else { "All sysadmin SQL logins have CHECK_EXPIRATION=ON" })) `
                  -Recommendation "ALTER LOGIN [<login>] WITH CHECK_EXPIRATION = ON;"

        $badPol = $logins | Where-Object { $_.is_policy_checked -eq $false }
        if (-not $badPol) {
            Add-Check -Instance $sqlInstance -Id "4.3" -Title "Ensure CHECK_POLICY Option is set to ON for All SQL Authenticated Logins" `
                      -Status "Pass" -Observed "All enabled SQL logins have CHECK_POLICY=ON" `
                      -Recommendation "ALTER LOGIN [<login>] WITH CHECK_POLICY = ON;"
        } else {
            foreach ($bp in $badPol) {
                Add-Check -Instance $sqlInstance -Id "4.3" -Title "Ensure CHECK_POLICY Option is set to ON for All SQL Authenticated Logins" `
                          -Status "Fail" -Observed "login=$($bp.name) CHECK_POLICY=OFF" `
                          -Recommendation "ALTER LOGIN [$($bp.name)] WITH CHECK_POLICY = ON;" `
                          -FixSql    "ALTER LOGIN [$($bp.name)] WITH CHECK_POLICY = ON;" `
                          -RevertSql "ALTER LOGIN [$($bp.name)] WITH CHECK_POLICY = OFF;"
            }
        }
    } catch { Add-Check -Instance $sqlInstance -Id "4.x" -Title "Password policy checks" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # =======================================================================
    # 5. AUDITING AND LOGGING
    # =======================================================================
    # 5.1 NumErrorLogs >= 12
    try {
        $n = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($server.ServiceName)\MSSQLServer" -Name NumErrorLogs -ErrorAction SilentlyContinue).NumErrorLogs
        $st = if ($n -ge 12) { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "5.1" -Title "Ensure 'Maximum number of error log files' is set to greater than or equal to 12" -Status $st `
                  -Observed "NumErrorLogs=$n" -Recommendation "Set 'Configure SQL Server Error Logs' / NumErrorLogs registry value to 12+"
    } catch { Add-Check -Instance $sqlInstance -Id "5.1" -Title "Max error log files" -Status Manual -Observed $_.Exception.Message -Recommendation "" }

    # 5.2 Default trace enabled
    try {
        $v = (Get-DbaSpConfigure -SqlInstance $sqlInstance -Name 'default trace enabled' -ErrorAction Stop).ConfiguredValue
        Add-Check -Instance $sqlInstance -Id "5.2" -Title "Ensure 'Default Trace Enabled' Server Configuration Option is set to '1'" `
                  -Status ($(if ($v -eq 1) { "Pass" } else { "Fail" })) -Observed "value=$v" `
                  -Recommendation "EXEC sp_configure 'default trace enabled', 1; RECONFIGURE;"
    } catch { Add-Check -Instance $sqlInstance -Id "5.2" -Title "Default trace enabled" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # 5.3 Login auditing - failed at minimum
    try {
        $audit = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($server.ServiceName)\MSSQLServer" -Name AuditLevel -ErrorAction SilentlyContinue).AuditLevel
        # 2 = failed, 3 = both
        $st = if ($audit -ge 2) { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "5.3" -Title "Ensure 'Login Auditing' is set to 'failed logins'" -Status $st `
                  -Observed "AuditLevel=$audit (0=none,1=success,2=failure,3=both)" `
                  -Recommendation "Set 'Login Auditing' to 'Failed logins only' or 'Both' in SSMS Server Properties / Security"
    } catch { Add-Check -Instance $sqlInstance -Id "5.3" -Title "Login auditing" -Status Manual -Observed $_.Exception.Message -Recommendation "" }

    # 5.4 SQL Server Audit for login success/failure (L2)
    try {
        $a = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT s.name AS audit_name, s.is_state_enabled, sa.audit_action_name
FROM sys.server_audits s
LEFT JOIN sys.server_audit_specifications spec ON spec.audit_guid = s.audit_guid
LEFT JOIN sys.server_audit_specification_details sa ON sa.server_specification_id = spec.server_specification_id
WHERE sa.audit_action_name IN ('FAILED_LOGIN_GROUP','SUCCESSFUL_LOGIN_GROUP')
"@ -ErrorAction Stop
        $st = if ($a -and $a.Count -ge 2) { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "5.4" -Title "Ensure 'SQL Server Audit' is set to capture both 'failed' and 'successful logins'" -CisLevel L2 -Status $st `
                  -Observed ($(if ($a) { "$($a.Count) audit actions present" } else { "No login audit actions" })) `
                  -Recommendation "CREATE SERVER AUDIT + SERVER AUDIT SPECIFICATION FOR FAILED_LOGIN_GROUP, SUCCESSFUL_LOGIN_GROUP"
    } catch { Add-Check -Instance $sqlInstance -Id "5.4" -Title "Server audit logins" -CisLevel L2 -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # =======================================================================
    # 6. APPLICATION DEVELOPMENT
    # =======================================================================
    # 6.1 db_chaining off in user DBs
    try {
        $r = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT name FROM sys.databases
WHERE is_db_chaining_on = 1 AND name NOT IN ('master','msdb','tempdb','model')
"@ -ErrorAction Stop
        if (-not $r) {
            Add-Check -Instance $sqlInstance -Id "6.1" -Title "Ensure 'Database Ownership Chaining' is set to OFF" `
                      -Status "Pass" -Observed "No DBs with chaining ON" `
                      -Recommendation "ALTER DATABASE [<db>] SET DB_CHAINING OFF;"
        } else {
            foreach ($row in $r) {
                Add-Check -Instance $sqlInstance -Id "6.1" -Title "Ensure 'Database Ownership Chaining' is set to OFF" `
                          -Status "Fail" -Observed "DB_CHAINING=ON" -Database $row.name `
                          -Recommendation "ALTER DATABASE [$($row.name)] SET DB_CHAINING OFF;" `
                          -FixSql    "ALTER DATABASE [$($row.name)] SET DB_CHAINING OFF;" `
                          -RevertSql "ALTER DATABASE [$($row.name)] SET DB_CHAINING ON;"
            }
        }
    } catch { Add-Check -Instance $sqlInstance -Id "6.1" -Title "DB chaining" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # 6.2 CLR Assembly permission set = SAFE_ACCESS
    try {
        $cu = Invoke-DbaQuery -SqlInstance $sqlInstance -Query @"
SELECT name, permission_set_desc FROM sys.assemblies WHERE is_user_defined = 1 AND permission_set_desc <> 'SAFE_ACCESS'
"@ -ErrorAction Stop
        $st = if (-not $cu) { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "6.2" -Title "Ensure 'CLR Assembly Permission Set' is set to 'SAFE_ACCESS' for All CLR Assemblies" -Status $st `
                  -Observed ($(if ($cu) { ($cu | ForEach-Object { "$($_.name)=$($_.permission_set_desc)" }) -join ',' } else { "All user assemblies SAFE_ACCESS" })) `
                  -Recommendation "ALTER ASSEMBLY [<asm>] WITH PERMISSION_SET = SAFE;"
    } catch { Add-Check -Instance $sqlInstance -Id "6.2" -Title "CLR permission set" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # =======================================================================
    # 7. ENCRYPTION
    # =======================================================================
    # 7.1 Symmetric keys >= AES_128
    try {
        $bad = @()
        foreach ($db in (Get-DbaDatabase -SqlInstance $sqlInstance -ErrorAction SilentlyContinue)) {
            try {
                $r = Invoke-DbaQuery -SqlInstance $sqlInstance -Database $db.Name -Query @"
SELECT name, algorithm_desc FROM sys.symmetric_keys WHERE name <> '##MS_DatabaseMasterKey##'
  AND algorithm_desc NOT IN ('AES_128','AES_192','AES_256')
"@ -ErrorAction SilentlyContinue
                if ($r) { $bad += $r | ForEach-Object { "$($db.Name).$($_.name)=$($_.algorithm_desc)" } }
            } catch {}
        }
        $st = if ($bad.Count -eq 0) { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "7.1" -Title "Ensure 'Symmetric Key encryption algorithm' is set to 'AES_128' or higher in non-system databases" -Status $st `
                  -Observed ($(if ($bad) { $bad -join ',' } else { "All symmetric keys >= AES_128" })) `
                  -Recommendation "Re-create symmetric keys with ALGORITHM = AES_128, AES_192, or AES_256"
    } catch { Add-Check -Instance $sqlInstance -Id "7.1" -Title "Symmetric key alg" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # 7.2 Asymmetric keys >= 2048
    try {
        $bad = @()
        foreach ($db in (Get-DbaDatabase -SqlInstance $sqlInstance -ExcludeSystem -ErrorAction SilentlyContinue)) {
            try {
                $r = Invoke-DbaQuery -SqlInstance $sqlInstance -Database $db.Name -Query @"
SELECT name, key_length FROM sys.asymmetric_keys WHERE key_length < 2048
"@ -ErrorAction SilentlyContinue
                if ($r) { $bad += $r | ForEach-Object { "$($db.Name).$($_.name)=$($_.key_length)" } }
            } catch {}
        }
        $st = if ($bad.Count -eq 0) { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "7.2" -Title "Ensure Asymmetric Key Size is set to 'greater than or equal to 2048' in non-system databases" -Status $st `
                  -Observed ($(if ($bad) { $bad -join ',' } else { "All asymmetric keys >= 2048" })) `
                  -Recommendation "Re-create asymmetric keys with WITH ALGORITHM = RSA_2048 or higher"
    } catch { Add-Check -Instance $sqlInstance -Id "7.2" -Title "Asymmetric key size" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # 7.3 Database Backups encrypted (L2)
    try {
        $r = Invoke-DbaQuery -SqlInstance $sqlInstance -Database msdb -Query @"
SELECT TOP 50 database_name, backup_start_date, encryptor_type
FROM msdb.dbo.backupset
WHERE type = 'D' AND backup_start_date > DATEADD(DAY, -30, GETDATE())
"@ -ErrorAction SilentlyContinue
        $unenc = $r | Where-Object { -not $_.encryptor_type }
        $st = if (-not $unenc) { "Pass" } else { "Fail" }
        Add-Check -Instance $sqlInstance -Id "7.3" -Title "Ensure Database Backups are encrypted" -CisLevel L2 -Status $st `
                  -Observed ($(if ($unenc) { "$($unenc.Count) unencrypted full backups in last 30d" } else { "All recent backups encrypted" })) `
                  -Recommendation "BACKUP DATABASE ... WITH ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = <cert>);"
    } catch { Add-Check -Instance $sqlInstance -Id "7.3" -Title "Backup encryption" -CisLevel L2 -Status Error -Observed $_.Exception.Message -Recommendation "" }

    # 7.4 Force encryption (registry-backed)
    try {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($server.ServiceName)\MSSQLServer\SuperSocketNetLib"
        $fe = (Get-ItemProperty -Path $regPath -Name ForceEncryption -ErrorAction SilentlyContinue).ForceEncryption
        if ($fe -eq 1) {
            Add-Check -Instance $sqlInstance -Id "7.4" -Title "Ensure Network Encryption (FORCE ENCRYPTION) is configured" -Status "Pass" `
                      -Observed "ForceEncryption=$fe" `
                      -Recommendation "Configure a server certificate and set ForceEncryption=1 in SQL Server Configuration Manager"
        } else {
            Add-Check -Instance $sqlInstance -Id "7.4" -Title "Ensure Network Encryption (FORCE ENCRYPTION) is configured" -Status "Fail" `
                      -Observed "ForceEncryption=$fe (registry: $regPath)" `
                      -Recommendation "Set-ItemProperty -Path '$regPath' -Name ForceEncryption -Value 1; then restart SQL service"
            # Registry remediation - handle manually since Add-Check fix path is T-SQL only
            if ($Remediate -and ($Controls.Count -eq 0 -or $Controls -contains "7.4")) {
                Log-Message "REMEDIATE 7.4 : Force encryption (registry)" "Warning"
                Log-Message "  BEFORE: ForceEncryption=$fe"
                $fixCmd    = "Set-ItemProperty -Path '$regPath' -Name ForceEncryption -Value 1 -Type DWord -Force"
                $revertCmd = if ($null -eq $fe) { "Remove-ItemProperty -Path '$regPath' -Name ForceEncryption -ErrorAction SilentlyContinue" } else { "Set-ItemProperty -Path '$regPath' -Name ForceEncryption -Value $fe -Type DWord -Force" }
                Log-Message "  FIX   : $fixCmd"
                Log-Message "  REVERT: $revertCmd"
                Add-RollbackEntry -Instance $sqlInstance -ControlId "7.4" -Title "Force Encryption registry" `
                                  -BeforeState "ForceEncryption=$fe" `
                                  -RevertSql "<# PowerShell - not T-SQL #>`r`n$revertCmd"
                if (-not $WhatIf) {
                    try { Invoke-Expression $fixCmd; Log-Message "  APPLIED (restart SQL service to activate)" }
                    catch { Log-Message "  FAILED: $($_.Exception.Message)" "Error" }
                } else { Log-Message "  WHATIF: skipped" }
            }
        }
    } catch { Add-Check -Instance $sqlInstance -Id "7.4" -Title "Force encryption" -Status Manual -Observed $_.Exception.Message -Recommendation "" }

    # =======================================================================
    # 8. APPENDIX
    # =======================================================================
    # 8.1 SQL Server Browser disabled if not needed (service - PowerShell remediation)
    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name = 'SQLBrowser'" -ErrorAction SilentlyContinue
        if ($svc) {
            $compliant = ($svc.StartMode -eq 'Disabled' -or $svc.State -ne 'Running')
            $st = if ($compliant) { "Pass" } else { "Fail" }
            Add-Check -Instance $sqlInstance -Id "8.1" -Title "Ensure 'SQL Server Browser Service' is configured correctly" -Status $st `
                      -Observed "StartMode=$($svc.StartMode), State=$($svc.State)" `
                      -Recommendation "Disable SQL Browser unless multiple instances or dynamic ports require it"
            if (-not $compliant -and $Remediate -and ($Controls.Count -eq 0 -or $Controls -contains "8.1")) {
                Log-Message "REMEDIATE 8.1 : SQL Browser service" "Warning"
                $beforeStartMode = $svc.StartMode
                $beforeState     = $svc.State
                Log-Message "  BEFORE: StartMode=$beforeStartMode, State=$beforeState"
                $fixCmd    = "Set-Service -Name SQLBrowser -StartupType Disabled; Stop-Service -Name SQLBrowser -Force -ErrorAction SilentlyContinue"
                $revertCmd = "Set-Service -Name SQLBrowser -StartupType $beforeStartMode$(if ($beforeState -eq 'Running') { '; Start-Service -Name SQLBrowser' })"
                Log-Message "  FIX   : $fixCmd"
                Log-Message "  REVERT: $revertCmd"
                Add-RollbackEntry -Instance $sqlInstance -ControlId "8.1" -Title "SQL Browser service" `
                                  -BeforeState "StartMode=$beforeStartMode, State=$beforeState" `
                                  -RevertSql "<# PowerShell - not T-SQL #>`r`n$revertCmd"
                if (-not $WhatIf) {
                    try { Invoke-Expression $fixCmd; Log-Message "  APPLIED" }
                    catch { Log-Message "  FAILED: $($_.Exception.Message)" "Error" }
                } else { Log-Message "  WHATIF: skipped" }
            }
        } else {
            Add-Check -Instance $sqlInstance -Id "8.1" -Title "SQL Server Browser Service" -Status NotApplicable -Observed "Service not installed" -Recommendation "n/a"
        }
    } catch { Add-Check -Instance $sqlInstance -Id "8.1" -Title "SQL Browser" -Status Error -Observed $_.Exception.Message -Recommendation "" }

    try { $server.ConnectionContext.Disconnect() } catch {}
}

# ---------------------------------------------------------------------------
# Summary + output
# ---------------------------------------------------------------------------
$summary = @{
    hostname           = $env:COMPUTERNAME
    fqdn               = ([System.Net.Dns]::GetHostByName($env:COMPUTERNAME)).HostName
    benchmark          = "CIS Microsoft SQL Server 2022 Benchmark v1.0.0"
    level_filter       = $Level
    control_filter     = $Controls
    collected_at       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    instances          = @($instances)
    total_checks       = $global:Findings.Count
    pass               = ($global:Findings | Where-Object status -eq 'Pass').Count
    fail               = ($global:Findings | Where-Object status -eq 'Fail').Count
    manual             = ($global:Findings | Where-Object status -eq 'Manual').Count
    error              = ($global:Findings | Where-Object status -eq 'Error').Count
    not_applicable     = ($global:Findings | Where-Object status -eq 'NotApplicable').Count
    remediate_mode     = [bool]$Remediate
    whatif_mode        = [bool]$WhatIf
    remediations       = $global:Remediated
    remediations_applied = ($global:Remediated | Where-Object { $_.applied }).Count
    rollback_file      = if ($Remediate) { $RollbackPath } else { $null }
    findings           = $global:Findings
}

$json = $summary | ConvertTo-Json -Depth 8
Set-Content -Path $ReportPath -Value $json -Encoding UTF8
Log-Message "CIS report written: $ReportPath (Pass=$($summary.pass) Fail=$($summary.fail) Manual=$($summary.manual) Error=$($summary.error))"
if ($Remediate) {
    Log-Message "Remediations: $($summary.remediations_applied) applied / $($global:Remediated.Count) attempted. Rollback file: $RollbackPath" "Warning"
    Add-Content -Path $RollbackPath -Value "`r`n-- End of rollback script. Total entries: $($global:Remediated.Count)" -Encoding UTF8
}

if ($AsAnsibleFact) {
    Write-Output $json
} else {
    $global:Findings | Format-Table cis_id, cis_level, status, database, title -AutoSize
    if ($Remediate) {
        Write-Host ""
        Write-Host "=== Remediation summary ==="
        $global:Remediated | Format-Table cis_id, database, applied, whatif, error -AutoSize
        Write-Host "Rollback script: $RollbackPath"
    }
}
