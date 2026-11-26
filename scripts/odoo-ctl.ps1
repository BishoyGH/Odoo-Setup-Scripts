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
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('status', 'start', 'stop', 'restart', 'logs', 'update', 'backup', 'open')]
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
    if (Test-Path $last) {
        $b = Get-Content -Raw $last | ConvertFrom-Json
        Write-Host ('  Last backup     {0}  ({1} MB)' -f $b.LastSuccess, $b.SizeMB)
    }
    elseif ($settings.Backup.Enabled) { Write-Host '  Last backup     none yet' -ForegroundColor Yellow }
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
    'open' { Start-Process ('http://localhost:{0}/web' -f $settings.HttpPort) }
}
