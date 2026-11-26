<#
.SYNOPSIS
  Restarts Odoo when it stops answering. Run every 5 minutes by the
  "Odoo Health Check" scheduled task (production installs).

.DESCRIPTION
  One run checks http://127.0.0.1:<port>/web/login once:
    * answering            -> nothing to do
    * service stopped      -> start it (and PostgreSQL first if needed)
    * not answering twice  -> restart the service
  It waits while the service is starting or was started less than 5 minutes
  ago, does nothing while setup/restore/"odoo-ctl stop" has paused it
  (logs\health-check.pause, ignored after 6 hours), and stops restarting after
  3 restarts in one hour so a broken install does not restart forever.
  Every action is written to logs\health-check.log.
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\Odoo',
    [int]$Threshold = 2
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$logic = Join-Path $PSScriptRoot 'OdooSetup.Logic.psm1'
if (-not (Test-Path $logic)) { $logic = Join-Path $PSScriptRoot '..\lib\OdooSetup.Logic.psm1' }
Import-Module $logic -DisableNameChecking

$paths = Get-InstallPaths -Root $Root
$logFile = Join-Path $paths.Logs 'health-check.log'
$stateFile = Join-Path $paths.Logs 'health-check.json'
$pauseFile = Join-Path $paths.Logs 'health-check.pause'
$odooService = 'odoo'
$pgService = 'OdooPostgreSQL'

function Write-HealthLog {
    param([string]$Message, [string]$Level = 'INFO')
    if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) { Move-Item $logFile ($logFile + '.old') -Force }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Test-Http {
    param([int]$Port, [int]$TimeoutSeconds = 20)
    try {
        $r = Invoke-WebRequest -Uri ('http://127.0.0.1:{0}/web/login' -f $Port) -UseBasicParsing -TimeoutSec $TimeoutSeconds
        return ($r.StatusCode -eq 200)
    }
    catch { return $false }
}

function Wait-Http {
    param([int]$Port, [int]$TimeoutSeconds = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Http -Port $Port -TimeoutSeconds 15) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Get-ServiceUptimeMinutes {
    param([string]$Name)
    try {
        $svc = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $Name)
        if ($svc -and $svc.ProcessId) {
            $p = Get-Process -Id $svc.ProcessId -ErrorAction Stop
            return ((Get-Date) - $p.StartTime).TotalMinutes
        }
    }
    catch { Write-Verbose $_ }
    return 999
}

function Start-OdooServices {
    param([switch]$Restart)
    $pg = Get-Service -Name $pgService -ErrorAction SilentlyContinue
    if ($pg -and $pg.Status -ne 'Running') {
        Write-HealthLog ('PostgreSQL service was {0}; starting it.' -f $pg.Status) 'WARN'
        Start-Service -Name $pgService
        $pg.WaitForStatus('Running', [TimeSpan]::FromSeconds(90))
    }
    if ($Restart) { Restart-Service -Name $odooService -Force } else { Start-Service -Name $odooService }
}

try {
    New-Item -ItemType Directory -Path $paths.Logs -Force | Out-Null
    $settings = Get-Content -Raw $paths.Settings -Encoding UTF8 | ConvertFrom-Json
    $port = [int]$settings.HttpPort

    $state = @{ Failures = 0; Restarts = @() }
    if (Test-Path $stateFile) {
        try {
            $saved = Get-Content -Raw $stateFile | ConvertFrom-Json
            $state.Failures = [int]$saved.Failures
            $state.Restarts = @($saved.Restarts | Where-Object { $_ })
        }
        catch { Write-Verbose 'Unreadable state file; starting fresh.' }
    }
    $now = Get-Date
    $recent = @($state.Restarts | Where-Object { ($now - [datetime]$_).TotalMinutes -lt 60 })

    $paused = $false
    if (Test-Path $pauseFile) {
        if (($now - (Get-Item $pauseFile).LastWriteTime).TotalHours -lt 6) { $paused = $true }
        else { Remove-Item $pauseFile -Force -ErrorAction SilentlyContinue; Write-HealthLog 'Removed a pause older than 6 hours.' 'WARN' }
    }

    $svc = Get-Service -Name $odooService -ErrorAction SilentlyContinue
    $status = ''
    if ($svc) { $status = [string]$svc.Status }
    $httpOk = $false
    if (-not $paused -and $status -eq 'Running') { $httpOk = Test-Http -Port $port }

    $action = Get-HealthCheckAction -ServiceStatus $status -HttpOk $httpOk -PreviousFailures $state.Failures -Paused $paused `
        -ServiceUptimeMinutes (Get-ServiceUptimeMinutes $odooService) -RestartsLastHour $recent.Count -Threshold $Threshold

    switch ($action) {
        'ok' {
            if ($state.Failures -gt 0) { Write-HealthLog 'Odoo is answering again.' 'OK' }
            $state.Failures = 0
        }
        'wait' {
            if ($status -eq 'Running' -and -not $httpOk) {
                $state.Failures++
                Write-HealthLog ('Odoo did not answer on port {0} (check {1} of {2}).' -f $port, $state.Failures, $Threshold) 'WARN'
            }
        }
        'start' {
            Write-HealthLog 'Odoo service was stopped; starting it.' 'WARN'
            Start-OdooServices
            $recent += $now.ToString('o')
            $state.Failures = 0
            if (Wait-Http -Port $port) { Write-HealthLog 'Odoo started and is answering.' 'OK' }
            else { Write-HealthLog ('Odoo started but is not answering yet. See {0}\odoo-service.err.log' -f $paths.Logs) 'ERROR' }
        }
        'restart' {
            Write-HealthLog ('Odoo stopped answering on port {0}; restarting the service.' -f $port) 'WARN'
            Start-OdooServices -Restart
            $recent += $now.ToString('o')
            $state.Failures = 0
            if (Wait-Http -Port $port) { Write-HealthLog 'Odoo restarted and is answering.' 'OK' }
            else { Write-HealthLog ('Odoo restarted but is not answering yet. See {0}\odoo-service.err.log' -f $paths.Logs) 'ERROR' }
        }
        'backoff' {
            Write-HealthLog ('Odoo is down but was restarted {0} times in the last hour; not restarting again. Run setup and choose Repair.' -f $recent.Count) 'ERROR'
        }
        'missing' { Write-HealthLog 'The Odoo service is not installed; nothing to check.' 'WARN' }
        'paused' { Write-Verbose 'Paused.' }
    }

    $state.Restarts = $recent
    @{ Failures = $state.Failures; Restarts = @($recent); LastCheck = $now.ToString('o'); LastResult = $action } |
        ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
}
catch {
    Write-HealthLog $_.Exception.Message 'ERROR'
    exit 1
}
