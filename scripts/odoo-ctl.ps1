<#
.SYNOPSIS
  Day-to-day control of an Odoo installed by Odoo-Setup-Scripts.

.EXAMPLE
  odoo-ctl.ps1 status
  odoo-ctl.ps1 restart
  odoo-ctl.ps1 logs
  odoo-ctl.ps1 update -Modules sale,stock      # upgrade modules after copying new code
  odoo-ctl.ps1 update -Modules all
  odoo-ctl.ps1 backup
  odoo-ctl.ps1 test-restore                    # back up now and prove the backup restores
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('status', 'start', 'stop', 'restart', 'logs', 'update', 'backup', 'test-restore', 'open')]
    [string]$Command = 'status',
    [string]$Modules = '',
    [string]$Root = 'C:\Odoo'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$logic = Join-Path $PSScriptRoot 'OdooSetup.Logic.psm1'
if (-not (Test-Path $logic)) { $logic = Join-Path $PSScriptRoot '..\lib\OdooSetup.Logic.psm1' }
Import-Module $logic -DisableNameChecking
$paths = Get-InstallPaths -Root $Root
$settings = Get-Content -Raw $paths.Settings -Encoding UTF8 | ConvertFrom-Json
$services = @('OdooPostgreSQL', 'odoo')

function Show-Status {
    Write-Host ''
    Write-Host ('  Odoo {0} ({1})  database: {2}' -f $settings.OdooVersion, $settings.Mode, $settings.DbName) -ForegroundColor Cyan
    foreach ($name in $services) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        $state = 'not installed'; $color = 'Red'
        if ($svc) { $state = [string]$svc.Status; if ($svc.Status -eq 'Running') { $color = 'Green' } else { $color = 'Yellow' } }
        Write-Host ('  {0,-16}' -f $name) -NoNewline; Write-Host $state -ForegroundColor $color
    }
    Write-Host ('  URL             http://localhost:{0}' -f $settings.HttpPort)
    $last = Join-Path $paths.Logs 'last-backup.json'
    $status = $null
    if (Test-Path $last) { $status = Get-Content -Raw $last -Encoding UTF8 | ConvertFrom-Json }
    $lastOk = Get-SettingValue $status 'LastSuccess'
    if ($lastOk) { Write-Host ('  Last backup     {0}  ({1} MB)' -f $lastOk, (Get-SettingValue $status 'SizeMB')) }
    if ($settings.Backup.Enabled) {
        $health = Get-BackupHealth -Status $status `
            -CopyConfigured ([bool][string](Get-SettingValue $settings.Backup 'CopyDir' '')) `
            -TestRestoreDays ([int](Get-SettingValue $settings.Backup 'TestRestoreDays' 7))
        if ($health.Level -eq 'OK') { Write-Host '  Backups         healthy' -ForegroundColor Green }
        else {
            $color = $(if ($health.Level -eq 'Error') { 'Red' } else { 'Yellow' })
            foreach ($m in $health.Messages) { Write-Host ('  Backups         {0}' -f $m) -ForegroundColor $color }
        }
    }
    Write-Host ''
}

switch ($Command) {
    'status' { Show-Status }
    'start' { foreach ($s in $services) { Start-Service $s }; Show-Status }
    'stop' { Stop-Service 'odoo' -Force; Show-Status }
    'restart' { Restart-Service 'odoo' -Force; Show-Status }
    'logs' {
        $log = Get-ChildItem $paths.Logs -Filter 'odoo-service.err*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($log) { Get-Content $log.FullName -Tail 60 -Wait } else { Write-Host 'No service log yet.' }
    }
    'update' {
        if (-not $Modules) { throw 'Use -Modules name1,name2 or -Modules all' }
        Stop-Service 'odoo' -Force
        try {
            & $paths.VenvPython $paths.OdooBin -c $paths.OdooConf -d $settings.DbName -u $Modules --no-http --stop-after-init
            if ($LASTEXITCODE -ne 0) { throw ('Module update failed ({0})' -f $LASTEXITCODE) }
        }
        finally { Start-Service 'odoo' }
        Show-Status
    }
    'backup' { & (Join-Path $PSScriptRoot 'backup.ps1') -Root $Root }
    'test-restore' { & (Join-Path $PSScriptRoot 'backup.ps1') -Root $Root -TestRestore }
    'open' { Start-Process ('http://localhost:{0}/web' -f $settings.HttpPort) }
}
