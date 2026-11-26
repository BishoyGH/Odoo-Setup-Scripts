<#
.SYNOPSIS
  Shows a desktop warning when Odoo backups are failing or out of date.

.DESCRIPTION
  Run by the "Odoo Backup Check" scheduled task as the signed-in user: at
  sign-in, every morning, and straight after a failed backup. It reads
  logs\last-backup.json (written by backup.ps1) and stays silent when all is
  well. -Always shows the result even when backups are fine (for testing).
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\Odoo',
    [switch]$Always
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    $logic = Join-Path $PSScriptRoot 'OdooSetup.Logic.psm1'
    if (-not (Test-Path $logic)) { $logic = Join-Path $PSScriptRoot '..\lib\OdooSetup.Logic.psm1' }
    Import-Module $logic -DisableNameChecking
    $paths = Get-InstallPaths -Root $Root
    $statusPath = Join-Path $paths.Logs 'last-backup.json'
    $status = $null
    if (Test-Path $statusPath) { $status = Get-Content -Raw $statusPath -Encoding UTF8 | ConvertFrom-Json }
    $config = Get-SettingValue $status 'Config'
    $health = Get-BackupHealth -Status $status `
        -CopyConfigured ([bool][string](Get-SettingValue $config 'CopyDir' '')) `
        -TestRestoreDays ([int](Get-SettingValue $config 'TestRestoreDays' 7))
}
catch {
    # Nothing useful to show if the status cannot be read; never pop up a script error.
    Write-Verbose $_
    exit 0
}

if ($health.Level -eq 'OK' -or $health.Level -eq 'Unknown') {
    if (-not $Always) { exit 0 }
}

$title = 'Odoo backup warning'
$icon = 0x30   # warning
if ($health.Level -eq 'Error') { $title = 'Odoo backup problem'; $icon = 0x10 }   # error
if ($health.Level -eq 'OK') { $title = 'Odoo backups are OK'; $icon = 0x40 }      # information

$lines = @($health.Messages | ForEach-Object { '- ' + $_ })
$text = ($lines -join "`r`n") + "`r`n`r`n" +
    "Your company data may not be safe until this is fixed.`r`n" +
    ('Details: {0}' -f (Join-Path $paths.Logs 'backup.log')) + "`r`n" +
    ('Back up now: {0}\odoo-ctl.ps1 backup (as Administrator)' -f $paths.Tools)
if ($health.Level -eq 'OK') { $text = 'The last backup, second copy and test-restore all succeeded.' }

# 0x1000 = stay on top of other windows so it is not missed.
$shell = New-Object -ComObject WScript.Shell
[void]$shell.Popup($text, 0, $title, $icon + 0x1000)
exit 0
