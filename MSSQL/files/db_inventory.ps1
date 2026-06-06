#Requires -Version 5.0
<#
.SYNOPSIS
    Collects comprehensive MSSQL Server facts for Ansible (facts.d) inventory using dbatools.

.DESCRIPTION
    Gathers SQL Server inventory data suitable for health checks, executive dashboards,
    sizing analysis and security/compliance reporting. Collects:

      * Instance identity, edition, build, patch / CU level, service pack
      * Host OS, drive (disk) space and SQL Server installed KB hotfixes
      * Configuration (max memory, MAXDOP, auth mode, TDE, etc.)
      * Database list with status, recovery model, owner, compatibility level
      * Database sizing (data, log, total, used, free, growth settings)
      * Per-file (tablespace) details with drive, path, size, free space, autogrowth
      * Backup summary (last full / diff / log) per database
      * SQL Logins, server roles, sysadmin members, database users & role mapping
      * SQL Agent jobs, schedules, last run status, recent failures
      * High Availability (Always On AG / replicas / mirroring) state
      * Security posture (auth mode, TDE, sa account state, login audit)

    Output is a single JSON document on stdout, consumable by Ansible's facts.d plugin.

.NOTES
    Drop this file into C:\ProgramData\ansible\facts.d\db_inventory.ps1 (or equivalent)
    so it runs as a custom facts plugin during 'setup' / fact gathering. Requires the
    'dbatools' PowerShell module and an account with VIEW SERVER STATE on each instance.
#>

# ---------------------------------------------------------------------------
# Module bootstrap
# ---------------------------------------------------------------------------
try {
    if (-not (Get-Module -ListAvailable -Name dbatools)) {
        Write-Error "dbatools module is not installed. Installing..."
        Install-Module -Name dbatools -Force -AllowClobber -Scope AllUsers
    }
    Import-Module dbatools -ErrorAction Stop -DisableNameChecking | Out-Null
    # Silence dbatools telemetry / confirmation prompts where supported
    try { Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true -ErrorAction SilentlyContinue } catch {}
    try { Set-DbatoolsConfig -FullName sql.connection.encrypt   -Value $false -ErrorAction SilentlyContinue } catch {}
} catch {
    Write-Error "Failed to import dbatools module: $_"
    exit 1
}

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Format-DateSafe {
    param($value)
    if ($null -eq $value) { return $null }
    try {
        $dt = [datetime]$value
        if ($dt -eq [datetime]::MinValue) { return "Never" }
        return $dt.ToString("yyyy-MM-dd HH:mm:ss")
    } catch { return $null }
}

function Get-LocalSqlInstances {
    $found = New-Object System.Collections.Generic.List[string]
    try {
        # Discover via Windows services (SQL Server Database Engine = MSSQL$<instance> or MSSQLSERVER)
        Get-CimInstance -ClassName Win32_Service -Filter "Name like 'MSSQL%' AND PathName like '%sqlservr.exe%'" -ErrorAction SilentlyContinue |
            ForEach-Object {
                if ($_.Name -eq 'MSSQLSERVER') {
                    $found.Add($env:COMPUTERNAME) | Out-Null
                } elseif ($_.Name -like 'MSSQL$*') {
                    $inst = $_.Name.Split('$', 2)[1]
                    $found.Add("$($env:COMPUTERNAME)\$inst") | Out-Null
                }
            }
    } catch {}

    if ($found.Count -eq 0) {
        # Fallback to a default local connection
        $found.Add("localhost") | Out-Null
    }
    return ,($found | Select-Object -Unique)
}

function Get-DriveSpaceFacts {
    $drives = @()
    try {
        Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue |
            ForEach-Object {
                $sizeGb = if ($_.Size) { [math]::Round($_.Size / 1GB, 2) } else { 0 }
                $freeGb = if ($_.FreeSpace) { [math]::Round($_.FreeSpace / 1GB, 2) } else { 0 }
                $pctFree = if ($sizeGb -gt 0) { [math]::Round(($freeGb / $sizeGb) * 100, 2) } else { 0 }
                $drives += @{
                    drive            = $_.DeviceID
                    label            = $_.VolumeName
                    filesystem       = $_.FileSystem
                    size_gb          = $sizeGb
                    free_gb          = $freeGb
                    used_gb          = [math]::Round($sizeGb - $freeGb, 2)
                    percent_free     = $pctFree
                }
            }
    } catch {}
    return $drives
}

function Get-OsHotfixFacts {
    $hotfixes = @()
    try {
        Get-CimInstance -ClassName Win32_QuickFixEngineering -ErrorAction SilentlyContinue |
            Sort-Object -Property InstalledOn -Descending |
            Select-Object -First 50 |
            ForEach-Object {
                $hotfixes += @{
                    hotfix_id    = $_.HotFixID
                    description  = $_.Description
                    installed_on = Format-DateSafe $_.InstalledOn
                    installed_by = $_.InstalledBy
                }
            }
    } catch {}
    return $hotfixes
}

# ---------------------------------------------------------------------------
# Per-instance collectors
# ---------------------------------------------------------------------------
function Get-InstanceCoreFacts {
    param($server)
    return @{
        instance_name        = $server.Name
        server_name          = $server.NetName
        computer_name        = $server.ComputerNamePhysicalNetBIOS
        version              = $server.Version.ToString()
        version_major        = $server.Version.Major
        build_number         = $server.BuildNumber
        product_level        = $server.ProductLevel          # RTM / SP1 / CU
        product_version      = $server.ProductVersion
        edition              = $server.Edition
        engine_edition       = $server.EngineEdition.ToString()
        service_pack         = $server.ProductLevel
        update_level         = (& { try { $server.Query("SELECT SERVERPROPERTY('ProductUpdateLevel') AS u").Tables[0].Rows[0].u } catch { $null } })
        update_reference     = (& { try { $server.Query("SELECT SERVERPROPERTY('ProductUpdateReference') AS r").Tables[0].Rows[0].r } catch { $null } })
        patch_level          = "$($server.ProductLevel) / Build $($server.BuildNumber)"
        collation            = $server.Collation
        is_clustered         = [bool]$server.IsClustered
        is_hadr_enabled      = [bool]$server.IsHadrEnabled
        is_case_sensitive    = [bool]$server.IsCaseSensitive
        is_single_user       = [bool]$server.IsSingleUser
        service_account      = $server.ServiceAccount
        startup_time         = Format-DateSafe $server.LoginMode
        state                = $server.State.ToString()
        login_mode           = $server.LoginMode.ToString()   # Integrated / Mixed
        default_data_path    = $server.DefaultFile
        default_log_path     = $server.DefaultLog
        backup_directory     = $server.BackupDirectory
        master_db_path       = $server.MasterDBPath
        master_db_log_path   = $server.MasterDBLogPath
        error_log_path       = $server.ErrorLogPath
        physical_memory_mb   = $server.PhysicalMemory
        processors           = $server.Processors
        max_server_memory_mb = $server.Configuration.MaxServerMemory.ConfigValue
        min_server_memory_mb = $server.Configuration.MinServerMemory.ConfigValue
        max_dop              = $server.Configuration.MaxDegreeOfParallelism.ConfigValue
        cost_threshold       = $server.Configuration.CostThresholdForParallelism.ConfigValue
        remote_admin_enabled = [bool]$server.Configuration.RemoteAccess.ConfigValue
    }
}

function Get-InstanceSecurityFacts {
    param($server, $serverName)
    $sec = @{
        authentication_mode = $server.LoginMode.ToString()
        sa_disabled         = $null
        sa_renamed          = $null
        c2_audit_enabled    = [bool]$server.Configuration.C2AuditMode.ConfigValue
        common_criteria     = [bool]$server.Configuration.CommonCriteriaComplianceEnabled.ConfigValue
        xp_cmdshell_enabled = [bool]$server.Configuration.XPCmdShellEnabled.ConfigValue
        clr_enabled         = [bool]$server.Configuration.IsSqlClrEnabled.ConfigValue
        login_audit_setting = $null
        tde_databases       = @()
    }

    try {
        $sa = $server.Logins | Where-Object { $_.Sid -eq [byte[]]@(0x01) -or $_.Name -eq 'sa' } | Select-Object -First 1
        if ($sa) {
            $sec.sa_disabled = [bool]$sa.IsDisabled
            $sec.sa_renamed  = ($sa.Name -ne 'sa')
        }
    } catch {}

    try {
        $audit = $server.Query("EXEC xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'AuditLevel'")
        if ($audit -and $audit.Tables[0].Rows.Count -gt 0) {
            $sec.login_audit_setting = $audit.Tables[0].Rows[0].Data
        }
    } catch {}

    try {
        $tde = $server.Query("SELECT DB_NAME(database_id) AS db FROM sys.dm_database_encryption_keys WHERE encryption_state = 3")
        foreach ($r in $tde.Tables[0].Rows) { $sec.tde_databases += $r.db }
    } catch {}

    return $sec
}

function Get-LoginAndRoleFacts {
    param($server)
    $logins      = @()
    $sysadmins   = @()
    $serverRoles = @{}

    try {
        foreach ($login in $server.Logins) {
            $logins += @{
                name             = $login.Name
                login_type       = $login.LoginType.ToString()
                is_disabled      = [bool]$login.IsDisabled
                is_locked        = [bool]$login.IsLocked
                is_password_expired = [bool]$login.IsPasswordExpired
                default_database = $login.DefaultDatabase
                language         = $login.Language
                created          = Format-DateSafe $login.CreateDate
                last_modified    = Format-DateSafe $login.DateLastModified
                password_policy_enforced = [bool]$login.PasswordPolicyEnforced
                password_expiration_enforced = [bool]$login.PasswordExpirationEnabled
            }
        }
    } catch {}

    try {
        foreach ($role in $server.Roles) {
            $members = @()
            try { $members = @($role.EnumServerRoleMembers()) } catch {}
            $serverRoles[$role.Name] = $members
            if ($role.Name -eq 'sysadmin') { $sysadmins = $members }
        }
    } catch {}

    return @{
        login_count         = $logins.Count
        logins              = $logins
        server_roles        = $serverRoles
        sysadmin_members    = $sysadmins
    }
}

function Get-DatabaseFacts {
    param($server, $serverName)
    $dbList = @()

    foreach ($db in $server.Databases) {
        $dbInfo = @{
            name                = $db.Name
            id                  = $db.ID
            is_system           = [bool]$db.IsSystemObject
            status              = $db.Status.ToString()
            state               = $db.State.ToString()
            owner               = $db.Owner
            recovery_model      = $db.RecoveryModel.ToString()
            compatibility_level = $db.CompatibilityLevel.ToString()
            collation           = $db.Collation
            create_date         = Format-DateSafe $db.CreateDate
            last_backup_date    = Format-DateSafe $db.LastBackupDate
            last_diff_backup    = Format-DateSafe $db.LastDifferentialBackupDate
            last_log_backup     = Format-DateSafe $db.LastLogBackupDate
            read_only           = [bool]$db.ReadOnly
            auto_close          = [bool]$db.AutoClose
            auto_shrink         = [bool]$db.AutoShrink
            page_verify         = $db.PageVerify.ToString()
            encryption_enabled  = [bool]$db.EncryptionEnabled
            is_mirroring_enabled = [bool]$db.IsMirroringEnabled
            availability_group  = $db.AvailabilityGroupName
            size_mb             = [math]::Round([double]$db.Size, 2)
            data_space_used_mb  = [math]::Round([double]$db.DataSpaceUsage / 1024.0, 2)
            index_space_used_mb = [math]::Round([double]$db.IndexSpaceUsage / 1024.0, 2)
            space_available_mb  = [math]::Round([double]$db.SpaceAvailable / 1024.0, 2)
        }

        # ----- Per-file (tablespace) details -----
        $files = @()
        try {
            foreach ($fg in $db.FileGroups) {
                foreach ($f in $fg.Files) {
                    $usedMb  = [math]::Round([double]$f.UsedSpace / 1024.0, 2)
                    $sizeMb  = [math]::Round([double]$f.Size / 1024.0, 2)
                    $files += @{
                        logical_name  = $f.Name
                        physical_name = $f.FileName
                        file_group    = $fg.Name
                        file_type     = "ROWS"
                        drive         = if ($f.FileName) { [System.IO.Path]::GetPathRoot($f.FileName) } else { $null }
                        size_mb       = $sizeMb
                        used_mb       = $usedMb
                        free_mb       = [math]::Round($sizeMb - $usedMb, 2)
                        max_size_mb   = if ($f.MaxSize -eq -1) { "Unlimited" } else { [math]::Round([double]$f.MaxSize / 1024.0, 2) }
                        growth        = $f.Growth
                        growth_type   = $f.GrowthType.ToString()
                        is_primary    = [bool]$f.IsPrimaryFile
                    }
                }
            }
            foreach ($lf in $db.LogFiles) {
                $usedMb = [math]::Round([double]$lf.UsedSpace / 1024.0, 2)
                $sizeMb = [math]::Round([double]$lf.Size / 1024.0, 2)
                $files += @{
                    logical_name  = $lf.Name
                    physical_name = $lf.FileName
                    file_group    = "LOG"
                    file_type     = "LOG"
                    drive         = if ($lf.FileName) { [System.IO.Path]::GetPathRoot($lf.FileName) } else { $null }
                    size_mb       = $sizeMb
                    used_mb       = $usedMb
                    free_mb       = [math]::Round($sizeMb - $usedMb, 2)
                    max_size_mb   = if ($lf.MaxSize -eq -1) { "Unlimited" } else { [math]::Round([double]$lf.MaxSize / 1024.0, 2) }
                    growth        = $lf.Growth
                    growth_type   = $lf.GrowthType.ToString()
                }
            }
        } catch {}
        $dbInfo.files       = $files
        $dbInfo.file_count  = $files.Count

        # ----- Database users + role memberships -----
        $dbUsers = @()
        try {
            foreach ($u in $db.Users) {
                $roles = @()
                try { $roles = @($u.EnumRoles()) } catch {}
                $dbUsers += @{
                    name             = $u.Name
                    login            = $u.Login
                    user_type        = $u.UserType.ToString()
                    default_schema   = $u.DefaultSchema
                    is_system_object = [bool]$u.IsSystemObject
                    create_date      = Format-DateSafe $u.CreateDate
                    roles            = $roles
                }
            }
        } catch {}
        $dbInfo.users      = $dbUsers
        $dbInfo.user_count = $dbUsers.Count

        $dbList += $dbInfo
    }

    return $dbList
}

function Get-AgentJobFacts {
    param($serverName)
    $jobs = @{
        agent_running    = $false
        job_count        = 0
        enabled_count    = 0
        failed_last_run  = 0
        jobs             = @()
        recent_failures  = @()
    }

    try {
        $jobList = Get-DbaAgentJob -SqlInstance $serverName -ErrorAction SilentlyContinue
        if ($jobList) {
            $jobs.agent_running = $true
            foreach ($job in $jobList) {
                $jobs.job_count++
                if ($job.IsEnabled) { $jobs.enabled_count++ }
                if ($job.LastRunOutcome -eq 'Failed') { $jobs.failed_last_run++ }

                $schedules = @()
                try {
                    foreach ($s in $job.JobSchedules) {
                        $schedules += @{
                            name           = $s.Name
                            enabled        = [bool]$s.IsEnabled
                            frequency_type = $s.FrequencyTypes.ToString()
                        }
                    }
                } catch {}

                $jobs.jobs += @{
                    name              = $job.Name
                    category          = $job.Category
                    enabled           = [bool]$job.IsEnabled
                    owner             = $job.OwnerLoginName
                    description       = $job.Description
                    last_run_date     = Format-DateSafe $job.LastRunDate
                    last_run_outcome  = $job.LastRunOutcome.ToString()
                    next_run_date     = Format-DateSafe $job.NextRunDate
                    current_run_status = $job.CurrentRunStatus.ToString()
                    schedules         = $schedules
                }
            }

            try {
                $hist = Get-DbaAgentJobHistory -SqlInstance $serverName -StartDate (Get-Date).AddDays(-7) -ErrorAction SilentlyContinue |
                        Where-Object { $_.Status -eq 'Failed' -and $_.StepID -eq 0 } |
                        Select-Object -First 25
                foreach ($h in $hist) {
                    $jobs.recent_failures += @{
                        job_name = $h.Job
                        run_date = Format-DateSafe $h.RunDate
                        message  = $h.Message
                    }
                }
            } catch {}
        }
    } catch {}

    return $jobs
}

function Get-BackupSummary {
    param($serverName)
    $summary = @()
    try {
        $bkps = Get-DbaLastBackup -SqlInstance $serverName -ErrorAction SilentlyContinue
        foreach ($b in $bkps) {
            $summary += @{
                database          = $b.Database
                recovery_model    = $b.RecoveryModel
                last_full_backup  = Format-DateSafe $b.LastFullBackup
                last_diff_backup  = Format-DateSafe $b.LastDiffBackup
                last_log_backup   = Format-DateSafe $b.LastLogBackup
                since_full_hours  = if ($b.LastFullBackup) { [math]::Round(((Get-Date) - $b.LastFullBackup).TotalHours, 1) } else { $null }
                since_log_hours   = if ($b.LastLogBackup)  { [math]::Round(((Get-Date) - $b.LastLogBackup).TotalHours, 1)  } else { $null }
            }
        }
    } catch {}
    return $summary
}

function Get-HaFacts {
    param($server, $serverName)
    $ha = @{
        always_on_enabled = [bool]$server.IsHadrEnabled
        availability_groups = @()
        mirroring_partners  = @()
    }
    try {
        if ($server.IsHadrEnabled) {
            $ags = Get-DbaAvailabilityGroup -SqlInstance $serverName -ErrorAction SilentlyContinue
            foreach ($ag in $ags) {
                $replicas = @()
                try {
                    foreach ($r in $ag.AvailabilityReplicas) {
                        $replicas += @{
                            name             = $r.Name
                            role             = $r.Role.ToString()
                            availability_mode = $r.AvailabilityMode.ToString()
                            failover_mode    = $r.FailoverMode.ToString()
                            connection_state = $r.ConnectionState.ToString()
                        }
                    }
                } catch {}
                $ha.availability_groups += @{
                    name              = $ag.Name
                    primary_replica   = $ag.PrimaryReplicaServerName
                    cluster_type      = $ag.ClusterType.ToString()
                    automated_backup_preference = $ag.AutomatedBackupPreference.ToString()
                    replicas          = $replicas
                }
            }
        }
    } catch {}

    try {
        foreach ($db in $server.Databases) {
            if ($db.IsMirroringEnabled) {
                $ha.mirroring_partners += @{
                    database = $db.Name
                    partner  = $db.MirroringPartner
                    role     = $db.MirroringRole.ToString()
                    state    = $db.MirroringStatus.ToString()
                }
            }
        }
    } catch {}

    return $ha
}

# ---------------------------------------------------------------------------
# CIS Microsoft SQL Server 2022 Benchmark - exception detection
# ---------------------------------------------------------------------------
# Lightweight set of CIS controls focused on highlighting WHICH databases /
# logins / settings are non-compliant. Output is structured as exception lists
# so the executive dashboard can pivot "show me every DB that fails control X".
function Get-CisExceptionFacts {
    param($server, $serverName)

    $cis = @{
        benchmark             = "CIS Microsoft SQL Server 2022 Benchmark v1.0.0"
        instance_exceptions   = @()   # instance-level CIS failures
        database_exceptions   = @{}   # db_name -> list of failing control ids
        controls              = @()   # detailed per-control records
        summary               = @{ pass = 0; fail = 0; manual = 0; error = 0 }
    }

    function _Record {
        param($id, $title, $level, $status, $observed, $scope = "instance", $database = $null)
        $rec = @{
            cis_id      = $id
            title       = $title
            cis_level   = $level
            status      = $status
            observed    = $observed
            scope       = $scope
            database    = $database
        }
        $cis.controls += $rec
        switch ($status) {
            "Pass"   { $cis.summary.pass++ }
            "Fail"   { $cis.summary.fail++ }
            "Manual" { $cis.summary.manual++ }
            "Error"  { $cis.summary.error++ }
        }
        if ($status -eq "Fail") {
            if ($scope -eq "database" -and $database) {
                if (-not $cis.database_exceptions.ContainsKey($database)) {
                    $cis.database_exceptions[$database] = @()
                }
                $cis.database_exceptions[$database] += $id
            } else {
                $cis.instance_exceptions += @{ cis_id = $id; title = $title; observed = $observed }
            }
        }
    }

    # ----- 2.x Surface area: sp_configure values -----
    $configChecks = @(
        @{ Id="2.1";  Name="Ad Hoc Distributed Queries"; Expected=0; Title="Ad Hoc Distributed Queries disabled" }
        @{ Id="2.2";  Name="clr enabled";                Expected=0; Title="CLR Enabled disabled" }
        @{ Id="2.3";  Name="cross db ownership chaining"; Expected=0; Title="Cross DB Ownership Chaining disabled" }
        @{ Id="2.4";  Name="Database Mail XPs";          Expected=0; Title="Database Mail XPs disabled" }
        @{ Id="2.5";  Name="Ole Automation Procedures";  Expected=0; Title="Ole Automation Procedures disabled" }
        @{ Id="2.6";  Name="remote access";              Expected=0; Title="Remote Access disabled" }
        @{ Id="2.8";  Name="scan for startup procs";     Expected=0; Title="Scan For Startup Procs disabled" }
        @{ Id="2.17"; Name="clr strict security";        Expected=1; Title="CLR Strict Security enabled" }
        @{ Id="5.2";  Name="default trace enabled";      Expected=1; Title="Default Trace enabled" }
    )
    foreach ($cfg in $configChecks) {
        try {
            $v = (Get-DbaSpConfigure -SqlInstance $serverName -Name $cfg.Name -ErrorAction Stop).ConfiguredValue
            $st = if ($v -eq $cfg.Expected) { "Pass" } else { "Fail" }
            _Record -id $cfg.Id -title $cfg.Title -level "L1" -status $st -observed "value=$v"
        } catch { _Record -id $cfg.Id -title $cfg.Title -level "L1" -status "Error" -observed $_.Exception.Message }
    }

    # ----- 2.9 Trustworthy database property (per-database) -----
    try {
        $r = Invoke-DbaQuery -SqlInstance $serverName -Query @"
SELECT name FROM sys.databases
WHERE is_trustworthy_on = 1 AND name NOT IN ('msdb','model','tempdb','master')
"@ -ErrorAction Stop
        if (-not $r) {
            _Record -id "2.9" -title "TRUSTWORTHY OFF on user DBs" -level "L1" -status "Pass" -observed "No exceptions"
        } else {
            foreach ($row in $r) {
                _Record -id "2.9" -title "TRUSTWORTHY OFF on user DBs" -level "L1" -status "Fail" `
                        -observed "TRUSTWORTHY=ON" -scope "database" -database $row.name
            }
        }
    } catch { _Record -id "2.9" -title "TRUSTWORTHY OFF on user DBs" -level "L1" -status "Error" -observed $_.Exception.Message }

    # ----- 2.13 / 2.14 / 2.16 sa account state -----
    try {
        $sa = Invoke-DbaQuery -SqlInstance $serverName -Query "SELECT name, is_disabled FROM sys.server_principals WHERE sid = 0x01" -ErrorAction Stop
        _Record -id "2.13" -title "'sa' login disabled" -level "L1" `
                -status ($(if ($sa.is_disabled -eq 1) { "Pass" } else { "Fail" })) `
                -observed "name=$($sa.name) disabled=$($sa.is_disabled)"
        _Record -id "2.14" -title "'sa' login renamed"  -level "L1" `
                -status ($(if ($sa.name -ne 'sa') { "Pass" } else { "Fail" })) `
                -observed "current_name=$($sa.name)"
    } catch { _Record -id "2.13" -title "sa account state" -level "L1" -status "Error" -observed $_.Exception.Message }

    # ----- 2.15 AUTO_CLOSE off on contained DBs (per-database) -----
    try {
        $r = Invoke-DbaQuery -SqlInstance $serverName -Query @"
SELECT name FROM sys.databases WHERE containment <> 0 AND is_auto_close_on = 1
"@ -ErrorAction Stop
        if (-not $r) {
            _Record -id "2.15" -title "AUTO_CLOSE OFF on contained DBs" -level "L1" -status "Pass" -observed "No exceptions"
        } else {
            foreach ($row in $r) {
                _Record -id "2.15" -title "AUTO_CLOSE OFF on contained DBs" -level "L1" -status "Fail" `
                        -observed "AUTO_CLOSE=ON contained DB" -scope "database" -database $row.name
            }
        }
    } catch { _Record -id "2.15" -title "AUTO_CLOSE on contained DBs" -level "L1" -status "Error" -observed $_.Exception.Message }

    # ----- 3.1 Server authentication mode -----
    try {
        $mode = Invoke-DbaQuery -SqlInstance $serverName -Query "SELECT CASE SERVERPROPERTY('IsIntegratedSecurityOnly') WHEN 1 THEN 'Windows' ELSE 'Mixed' END AS m" -ErrorAction Stop
        _Record -id "3.1" -title "Windows Authentication Mode" -level "L1" `
                -status ($(if ($mode.m -eq 'Windows') { "Pass" } else { "Fail" })) -observed "Mode=$($mode.m)"
    } catch { _Record -id "3.1" -title "Server auth mode" -level "L1" -status "Error" -observed $_.Exception.Message }

    # ----- 3.2 guest user CONNECT (per-database) -----
    try {
        foreach ($db in $server.Databases | Where-Object { -not $_.IsSystemObject -and $_.IsAccessible }) {
            try {
                $r = Invoke-DbaQuery -SqlInstance $serverName -Database $db.Name -Query @"
SELECT 1 FROM sys.database_permissions dp
JOIN sys.database_principals pr ON dp.grantee_principal_id = pr.principal_id
WHERE pr.name = 'guest' AND dp.permission_name = 'CONNECT' AND dp.state_desc = 'GRANT'
"@ -ErrorAction Stop
                if ($r) {
                    _Record -id "3.2" -title "Revoke CONNECT from guest" -level "L1" -status "Fail" `
                            -observed "guest has CONNECT" -scope "database" -database $db.Name
                }
            } catch {}
        }
    } catch { _Record -id "3.2" -title "Guest CONNECT" -level "L1" -status "Error" -observed $_.Exception.Message }

    # ----- 3.3 Orphaned users (per-database) -----
    try {
        foreach ($db in $server.Databases | Where-Object { -not $_.IsSystemObject -and $_.IsAccessible }) {
            try {
                $o = Get-DbaDbOrphanUser -SqlInstance $serverName -Database $db.Name -ErrorAction SilentlyContinue
                if ($o) {
                    _Record -id "3.3" -title "Orphaned users dropped" -level "L1" -status "Fail" `
                            -observed "Orphans: $(($o | ForEach-Object {$_.User}) -join ',')" -scope "database" -database $db.Name
                }
            } catch {}
        }
    } catch { _Record -id "3.3" -title "Orphaned users" -level "L1" -status "Error" -observed $_.Exception.Message }

    # ----- 3.9 / 3.10 BUILTIN / local Windows groups as SQL logins -----
    try {
        $b = Invoke-DbaQuery -SqlInstance $serverName -Query @"
SELECT name FROM sys.server_principals
WHERE type_desc = 'WINDOWS_GROUP' AND name LIKE 'BUILTIN\%'
"@ -ErrorAction Stop
        _Record -id "3.9" -title "No BUILTIN groups as SQL logins" -level "L1" `
                -status ($(if (-not $b) { "Pass" } else { "Fail" })) `
                -observed ($(if ($b) { ($b | ForEach-Object { $_.name }) -join ',' } else { "None" }))

        $l = Invoke-DbaQuery -SqlInstance $serverName -Query @"
SELECT name FROM sys.server_principals
WHERE type_desc = 'WINDOWS_GROUP'
  AND name LIKE CAST(SERVERPROPERTY('MachineName') AS sysname) + '\%'
"@ -ErrorAction Stop
        _Record -id "3.10" -title "No Windows local groups as SQL logins" -level "L1" `
                -status ($(if (-not $l) { "Pass" } else { "Fail" })) `
                -observed ($(if ($l) { ($l | ForEach-Object { $_.name }) -join ',' } else { "None" }))
    } catch { _Record -id "3.9" -title "BUILTIN/local groups as logins" -level "L1" -status "Error" -observed $_.Exception.Message }

    # ----- 4.2 / 4.3 SQL login password policy / expiration -----
    try {
        $logins = Invoke-DbaQuery -SqlInstance $serverName -Query @"
SELECT name, is_policy_checked, is_expiration_checked
FROM sys.sql_logins WHERE is_disabled = 0
"@ -ErrorAction Stop
        $badPol = $logins | Where-Object { $_.is_policy_checked -eq $false }
        _Record -id "4.3" -title "CHECK_POLICY ON for all enabled SQL logins" -level "L1" `
                -status ($(if (-not $badPol) { "Pass" } else { "Fail" })) `
                -observed ($(if ($badPol) { ($badPol | ForEach-Object { $_.name }) -join ',' } else { "All enforced" }))

        $sysadmins = Invoke-DbaQuery -SqlInstance $serverName -Query @"
SELECT p.name FROM sys.sql_logins p
JOIN sys.server_role_members rm ON rm.member_principal_id = p.principal_id
JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
WHERE r.name = 'sysadmin'
"@ -ErrorAction Stop
        $badExp = $logins | Where-Object { $sysadmins.name -contains $_.name -and $_.is_expiration_checked -eq $false }
        _Record -id "4.2" -title "CHECK_EXPIRATION ON for sysadmin SQL logins" -level "L1" `
                -status ($(if (-not $badExp) { "Pass" } else { "Fail" })) `
                -observed ($(if ($badExp) { ($badExp | ForEach-Object { $_.name }) -join ',' } else { "All enforced" }))
    } catch { _Record -id "4.x" -title "Password policy" -level "L1" -status "Error" -observed $_.Exception.Message }

    # ----- 6.1 DB chaining (per-database) -----
    try {
        $r = Invoke-DbaQuery -SqlInstance $serverName -Query @"
SELECT name FROM sys.databases
WHERE is_db_chaining_on = 1 AND name NOT IN ('master','msdb','tempdb','model')
"@ -ErrorAction Stop
        if (-not $r) {
            _Record -id "6.1" -title "DB chaining OFF on user DBs" -level "L1" -status "Pass" -observed "No exceptions"
        } else {
            foreach ($row in $r) {
                _Record -id "6.1" -title "DB chaining OFF on user DBs" -level "L1" -status "Fail" `
                        -observed "DB_CHAINING=ON" -scope "database" -database $row.name
            }
        }
    } catch { _Record -id "6.1" -title "DB chaining" -level "L1" -status "Error" -observed $_.Exception.Message }

    # ----- 7.1 Symmetric key algorithm >= AES_128 (per-database) -----
    try {
        foreach ($db in $server.Databases | Where-Object { $_.IsAccessible }) {
            try {
                $r = Invoke-DbaQuery -SqlInstance $serverName -Database $db.Name -Query @"
SELECT name, algorithm_desc FROM sys.symmetric_keys
WHERE name <> '##MS_DatabaseMasterKey##'
  AND algorithm_desc NOT IN ('AES_128','AES_192','AES_256')
"@ -ErrorAction Stop
                if ($r) {
                    _Record -id "7.1" -title "Symmetric keys >= AES_128" -level "L1" -status "Fail" `
                            -observed "Weak keys: $(($r | ForEach-Object { "$($_.name)=$($_.algorithm_desc)" }) -join ',')" `
                            -scope "database" -database $db.Name
                }
            } catch {}
        }
    } catch { _Record -id "7.1" -title "Symmetric key algorithm" -level "L1" -status "Error" -observed $_.Exception.Message }

    # ----- 7.2 Asymmetric key length >= 2048 (per-database) -----
    try {
        foreach ($db in $server.Databases | Where-Object { -not $_.IsSystemObject -and $_.IsAccessible }) {
            try {
                $r = Invoke-DbaQuery -SqlInstance $serverName -Database $db.Name -Query @"
SELECT name, key_length FROM sys.asymmetric_keys WHERE key_length < 2048
"@ -ErrorAction Stop
                if ($r) {
                    _Record -id "7.2" -title "Asymmetric keys >= 2048" -level "L1" -status "Fail" `
                            -observed "Weak keys: $(($r | ForEach-Object { "$($_.name)=$($_.key_length)" }) -join ',')" `
                            -scope "database" -database $db.Name
                }
            } catch {}
        }
    } catch { _Record -id "7.2" -title "Asymmetric key size" -level "L1" -status "Error" -observed $_.Exception.Message }

    # ----- 7.4 Force encryption -----
    try {
        $fe = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($server.ServiceName)\MSSQLServer\SuperSocketNetLib" -Name ForceEncryption -ErrorAction SilentlyContinue).ForceEncryption
        _Record -id "7.4" -title "Network Force Encryption" -level "L1" `
                -status ($(if ($fe -eq 1) { "Pass" } else { "Fail" })) -observed "ForceEncryption=$fe"
    } catch { _Record -id "7.4" -title "Force encryption" -level "L1" -status "Manual" -observed $_.Exception.Message }

    # ----- 8.1 SQL Server Browser service -----
    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name = 'SQLBrowser'" -ErrorAction SilentlyContinue
        if ($svc) {
            _Record -id "8.1" -title "SQL Server Browser disabled (when not required)" -level "L1" `
                    -status ($(if ($svc.StartMode -eq 'Disabled' -or $svc.State -ne 'Running') { "Pass" } else { "Fail" })) `
                    -observed "StartMode=$($svc.StartMode), State=$($svc.State)"
        }
    } catch {}

    # Roll-up: total exception count + fail rate
    $cis.total_exceptions      = $cis.summary.fail
    $cis.exception_databases   = @($cis.database_exceptions.Keys)
    $cis.exception_database_count = $cis.exception_databases.Count
    $cis.compliance_score      = if (($cis.summary.pass + $cis.summary.fail) -gt 0) {
        [math]::Round(($cis.summary.pass / ($cis.summary.pass + $cis.summary.fail)) * 100, 1)
    } else { $null }

    return $cis
}

# ---------------------------------------------------------------------------
# Main collection
# ---------------------------------------------------------------------------
$inventoryData = @{}

try {
    $instances = Get-LocalSqlInstances

    foreach ($serverName in $instances) {
        try {
            $server = Connect-DbaInstance -SqlInstance $serverName -TrustServerCertificate -ErrorAction Stop

            $instanceInfo = Get-InstanceCoreFacts -server $server
            $instanceInfo.security    = Get-InstanceSecurityFacts -server $server -serverName $serverName
            $loginFacts               = Get-LoginAndRoleFacts -server $server
            $instanceInfo.access      = $loginFacts
            $instanceInfo.databases   = Get-DatabaseFacts -server $server -serverName $serverName
            $instanceInfo.database_count = $instanceInfo.databases.Count
            $instanceInfo.user_database_count = ($instanceInfo.databases | Where-Object { -not $_.is_system }).Count
            $instanceInfo.total_db_size_mb    = [math]::Round((($instanceInfo.databases | Measure-Object -Property size_mb -Sum).Sum), 2)
            $instanceInfo.agent       = Get-AgentJobFacts -serverName $serverName
            $instanceInfo.backups     = Get-BackupSummary -serverName $serverName
            $instanceInfo.high_availability = Get-HaFacts -server $server -serverName $serverName
            $instanceInfo.cis_compliance    = Get-CisExceptionFacts -server $server -serverName $serverName

            # Stamp each database with its CIS failures so dashboards can
            # filter the database list directly without joining elsewhere.
            if ($instanceInfo.cis_compliance.database_exceptions) {
                foreach ($db in $instanceInfo.databases) {
                    if ($instanceInfo.cis_compliance.database_exceptions.ContainsKey($db.name)) {
                        $db.cis_exceptions  = @($instanceInfo.cis_compliance.database_exceptions[$db.name])
                        $db.cis_compliant   = $false
                    } else {
                        $db.cis_exceptions  = @()
                        $db.cis_compliant   = $true
                    }
                }
            }

            $inventoryData[$serverName] = $instanceInfo

            try { $server.ConnectionContext.Disconnect() } catch {}
        } catch {
            $inventoryData[$serverName] = @{
                status        = "error"
                error_message = $_.Exception.Message
            }
        }
    }

    $output = @{
        mssql                = $inventoryData
        collection_timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        computer_name        = $env:COMPUTERNAME
        fqdn                 = ([System.Net.Dns]::GetHostByName($env:COMPUTERNAME)).HostName
        os_version           = [System.Environment]::OSVersion.Version.ToString()
        os_caption           = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        os_install_date      = Format-DateSafe ((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).InstallDate)
        os_last_boot         = Format-DateSafe ((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime)
        total_physical_memory_gb = [math]::Round(((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory / 1GB), 2)
        logical_processors   = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).NumberOfLogicalProcessors
        drives               = Get-DriveSpaceFacts
        os_hotfixes          = Get-OsHotfixFacts
        instance_count       = $inventoryData.Keys.Count
    }

    Write-Output ($output | ConvertTo-Json -Depth 12 -Compress:$false)

} catch {
    $errorOutput = @{
        error         = "Failed to collect MSSQL inventory"
        error_details = $_.Exception.Message
        timestamp     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    Write-Output ($errorOutput | ConvertTo-Json)
    exit 1
}