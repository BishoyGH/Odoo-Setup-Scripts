# Status, restore and uninstall.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'OdooSetup.Steps.psm1') -Global -DisableNameChecking

function Show-OdooStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths, [System.Collections.IDictionary]$Settings)
    Write-Section 'Status'
    if (-not $Settings) { Write-Warn ('No installation found in {0}' -f $Paths.Root); return }
    Write-KeyValue 'Odoo version' $Settings.OdooVersion
    Write-KeyValue 'Mode' $Settings.Mode
    Write-KeyValue 'Database' $Settings.DbName
    Write-KeyValue 'RAM profile' $Settings.RamProfile
    foreach ($name in @((Get-PgServiceName), (Get-OdooServiceName))) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        $state = 'not installed'
        if ($svc) { $state = ('{0} ({1})' -f $svc.Status, $svc.StartType) }
        Write-KeyValue ('Service ' + $name) $state
    }
    $url = 'http://localhost:{0}' -f $Settings.HttpPort
    $ok = Test-OdooHttp -Port $Settings.HttpPort -TimeoutSeconds 5
    Write-KeyValue 'Web' ('{0}  {1}' -f $url, $(if ($ok) { '(responding)' } else { '(not responding)' }))
    if ($Settings.Backup -and $Settings.Backup.Enabled) {
        Write-KeyValue 'Backups' ('{0} daily at {1}, keep {2} days' -f $Settings.Backup.Dir, $Settings.Backup.Time, $Settings.Backup.RetentionDays)
        $last = Join-Path $Paths.Logs 'last-backup.json'
        if (Test-Path $last) {
            $b = Get-Content -Raw $last | ConvertFrom-Json
            Write-KeyValue 'Last backup' ('{0} ({1} MB)' -f $b.LastSuccess, $b.SizeMB)
        }
        else { Write-KeyValue 'Last backup' 'none yet' }
        $drive = Split-Path $Settings.Backup.Dir -Qualifier
        $d = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive) -ErrorAction SilentlyContinue
        if ($d) { Write-KeyValue ('Free on ' + $drive) ('{0} GB' -f [Math]::Round($d.FreeSpace / 1GB, 1)) }
    }
    else { Write-KeyValue 'Backups' 'disabled' }
    $health = 'off'
    if (Get-ScheduledTask -TaskName (Get-HealthTaskName) -ErrorAction SilentlyContinue) {
        $health = 'every 5 minutes'
        $hs = Join-Path $Paths.Logs 'health-check.json'
        if (Test-Path $hs) {
            $h = Get-Content -Raw $hs | ConvertFrom-Json
            $health += (', last result "{0}"' -f $h.LastResult)
            $n = @($h.Restarts | Where-Object { $_ }).Count
            if ($n -gt 0) { $health += (', {0} restart(s) in the last hour' -f $n) }
        }
    }
    Write-KeyValue 'Health check' $health
}

function Select-BackupFolder {
    <# Interactive drive picker; recommends a non-system drive. #>
    [CmdletBinding()]
    param([string]$Default = '')
    $drives = Get-FixedDrives
    if ($drives.Count -eq 0) { throw 'No fixed drives found.' }
    $labels = foreach ($d in $drives) {
        $tag = ''
        if ($d.IsSystem) { $tag = '  (Windows drive - not recommended)' }
        '{0}  {1,-14} {2,7} GB free of {3} GB{4}' -f $d.Letter, ('"' + $d.Label + '"'), $d.FreeGB, $d.SizeGB, $tag
    }
    if (@($drives | Where-Object { -not $_.IsSystem }).Count -eq 0) {
        Write-Warn 'Only the Windows drive is available. Backups on the same disk do not survive a disk failure;'
        Write-Warn 'consider adding a second disk or copying backups to a USB drive regularly.'
    }
    $i = Read-Choice -Prompt 'Which partition should store database backups?' -Options $labels -DefaultIndex 0
    $suggested = $drives[$i].Letter + '\OdooBackups'
    if ($Default -and ($Default.StartsWith($drives[$i].Letter))) { $suggested = $Default }
    return (Read-Value -Prompt 'Backup folder' -Default $suggested -Validate { param($v) $v -match '^[A-Za-z]:\\' })
}

function Invoke-OdooRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Secrets,
        [string]$ZipPath = '',
        [string]$TargetDb = ''
    )
    Write-Section 'Restore from backup'
    if (-not $ZipPath) {
        $folder = ''
        if ($Settings.Backup -and $Settings.Backup.Dir) { $folder = $Settings.Backup.Dir }
        $folder = Read-Value -Prompt 'Folder that contains the backup ZIP files' -Default $folder -Validate { param($v) Test-Path $v }
        $zips = @(Get-ChildItem $folder -Filter '*.zip' -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 15)
        if ($zips.Count -eq 0) { throw ('No backup ZIP files in {0}' -f $folder) }
        $labels = $zips | ForEach-Object { '{0}  ({1:N1} MB, {2})' -f $_.Name, ($_.Length / 1MB), $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
        $ZipPath = $zips[(Read-Choice -Prompt 'Choose a backup (newest first)' -Options $labels)].FullName
    }
    if (-not $TargetDb) {
        $TargetDb = Read-Value -Prompt 'Restore into database' -Default $Settings.DbName -Validate { param($v) Test-DatabaseName $v }
    }
    $exists = Test-DatabaseExists -Paths $Paths -Port $Settings.PgPort -Password $Secrets.OdooDbPassword -DbName $TargetDb
    if ($exists) {
        Write-Warn ('Database "{0}" exists and will be REPLACED by the backup.' -f $TargetDb)
        $confirm = Read-Value -Prompt ('Type the database name ({0}) to confirm' -f $TargetDb)
        if ($confirm -ne $TargetDb) { Write-Warn 'Cancelled.'; return }
    }

    $tmp = Join-Path $Paths.Root ('_restore_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $odooSvc = Get-OdooServiceName
    Suspend-HealthCheck -Paths $Paths -Reason 'restore'
    try {
        Write-Info 'Extracting backup...'
        Expand-Zip -Path $ZipPath -Destination $tmp
        $dump = Join-Path $tmp 'dump.sql'
        if (-not (Test-Path $dump)) { throw 'dump.sql not found in the backup ZIP.' }

        Write-Info 'Stopping Odoo...'
        Stop-ServiceSafe -Name $odooSvc
        if ($exists) {
            Remove-OdooDatabase -Paths $Paths -Port $Settings.PgPort -SuperPassword $Secrets.PgSuperPassword -DbName $TargetDb
        }
        Invoke-Psql -Paths $Paths -Port $Settings.PgPort -User 'odoo' -Password $Secrets.OdooDbPassword `
            -Sql ("CREATE DATABASE `"{0}`" OWNER odoo ENCODING 'UTF8' TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C'" -f $TargetDb) | Out-Null

        Write-Info 'Loading database (this can take a while)...'
        $env:PGPASSWORD = $Secrets.OdooDbPassword
        try {
            # Same as Odoo's own restore: no ON_ERROR_STOP, because harmless statements such as
            # COMMENT ON EXTENSION fail for a non-superuser. Success is checked below instead.
            Invoke-Native -FilePath (Join-Path $Paths.PgBin 'psql.exe') -ArgumentList @(
                '-h', '127.0.0.1', '-p', $Settings.PgPort, '-U', 'odoo', '-d', $TargetDb, '-q', '-f', ('"{0}"' -f $dump)
            ) -LogFile (Join-Path $Paths.Logs 'restore-psql.log') | Out-Null
        }
        finally { $env:PGPASSWORD = $null }
        $base = Invoke-Psql -Paths $Paths -Port $Settings.PgPort -User 'odoo' -Password $Secrets.OdooDbPassword -Database $TargetDb `
            -Sql "SELECT state FROM ir_module_module WHERE name = 'base'"
        if ($base -ne 'installed') { throw ('The restored database looks incomplete. See {0}' -f (Join-Path $Paths.Logs 'restore-psql.log.err')) }

        $fsTarget = Join-Path $Paths.Data ('filestore\' + $TargetDb)
        $fsSource = Join-Path $tmp 'filestore'
        if (Test-Path $fsTarget) { Remove-Item $fsTarget -Recurse -Force }
        if (Test-Path $fsSource) {
            Write-Info 'Restoring attachments...'
            New-Item -ItemType Directory -Path (Split-Path $fsTarget -Parent) -Force | Out-Null
            & robocopy.exe $fsSource $fsTarget /E /MOVE /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { throw 'Copying attachments failed.' }
            Grant-FolderAccess -Path $fsTarget -Sid $SidNetworkService -Rights 'M'
        }
        Write-Ok ('Restored {0} into "{1}"' -f (Split-Path $ZipPath -Leaf), $TargetDb)
    }
    finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        if (Get-Service -Name $odooSvc -ErrorAction SilentlyContinue) {
            Start-ServiceSafe -Name $odooSvc
        }
        Resume-HealthCheck -Paths $Paths
    }
    return $TargetDb
}

function Invoke-OdooUninstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths)
    Write-Section 'Uninstall'
    Write-Host '   This removes the Odoo and PostgreSQL services, firewall rule, backup task and shortcut.' -ForegroundColor Gray
    Write-Host '   Your backups are never deleted.' -ForegroundColor Gray
    if (-not (Read-YesNo -Prompt 'Continue with uninstall?' -Default $false)) { return }

    $exe = Join-Path $Paths.Tools 'odoo-service.exe'
    if (Get-Service -Name (Get-OdooServiceName) -ErrorAction SilentlyContinue) {
        Stop-ServiceSafe -Name (Get-OdooServiceName)
        if (Test-Path $exe) { & $exe uninstall | Out-Null } else { & sc.exe delete (Get-OdooServiceName) | Out-Null }
        Write-Ok 'Odoo service removed'
    }
    if (Get-Service -Name (Get-PgServiceName) -ErrorAction SilentlyContinue) {
        Stop-ServiceSafe -Name (Get-PgServiceName)
        & (Join-Path $Paths.PgBin 'pg_ctl.exe') unregister -N (Get-PgServiceName) | Out-Null
        Write-Ok 'PostgreSQL service removed'
    }
    Unregister-BackupTask; Write-Ok 'Backup task removed'
    Unregister-HealthCheckTask; Write-Ok 'Health check task removed'
    Remove-WindowsUpdateActiveHours
    Remove-OdooFirewallRule; Write-Ok 'Firewall rule removed'
    Remove-OdooShortcut
    if (Set-DefenderExclusions -Paths $Paths -Remove) { Write-Ok 'Defender exclusions removed' }

    $deleteData = $false
    Write-Warn ('Your databases and attachments are in {0} and {1}.' -f $Paths.PgData, $Paths.Data)
    $answer = Read-Value -Prompt 'Type DELETE to erase them permanently, or press Enter to keep them' -Default ''
    if ($answer -ceq 'DELETE') { $deleteData = $true }

    if (Read-YesNo -Prompt ('Remove program files (Python, PostgreSQL, Odoo source) from {0}?' -f $Paths.Root) -Default $true) {
        $pyInstaller = Get-ChildItem $Paths.Downloads -Filter 'python-*-amd64.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pyInstaller) {
            Write-Info 'Uninstalling private Python...'
            try { Invoke-Native -FilePath $pyInstaller.FullName -ArgumentList @('/uninstall', '/quiet') -SuccessCodes @(0, 3010, 1605) | Out-Null }
            catch { Write-Warn 'Python uninstaller reported an error; removing files directly.' }
        }
        foreach ($d in @($Paths.Venv, $Paths.Python, $Paths.PgHome, $Paths.Wkhtml, $Paths.Src, $Paths.Tools, $Paths.Downloads, (Join-Path $Paths.Root 'addons\oca'))) {
            if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Remove-Item $Paths.State -Force -ErrorAction SilentlyContinue
        Write-Ok 'Program files removed'
    }
    if ($deleteData) {
        foreach ($d in @($Paths.PgData, $Paths.Data, $Paths.Conf)) { if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } }
        Write-Ok 'Databases, attachments and configuration erased'
    }
    else {
        Write-Info ('Kept data: {0}, {1}, {2}' -f $Paths.PgData, $Paths.Data, $Paths.Conf)
    }
}

Export-ModuleMember -Function *
