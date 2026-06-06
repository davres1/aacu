#Requires -Version 5.0
<#
.SYNOPSIS
    CheckMK local plugin, daily. Reports SQL build age + Windows hotfix age.
    Drop in: C:\ProgramData\checkmk\agent\local\86400\
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

$hotfixWarn = [int](Get-Threshold 'patch.hotfix_warn_age_days' 45)
$hotfixCrit = [int](Get-Threshold 'patch.hotfix_crit_age_days' 90)

$instances = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -ErrorAction SilentlyContinue).InstalledInstances
if (-not $instances) { $instances = @('MSSQLSERVER') }

# SQL build per instance via @@VERSION + ProductVersion (no dbatools needed)
foreach ($inst in $instances) {
    $server = if ($inst -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$inst" }
    $tag    = if ($inst -eq 'MSSQLSERVER') { 'default' } else { ($inst -replace '[^A-Za-z0-9_-]','_') }
    try {
        $cs = "Server=$server;Database=master;Integrated Security=True;Application Name=CheckMK_local_daily;TrustServerCertificate=True;Connect Timeout=5"
        $cn = New-Object System.Data.SqlClient.SqlConnection $cs
        $cn.Open()
        $cmd = $cn.CreateCommand()
        $cmd.CommandTimeout = 10
        $cmd.CommandText = "SELECT product_version = CONVERT(varchar(50), SERVERPROPERTY('ProductVersion')), edition = CONVERT(varchar(100), SERVERPROPERTY('Edition')), product_level = CONVERT(varchar(20), SERVERPROPERTY('ProductLevel'))"
        $r = $cmd.ExecuteReader()
        if ($r.Read()) {
            $ver = "$($r['product_version'])"
            $ed  = "$($r['edition'])"
            $lv  = "$($r['product_level'])"
            $r.Close()
            # We don't know the build age without a lookup table, so just report the version and let the
            # daily PatchLevelCheck.ps1 (chatbot-driven) compute build age via dbatools.
            Emit 0 "MSSQL_Version_$tag" "-" "version=$ver level=$lv edition=$ed"
        } else { $r.Close() }
        $cn.Close()
    } catch {
        Emit 3 "MSSQL_Version_$tag" "-" "probe failed: $($_.Exception.Message)"
    }
}

# Windows hotfix age
try {
    $last = Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($last) {
        $ageD = [int]((Get-Date) - $last.InstalledOn).TotalDays
        $sev = if ($ageD -ge $hotfixCrit) { 2 } elseif ($ageD -ge $hotfixWarn) { 1 } else { 0 }
        Emit $sev "Windows_LastHotfix" "age_days=$ageD;$hotfixWarn;$hotfixCrit" "last hotfix $($last.HotFixID) installed ${ageD}d ago"
    } else {
        Emit 3 "Windows_LastHotfix" "-" "no hotfix history available"
    }
} catch {
    Emit 3 "Windows_LastHotfix" "-" "probe failed: $($_.Exception.Message)"
}
