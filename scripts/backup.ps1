<#
.SYNOPSIS
  Backs up the Odoo database and filestore to a ZIP that Odoo's own
  database manager can restore (dump.sql + filestore/ + manifest.json).

.DESCRIPTION
  Run daily by the "Odoo Daily Backup" scheduled task, or by hand:
    powershell -ExecutionPolicy Bypass -File C:\Odoo\tools\backup.ps1
  Settings (backup folder, second copy, retention, test-restore interval) are
  read from conf\settings.json.

  After a good backup it
    * copies the ZIP to the second folder (USB drive or another partition)
      when one is configured, and checks the copy byte for byte;
    * once a week restores the new ZIP into a throwaway database and checks
      it (-TestRestore forces this now, -SkipTestRestore skips it).
  Results go to logs\last-backup.json. When anything fails, an entry is
  written to the Windows Application log and the "Odoo Backup Check" task
  shows a warning on the desktop.

  Exit codes: 0 all good, 1 backup failed, 2 backup good but the second copy
  or the test-restore failed.
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\Odoo',
    [string]$Database = '',
    [string]$Destination = '',
    [switch]$TestRestore,
    [switch]$SkipTestRestore
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
    if ($Level -eq 'ERROR') { $color = 'Red' } elseif ($Level -eq 'WARN') { $color = 'Yellow' } elseif ($Level -eq 'OK') { $color = 'Green' }
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

function Read-BackupStatus {
    <# Previous results, so a failed run keeps the date of the last good one. #>
    param([string]$Path)
    $status = [ordered]@{
        LastSuccess = $null; File = $null; SizeMB = $null; LastAttempt = $null; LastError = $null; LastErrorAt = $null
        Copy = [ordered]@{ Dir = $null; File = $null; LastSuccess = $null; LastError = $null; LastErrorAt = $null }
        TestRestore = [ordered]@{ LastRun = $null; Ok = $false; Message = $null; Warning = $null; File = $null }
        # Copy of the relevant settings: the desktop check runs as the signed-in
        # user, who cannot read conf\settings.json.
        Config = [ordered]@{ CopyDir = $null; TestRestoreDays = 7 }
    }
    if (-not (Test-Path $Path)) { return $status }
    try { $old = Get-Content -Raw $Path -Encoding UTF8 | ConvertFrom-Json } catch { return $status }
    foreach ($k in @('LastSuccess', 'File', 'SizeMB', 'LastAttempt', 'LastError', 'LastErrorAt')) { $status[$k] = Get-SettingValue $old $k }
    foreach ($section in @('Copy', 'TestRestore', 'Config')) {
        $o = Get-SettingValue $old $section
        foreach ($k in @($status[$section].Keys)) { $status[$section][$k] = Get-SettingValue $o $k $status[$section][$k] }
    }
    return $status
}

function Save-BackupStatus {
    param([string]$Path, $Status)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, ($Status | ConvertTo-Json -Depth 4), $enc)
}

function Send-BackupAlert {
    <#
      Application event log entry (works on every Windows edition) and, when
      running as the scheduled task (SYSTEM), starts the "Odoo Backup Check"
      task, which runs in the signed-in user's session and shows the warning.
    #>
    param([string]$Message)
    try {
        $text = $Message
        if ($text.Length -gt 900) { $text = $text.Substring(0, 900) }
        & eventcreate.exe /L APPLICATION /T ERROR /SO OdooBackup /ID 100 /D ('Odoo backup: ' + $text) 2>&1 | Out-Null
    }
    catch { Write-Verbose $_ }
    try {
        $isSystem = ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
        if ($isSystem -and (Get-ScheduledTask -TaskName 'Odoo Backup Check' -ErrorAction SilentlyContinue)) {
            Start-ScheduledTask -TaskName 'Odoo Backup Check'
        }
    }
    catch { Write-Verbose $_ }
}

function Invoke-PgTool {
    <# Runs a PostgreSQL tool; stderr goes to ErrLog instead of stopping the script. #>
    param([string]$Exe, [string[]]$Arguments, [string]$ErrLog = '')
    $ErrorActionPreference = 'Continue'
    $all = @(& $Exe @Arguments 2>&1)
    $code = $LASTEXITCODE
    $stdout = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
    $stderr = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
    if ($ErrLog -and $stderr.Count -gt 0) { Add-Content -Path $ErrLog -Value $stderr -Encoding UTF8 }
    return [pscustomobject]@{ Code = $code; Output = $stdout }
}

function Copy-BackupToSecondFolder {
    <# Copies the ZIP, verifies it by SHA-256, then applies the same retention. #>
    param([string]$ZipPath, [string]$CopyRoot, [string]$DbName, [int]$RetentionDays, [datetime]$Now)
    $drive = Split-Path $CopyRoot -Qualifier
    if (-not (Test-Path ($drive + '\'))) { throw ('Drive {0} is not connected. Plug in the backup drive.' -f $drive) }
    $dir = Join-Path $CopyRoot $DbName
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Get-ChildItem $dir -Filter '*.partial' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $name = Split-Path $ZipPath -Leaf
    $partial = Join-Path $dir ($name + '.partial')
    $final = Join-Path $dir $name
    Copy-Item -LiteralPath $ZipPath -Destination $partial -Force
    $a = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash
    $b = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash
    if ($a -ne $b) { Remove-Item $partial -Force -ErrorAction SilentlyContinue; throw 'The copy does not match the original (checksum differs).' }
    Move-Item -LiteralPath $partial -Destination $final -Force
    $old = Select-BackupsToPrune -Files @(Get-ChildItem $dir -Filter '*.zip') -RetentionDays $RetentionDays -KeepMinimum 3 -Now $Now
    foreach ($f in $old) { Remove-Item $f.FullName -Force; Write-BackupLog ('Removed old copy {0}' -f $f.Name) }
    return $final
}

function Invoke-BackupTestRestore {
    <#
      Restores the ZIP into a throwaway database with the odoo role, checks
      it, then drops it. Odoo never serves this database in production
      (dbfilter), and its scheduled jobs and mail servers are switched off
      right after loading as a second guard. Returns a warning string (empty
      when everything matched) or throws on failure.
    #>
    param([string]$ZipPath, [string]$DbName, [string]$WorkRoot, [string[]]$PgArgs, [string]$PgBin, [string]$LogDir)
    $testDb = Get-TestRestoreDbName -DbName $DbName
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $work = Join-Path $WorkRoot ('_restoretest_' + $id)
    $sqlFile = Join-Path $WorkRoot ('_restoretest_' + $id + '.sql')
    $psql = Join-Path $PgBin 'psql.exe'
    $errLog = Join-Path $LogDir 'restore-test-psql.log'
    Set-Content -Path $errLog -Value ('Test-restore of {0} at {1}' -f $ZipPath, (Get-Date -Format s)) -Encoding UTF8
    # SQL with quoted identifiers goes through a file: Windows PowerShell 5.1
    # drops embedded double quotes from native command arguments.
    $runSql = {
        param([string]$Db, [string]$Sql)
        [IO.File]::WriteAllText($sqlFile, $Sql, (New-Object System.Text.UTF8Encoding($false)))
        return (Invoke-PgTool $psql ($PgArgs + @('-d', $Db, '-q', '-v', 'ON_ERROR_STOP=1', '-f', $sqlFile)) $errLog)
    }
    $dropSql = 'DROP DATABASE IF EXISTS "{0}" WITH (FORCE);' -f $testDb
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
        & $tar -x -f $ZipPath -C $work
        if ($LASTEXITCODE -ne 0) { throw 'The ZIP could not be extracted.' }
        $dump = Join-Path $work 'dump.sql'
        if (-not (Test-Path $dump)) { throw 'dump.sql is missing from the ZIP.' }
        $manifest = Get-Content -Raw (Join-Path $work 'manifest.json') -Encoding UTF8 | ConvertFrom-Json

        if ((& $runSql 'postgres' $dropSql).Code -ne 0) { throw ('Could not remove an old test database (see {0}).' -f $errLog) }
        $create = "CREATE DATABASE `"{0}`" OWNER odoo ENCODING 'UTF8' TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C';" -f $testDb
        if ((& $runSql 'postgres' $create).Code -ne 0) { throw ('Could not create the test database (see {0}).' -f $errLog) }

        # Same as Odoo's restore: no ON_ERROR_STOP (harmless statements fail for a non-superuser).
        $r = Invoke-PgTool $psql ($PgArgs + @('-d', $testDb, '-q', '-f', $dump)) $errLog
        if ($r.Code -ne 0) { throw ('Loading dump.sql failed (see {0}).' -f $errLog) }
        & $runSql $testDb 'UPDATE ir_cron SET active = false;' | Out-Null
        & $runSql $testDb 'UPDATE ir_mail_server SET active = false;' | Out-Null

        $q = {
            param([string]$Sql)
            $res = Invoke-PgTool $psql ($PgArgs + @('-d', $testDb, '-v', 'ON_ERROR_STOP=1', '-tA', '-c', $Sql)) $errLog
            if ($res.Code -ne 0) { throw ('Check query failed: {0} (see {1})' -f $Sql, $errLog) }
            return (($res.Output | Out-String).Trim())
        }
        if ((& $q "SELECT state FROM ir_module_module WHERE name = 'base'") -ne 'installed') { throw 'The restored database is incomplete (base module not installed).' }
        if ([int](& $q 'SELECT count(*) FROM res_company') -lt 1) { throw 'The restored database has no company.' }
        if ([int](& $q 'SELECT count(*) FROM res_users WHERE active') -lt 1) { throw 'The restored database has no active users.' }
        $expected = @($manifest.modules.PSObject.Properties).Count
        $installed = [int](& $q "SELECT count(*) FROM ir_module_module WHERE state = 'installed'")
        if ($expected -gt 0 -and $installed -ne $expected) {
            throw ('The restored database has {0} installed modules; the backup manifest lists {1}.' -f $installed, $expected)
        }

        # Attachments: every file the database points to must be in the ZIP.
        $fnames = Invoke-PgTool $psql ($PgArgs + @('-d', $testDb, '-tA', '-c', 'SELECT DISTINCT store_fname FROM ir_attachment WHERE store_fname IS NOT NULL')) $errLog
        $fsDir = Join-Path $work 'filestore'
        $missing = 0; $total = 0
        foreach ($f in $fnames.Output) {
            $f = $f.Trim()
            if (-not $f) { continue }
            $total++
            if (-not (Test-Path -LiteralPath (Join-Path $fsDir ($f -replace '/', '\')))) { $missing++ }
        }
        Write-BackupLog ('Test-restore checks passed: {0} modules, {1} attachment files ({2} missing)' -f $installed, $total, $missing)
        if ($missing -gt 0) {
            return ('{0} of {1} attachment files referenced by the database are not in the backup.' -f $missing, $total)
        }
        return ''
    }
    finally {
        & $runSql 'postgres' $dropSql | Out-Null
        Remove-Item $sqlFile -Force -ErrorAction SilentlyContinue
        if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$statusPath = Join-Path $paths.Logs 'last-backup.json'
$status = Read-BackupStatus -Path $statusPath
$status.LastAttempt = (Get-Date).ToString('s')
$staging = $null
$zipPath = $null
$settings = $null
try {
    $settings = Get-Content -Raw $paths.Settings -Encoding UTF8 | ConvertFrom-Json
    $conf = Read-OdooConf $paths.OdooConf
    if (-not $Database) { $Database = $settings.DbName }
    if (-not $Destination) { $Destination = $settings.Backup.Dir }
    $status.Config.CopyDir = [string](Get-SettingValue $settings.Backup 'CopyDir' '')
    $status.Config.TestRestoreDays = [int](Get-SettingValue $settings.Backup 'TestRestoreDays' 7)
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

    $status.LastSuccess = $now.ToString('s'); $status.File = $zipPath; $status.SizeMB = $sizeMb
    Save-BackupStatus -Path $statusPath -Status $status
}
catch {
    Write-BackupLog $_.Exception.Message 'ERROR'
    $status.LastError = $_.Exception.Message; $status.LastErrorAt = (Get-Date).ToString('s')
    Save-BackupStatus -Path $statusPath -Status $status
    Send-BackupAlert ('Backup FAILED: ' + $_.Exception.Message)
    exit 1   # the finally block below still runs
}
finally {
    $env:PGPASSWORD = $null
    if ($staging -and (Test-Path $staging)) { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- After a good backup: second copy, then the weekly test-restore. ----
$problems = @()

$copyDir = $status.Config.CopyDir
$status.Copy.Dir = $(if ($copyDir) { $copyDir } else { $null })
if ($copyDir) {
    try {
        Write-BackupLog ('Copying to second folder {0}' -f $copyDir)
        $status.Copy.File = Copy-BackupToSecondFolder -ZipPath $zipPath -CopyRoot $copyDir -DbName $Database -RetentionDays $retention -Now $now
        $status.Copy.LastSuccess = (Get-Date).ToString('s')
        Write-BackupLog ('Second copy OK: {0}' -f $status.Copy.File) 'OK'
    }
    catch {
        $status.Copy.LastError = $_.Exception.Message; $status.Copy.LastErrorAt = (Get-Date).ToString('s')
        Write-BackupLog ('Second copy FAILED: {0}' -f $_.Exception.Message) 'WARN'
        $problems += ('Second copy failed: ' + $_.Exception.Message)
    }
    Save-BackupStatus -Path $statusPath -Status $status
}

$testDays = $status.Config.TestRestoreDays
$autoTest = [bool](Get-SettingValue $settings.Backup 'Enabled' $false)
$due = $autoTest -and (Test-TestRestoreDue -LastRun $status.TestRestore.LastRun -LastRunOk ([bool]$status.TestRestore.Ok) -IntervalDays $testDays -Now $now)
if ($TestRestore -or ($due -and -not $SkipTestRestore)) {
    Write-BackupLog ('Test-restore of {0} into "{1}"' -f (Split-Path $zipPath -Leaf), (Get-TestRestoreDbName -DbName $Database))
    $status.TestRestore.LastRun = (Get-Date).ToString('s'); $status.TestRestore.File = $zipPath
    $env:PGPASSWORD = $conf['db_password']
    try {
        $warning = Invoke-BackupTestRestore -ZipPath $zipPath -DbName $Database -WorkRoot $Destination -PgArgs $pgArgs -PgBin $paths.PgBin -LogDir $paths.Logs
        $status.TestRestore.Ok = $true; $status.TestRestore.Message = 'Restored and checked'
        $status.TestRestore.Warning = $(if ($warning) { $warning } else { $null })
        if ($warning) { Write-BackupLog ('Test-restore OK with a warning: {0}' -f $warning) 'WARN' }
        else { Write-BackupLog 'Test-restore OK' 'OK' }
    }
    catch {
        $status.TestRestore.Ok = $false; $status.TestRestore.Message = $_.Exception.Message; $status.TestRestore.Warning = $null
        Write-BackupLog ('Test-restore FAILED: {0}' -f $_.Exception.Message) 'ERROR'
        $problems += ('Test-restore failed: ' + $_.Exception.Message)
    }
    finally { $env:PGPASSWORD = $null }
    Save-BackupStatus -Path $statusPath -Status $status
}

if ($problems.Count -gt 0) {
    Send-BackupAlert ('Backup OK, but: ' + ($problems -join ' '))
    exit 2
}
exit 0
