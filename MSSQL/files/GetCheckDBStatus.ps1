#Requires -Version 5.0
<#
.SYNOPSIS
    Lightweight reader of the cached DBCC CHECKDB result file (written by
    the scheduled DBCCCheckDB.ps1 task). Designed for chatbot on-demand
    queries — avoids running CHECKDB live, which is heavy.
#>

$ErrorActionPreference = 'Continue'
$statusFile = 'C:\Logs\checkdb_status.json'

if (-not (Test-Path $statusFile)) {
    @{
        timestamp = (Get-Date -Format 'o')
        available = $false
        error = "$statusFile does not exist yet. The scheduled DBCCCheckDB task has not produced a result."
    } | ConvertTo-Json -Compress
    exit 2
}

try {
    $blob = Get-Content $statusFile -Raw | ConvertFrom-Json
    $age = ((Get-Date) - [datetime]$blob.timestamp).TotalHours
    $blob | Add-Member -NotePropertyName age_hours -NotePropertyValue ([Math]::Round($age, 1)) -Force
    $blob | Add-Member -NotePropertyName available -NotePropertyValue $true -Force
    $blob | ConvertTo-Json -Depth 6 -Compress
    exit 0
} catch {
    @{
        available = $false
        error = "Failed to parse $statusFile : $($_.Exception.Message)"
    } | ConvertTo-Json -Compress
    exit 3
}
