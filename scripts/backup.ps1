<#
.SYNOPSIS
  Backs up the Odoo database and filestore to a ZIP that Odoo's own
  database manager can restore (dump.sql + filestore/ + manifest.json).

.DESCRIPTION
  Run daily by the "Odoo Daily Backup" scheduled task, or by hand:
    powershell -ExecutionPolicy Bypass -File C:\Odoo\tools\backup.ps1
  Settings (backup folder, retention) are read from conf\settings.json.
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\Odoo',
    [string]$Database = '',
    [string]$Destination = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$logic = Join-Path $PSScriptRoot 'OdooSetup.Logic.psm1'
if (-not (Test-Path $logic)) { $logic = Join-Path $PSScriptRoot '..\lib\OdooSetup.Logic.psm1' }
Import-Module $logic -DisableNameChecking

$paths = Get-InstallPaths -Root $Root
$logFile = Join-Path $paths.Logs 'backup.log'
New-Item -ItemType Directory -Path $paths.Logs -Force | Out-Null

function Write-BackupLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    $color = 'Gray'
    if ($Level -eq 'ERROR') { $color = 'Red' } elseif ($Level -eq 'OK') { $color = 'Green' }
    Write-Host $line -ForegroundColor $color
}

function Read-OdooConf {
    param([string]$Path)
    $conf = @{}
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$') { $conf[$Matches[1]] = $Matches[2] }
    }
    return $conf
}

$staging = $null
try {
    $settings = Get-Content -Raw $paths.Settings -Encoding UTF8 | ConvertFrom-Json
    $conf = Read-OdooConf $paths.OdooConf
    if (-not $Database) { $Database = $settings.DbName }
    if (-not $Destination) { $Destination = $settings.Backup.Dir }
    if (-not $Destination) { throw 'No backup folder configured. Run setup and enable backups.' }
    $retention = 14
    if ($settings.Backup.RetentionDays) { $retention = [int]$settings.Backup.RetentionDays }

    $dbDir = Join-Path $Destination $Database
    New-Item -ItemType Directory -Path $dbDir -Force | Out-Null
    $now = Get-Date
    $zipName = Get-BackupFileName -DbName $Database -Timestamp $now
    $zipPath = Join-Path $dbDir $zipName
    $staging = Join-Path $Destination ('_staging_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    Write-BackupLog ('Backing up "{0}" to {1}' -f $Database, $zipPath)
    $env:PGPASSWORD = $conf['db_password']
    $pgArgs = @('-h', '127.0.0.1', '-p', $conf['db_port'], '-U', $conf['db_user'])

    # 1. Database (plain SQL, same as Odoo's own backups)
    & (Join-Path $paths.PgBin 'pg_dump.exe') @pgArgs '--no-owner' '--format=p' '--file' (Join-Path $staging 'dump.sql') $Database
    if ($LASTEXITCODE -ne 0) { throw ('pg_dump failed with exit code {0}' -f $LASTEXITCODE) }

    # 2. Filestore (attachments)
    $filestore = Join-Path $paths.Data ('filestore\' + $Database)
    if (Test-Path $filestore) {
        & robocopy.exe $filestore (Join-Path $staging 'filestore') /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw ('Copying the filestore failed (robocopy {0})' -f $LASTEXITCODE) }
    }

    # 3. Manifest (Odoo format)
    $psql = Join-Path $paths.PgBin 'psql.exe'
    $modulesCsv = & $psql @pgArgs -d $Database -tA -F '|' -c "SELECT name, latest_version FROM ir_module_module WHERE state = 'installed'"
    $modules = [ordered]@{}
    foreach ($row in $modulesCsv) { if ($row -match '^(.*?)\|(.*)$') { $modules[$Matches[1]] = $Matches[2] } }
    $pgVersion = (& $psql @pgArgs -d $Database -tAc 'SHOW server_version').Trim()
    $major = $settings.OdooVersion
    $manifest = [ordered]@{
        odoo_dump = '1'; db_name = $Database; version = $major; major_version = $major
        version_info = @([int]$major.Split('.')[0], [int]$major.Split('.')[1], 0, 'final', 0, '')
        pg_version = $pgVersion; modules = $modules
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $staging 'manifest.json'), ($manifest | ConvertTo-Json -Depth 4), $enc)

    # 4. Zip with the built-in tar.exe (supports large files) and verify
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    $items = @('dump.sql', 'manifest.json')
    if (Test-Path (Join-Path $staging 'filestore')) { $items += 'filestore' }
    & $tar -a -c -f $zipPath -C $staging @items
    if ($LASTEXITCODE -ne 0) { throw 'Creating the ZIP failed' }
    $listing = & $tar -t -f $zipPath
    if (-not ($listing -contains 'dump.sql')) { throw 'Backup verification failed: dump.sql missing from ZIP' }

    $sizeMb = [Math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    Write-BackupLog ('Backup OK: {0} ({1} MB)' -f $zipName, $sizeMb) 'OK'

    # 5. Retention
    $old = Select-BackupsToPrune -Files @(Get-ChildItem $dbDir -Filter '*.zip') -RetentionDays $retention -KeepMinimum 3 -Now $now
    foreach ($f in $old) { Remove-Item $f.FullName -Force; Write-BackupLog ('Removed old backup {0}' -f $f.Name) }

    $status = [ordered]@{ LastSuccess = $now.ToString('s'); File = $zipPath; SizeMB = $sizeMb }
    [IO.File]::WriteAllText((Join-Path $paths.Logs 'last-backup.json'), ($status | ConvertTo-Json), $enc)
    exit 0
}
catch {
    Write-BackupLog $_.Exception.Message 'ERROR'
    exit 1
}
finally {
    $env:PGPASSWORD = $null
    if ($staging -and (Test-Path $staging)) { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue }
}
