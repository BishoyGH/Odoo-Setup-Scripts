# Safe "Update Odoo": bug-fix updates on the same Odoo version.
#
#   1. Download the latest Odoo and OCA archives while Odoo keeps running.
#      Nothing changed upstream -> stop here ("already up to date").
#   2. Stop Odoo, take a normal backup ZIP (kept afterwards).
#   3. Snapshot for a fast rollback: copy of the database (CREATE DATABASE ... TEMPLATE),
#      attachments and Python environment; old source trees are moved aside.
#   4. Put the new source in place, install Python requirements, run "odoo-bin -u all".
#   5. Start the service and check the login page answers.
#   Any failure in 3-5 rolls everything back. A marker file makes the next run roll back
#   an update that was interrupted (power cut, closed window).
#
# Major-version upgrades are out of scope (they need OpenUpgrade and a test run).

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'OdooSetup.Steps.psm1') -Global -DisableNameChecking

$script:ArchiveMarker = '.oss-archive-sha256'

function Get-UpdateWorkPaths {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths)
    $work = Join-Path $Paths.Root '_update'
    $old = Join-Path $work 'old'
    return @{
        Work      = $work
        Old       = $old
        Marker    = (Join-Path $work 'update.json')
        OdooSrc   = (Join-Path $old 'odoo')
        OcaDir    = (Join-Path $old 'oca')
        Venv      = (Join-Path $old 'venv')
        Filestore = (Join-Path $old 'filestore')
    }
}

function Get-FolderSizeMB {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return 0 }
    $sum = (Get-ChildItem $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { return 0 }
    return [Math]::Ceiling($sum / 1MB)
}

function Get-DriveFreeMB {
    param([Parameter(Mandatory)][string]$Path)
    $drive = Split-Path $Path -Qualifier
    $d = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive) -ErrorAction SilentlyContinue
    if (-not $d) { return -1 }
    return [Math]::Floor($d.FreeSpace / 1MB)
}

function Get-InstalledOcaRepos {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths)
    if (-not (Test-Path $Paths.OcaDir)) { return @() }
    return @(Get-ChildItem $Paths.OcaDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName '.oss-branch') } |
        Sort-Object Name | ForEach-Object { $_.Name })
}

function Get-TreeArchiveHash {
    param([Parameter(Mandatory)][string]$Path)
    $f = Join-Path $Path $script:ArchiveMarker
    if (Test-Path $f) { return (Get-Content $f -Raw).Trim() }
    return ''
}

function Copy-FolderTree {
    <# Copies a folder tree (robocopy handles long paths and is fast); throws on failure. #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    & robocopy.exe $Source $Destination /E /COPY:DAT /R:1 /W:1 /MT:8 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw ('Copying {0} failed (robocopy {1})' -f $Source, $LASTEXITCODE) }
}

function Remove-FolderSafe {
    param([string]$Path)
    if ($Path -and (Test-Path $Path)) { Remove-Item $Path -Recurse -Force }
}

function Get-UpdateDownloads {
    <#
      Downloads fresh archives for Odoo and every installed OCA repository and
      returns the trees whose archive differs from what is installed now.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Components,
        [Parameter(Mandatory)][string]$Version
    )
    $trees = @([pscustomobject]@{
            Name = 'odoo'; Repo = ''; Dest = $Paths.OdooSrc
            Url = ($Components.OdooSourceUrl -f $Version)
            Cache = (Join-Path $Paths.Downloads ('odoo-{0}.zip' -f $Version))
        })
    foreach ($repo in (Get-InstalledOcaRepos $Paths)) {
        $trees += [pscustomobject]@{
            Name = ('OCA/' + $repo); Repo = $repo; Dest = (Join-Path $Paths.OcaDir $repo)
            Url = ($Components.OcaSourceUrl -f $repo, $Version)
            Cache = (Join-Path $Paths.Downloads ('oca-{0}-{1}.zip' -f $repo, $Version))
        }
    }
    $changed = @()
    foreach ($t in $trees) {
        Write-Info ('Checking {0} {1}' -f $t.Name, $Version)
        # A failed download aborts here, before anything on this PC has changed.
        Invoke-Download -Url $t.Url -Destination $t.Cache -Refresh | Out-Null
        $sha = Get-FileSha256 $t.Cache
        if ($sha -ne (Get-TreeArchiveHash $t.Dest)) {
            $t | Add-Member -NotePropertyName Sha256 -NotePropertyValue $sha
            $t | Add-Member -NotePropertyName ZipMB -NotePropertyValue ([Math]::Ceiling((Get-Item $t.Cache).Length / 1MB))
            $changed += $t
        }
    }
    return , $changed
}

function Invoke-PreUpdateBackup {
    <# Runs the normal backup script and returns the ZIP it wrote. #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][string]$Destination
    )
    $started = Get-Date
    $backupScript = Join-Path $Paths.Tools 'backup.ps1'
    if (-not (Test-Path $backupScript)) { throw ('{0} not found. Run Repair first.' -f $backupScript) }
    & $backupScript -Root $Paths.Root -Destination $Destination
    if ($LASTEXITCODE -ne 0) { throw ('The backup failed, so nothing was updated. See {0}' -f (Join-Path $Paths.Logs 'backup.log')) }
    $status = Read-JsonFile (Join-Path $Paths.Logs 'last-backup.json')
    if (-not $status -or -not (Test-Path $status.File) -or (Get-Item $status.File).LastWriteTime -lt $started.AddSeconds(-5)) {
        throw 'The backup did not produce a new ZIP file, so nothing was updated.'
    }
    return $status.File
}

function New-UpdateSnapshot {
    <#
      Keeps everything needed to undo the update. Copies are flagged with a ".done"
      file so a rollback after an interruption never restores a half-made copy.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Secrets,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Trees,
        [Parameter(Mandatory)][string]$BackupZip
    )
    $u = Get-UpdateWorkPaths $Paths
    $db = $Settings.DbName
    $snapDb = Get-PreUpdateDatabaseName $db
    New-Item -ItemType Directory -Path $u.OcaDir -Force | Out-Null
    Write-JsonFile -Path $u.Marker -Data ([ordered]@{
            Started = (Get-Date).ToString('s'); DbName = $db; SnapshotDb = $snapDb; BackupZip = $BackupZip
        })

    Write-Info 'Copying attachments...'
    $fs = Join-Path $Paths.Data ('filestore\' + $db)
    if (Test-Path $fs) { Copy-FolderTree -Source $fs -Destination $u.Filestore }
    Set-Content -Path ($u.Filestore + '.done') -Value (Test-Path $fs) -Encoding ASCII

    Write-Info 'Copying the database...'
    $pg = @{ Paths = $Paths; Port = $Settings.PgPort; User = 'postgres'; Password = $Secrets.PgSuperPassword }
    Invoke-Psql @pg -Sql ('DROP DATABASE IF EXISTS "{0}"' -f $snapDb) | Out-Null
    Invoke-Psql @pg -Sql ("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='{0}'" -f $db) | Out-Null
    Invoke-Psql @pg -Sql ('CREATE DATABASE "{0}" WITH TEMPLATE "{1}" OWNER odoo' -f $snapDb, $db) | Out-Null
    Set-Content -Path (Join-Path $u.Old 'db.done') -Value $snapDb -Encoding ASCII

    Write-Info 'Copying the Python environment...'
    Copy-FolderTree -Source $Paths.Venv -Destination $u.Venv
    Set-Content -Path ($u.Venv + '.done') -Value 'True' -Encoding ASCII

    # Moving is instant on the same drive, and the old tree comes back the same way.
    foreach ($t in $Trees) {
        if (-not (Test-Path $t.Dest)) { continue }
        $target = $u.OdooSrc
        if ($t.Repo) { $target = Join-Path $u.OcaDir $t.Repo }
        Move-Item -Path $t.Dest -Destination $target
    }
}

function Restore-UpdateSnapshot {
    <# Undoes an update from the snapshot in _update\. Safe to run again if it is interrupted. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Secrets
    )
    $u = Get-UpdateWorkPaths $Paths
    $info = Read-JsonFile $u.Marker
    if (-not $info) { return }
    Write-Section 'Rolling back the update'
    Stop-ServiceSafe -Name (Get-OdooServiceName)
    Start-ServiceSafe -Name (Get-PgServiceName)

    # Source trees
    if (Test-Path $u.OdooSrc) {
        Remove-FolderSafe $Paths.OdooSrc
        Move-Item -Path $u.OdooSrc -Destination $Paths.OdooSrc
        Write-Ok 'Odoo source restored'
    }
    if (Test-Path $u.OcaDir) {
        foreach ($d in @(Get-ChildItem $u.OcaDir -Directory)) {
            $dest = Join-Path $Paths.OcaDir $d.Name
            Remove-FolderSafe $dest
            Move-Item -Path $d.FullName -Destination $dest
            Write-Ok ('OCA/{0} restored' -f $d.Name)
        }
    }

    # Python environment
    if ((Test-Path ($u.Venv + '.done')) -and (Test-Path $u.Venv)) {
        Remove-FolderSafe $Paths.Venv
        Move-Item -Path $u.Venv -Destination $Paths.Venv
        Remove-Item ($u.Venv + '.done') -Force
        Write-Ok 'Python environment restored'
    }

    # Database: drop the updated one and rename the untouched copy back.
    $pg = @{ Paths = $Paths; Port = $Settings.PgPort; User = 'postgres'; Password = $Secrets.PgSuperPassword }
    $dbDone = Join-Path $u.Old 'db.done'
    if (Test-Path $dbDone) {
        $snapDb = $info.SnapshotDb
        $exists = Invoke-Psql @pg -Sql ("SELECT 1 FROM pg_database WHERE datname='{0}'" -f $snapDb)
        if ($exists -eq '1') {
            foreach ($name in @($info.DbName, $snapDb)) {
                Invoke-Psql @pg -Sql ("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='{0}'" -f $name) | Out-Null
            }
            Invoke-Psql @pg -Sql ('DROP DATABASE IF EXISTS "{0}"' -f $info.DbName) | Out-Null
            Invoke-Psql @pg -Sql ('ALTER DATABASE "{0}" RENAME TO "{1}"' -f $snapDb, $info.DbName) | Out-Null
            Write-Ok ('Database "{0}" restored' -f $info.DbName)
        }
        Remove-Item $dbDone -Force
    }

    # Attachments
    if (Test-Path ($u.Filestore + '.done')) {
        $fs = Join-Path $Paths.Data ('filestore\' + $info.DbName)
        $hadFilestore = ((Get-Content ($u.Filestore + '.done') -Raw).Trim() -eq 'True')
        if ($hadFilestore -and (Test-Path $u.Filestore)) {
            Remove-FolderSafe $fs
            Move-Item -Path $u.Filestore -Destination $fs
            Grant-FolderAccess -Path $fs -Sid $SidNetworkService -Rights 'M'
            Write-Ok 'Attachments restored'
        }
        elseif (-not $hadFilestore) { Remove-FolderSafe $fs }
        Remove-Item ($u.Filestore + '.done') -Force
    }

    Remove-FolderSafe $u.Work
    Start-ServiceSafe -Name (Get-OdooServiceName)
    Write-Ok 'Odoo is back to the version it had before the update.'
    if ($info.BackupZip) { Write-Info ('The backup taken before the update is kept: {0}' -f $info.BackupZip) }
}

function Remove-UpdateSnapshot {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Secrets
    )
    $u = Get-UpdateWorkPaths $Paths
    $snapDb = Get-PreUpdateDatabaseName $Settings.DbName
    try {
        Invoke-Psql -Paths $Paths -Port $Settings.PgPort -User 'postgres' -Password $Secrets.PgSuperPassword `
            -Sql ('DROP DATABASE IF EXISTS "{0}"' -f $snapDb) | Out-Null
        Remove-FolderSafe $u.Work
    }
    catch { Write-Warn ('Could not remove the rollback copy in {0}: {1}' -f $u.Work, $_.Exception.Message) }
}

function Test-ModulesSettled {
    <# After "-u all" no module may be left half-way (to upgrade / to install / to remove). #>
    param($Paths, $Settings, $Secrets)
    $n = Invoke-Psql -Paths $Paths -Port $Settings.PgPort -User 'odoo' -Password $Secrets.OdooDbPassword -Database $Settings.DbName `
        -Sql "SELECT count(*) FROM ir_module_module WHERE state IN ('to upgrade', 'to install', 'to remove')"
    return ($n -eq '0')
}

function Invoke-OdooUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Secrets,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Components,
        [switch]$NoPrompt,
        [int]$HttpTimeoutSeconds = 300
    )
    Write-Section 'Update Odoo'
    $u = Get-UpdateWorkPaths $Paths
    if (Test-Path $u.Marker) {
        Write-Warn 'The last update did not finish (the PC may have been switched off). Undoing it first.'
        Restore-UpdateSnapshot -Paths $Paths -Settings $Settings -Secrets $Secrets
        Write-Info 'Run "Update Odoo" again when you are ready.'
        return
    }
    $odooSvc = Get-OdooServiceName
    if (-not (Get-Service -Name $odooSvc -ErrorAction SilentlyContinue)) { throw 'The Odoo service is not installed. Run Repair first.' }

    Write-Host ('   Installs the latest bug fixes for Odoo {0} and the community add-ons.' -f $Settings.OdooVersion) -ForegroundColor Gray
    Write-Host '   A backup is taken first, and if anything fails Odoo is put back exactly as it was.' -ForegroundColor Gray
    Write-Host '   Odoo is unavailable while the update runs (about 10-30 minutes).' -ForegroundColor Gray
    if (-not $NoPrompt -and -not (Read-YesNo -Prompt 'Check for updates now?' -Default $true)) { return }

    $log = Start-SetupLog -LogDir $Paths.Logs -Prefix 'update'
    $snapshotStarted = $false
    try {
        Initialize-StepCounter -Total 6
        Start-ServiceSafe -Name (Get-PgServiceName)

        Write-Step 'Download the latest source (Odoo keeps running)'
        $changed = Get-UpdateDownloads -Paths $Paths -Components $Components -Version $Settings.OdooVersion
        if ($changed.Count -eq 0) { Write-Ok 'Already up to date. Nothing was changed.'; return }
        Write-Ok ('Updates available for: {0}' -f (($changed | ForEach-Object { $_.Name }) -join ', '))

        $backupDir = Join-Path $Paths.Root 'backups'
        if ($Settings.Backup -and $Settings.Backup.Dir) { $backupDir = $Settings.Backup.Dir }
        $dbMB = [double](Invoke-Psql -Paths $Paths -Port $Settings.PgPort -User 'odoo' -Password $Secrets.OdooDbPassword `
                -Sql ("SELECT pg_database_size('{0}') / 1048576" -f $Settings.DbName))
        $fsMB = Get-FolderSizeMB (Join-Path $Paths.Data ('filestore\' + $Settings.DbName))
        $venvMB = Get-FolderSizeMB $Paths.Venv
        $srcMB = 3 * ($changed | Measure-Object -Property ZipMB -Sum).Sum
        $sameDrive = ((Split-Path $backupDir -Qualifier) -eq (Split-Path $Paths.Root -Qualifier))
        $needMB = Get-UpdateFreeSpaceNeededMB -DatabaseMB $dbMB -FilestoreMB $fsMB -VenvMB $venvMB -NewSourceMB $srcMB -BackupOnSameDrive $sameDrive
        $freeMB = Get-DriveFreeMB $Paths.Root
        if ($freeMB -ge 0 -and $freeMB -lt $needMB) {
            throw ('Not enough free space on {0}: the update needs about {1:N1} GB, {2:N1} GB is free. Nothing was changed.' -f `
                (Split-Path $Paths.Root -Qualifier), ($needMB / 1024), ($freeMB / 1024))
        }

        Write-Step 'Stop Odoo and back up'
        Stop-ServiceSafe -Name $odooSvc
        $zip = Invoke-PreUpdateBackup -Paths $Paths -Destination $backupDir
        Write-Ok ('Backup: {0}' -f $zip)

        Write-Step 'Keep a copy for rollback'
        $snapshotStarted = $true
        New-UpdateSnapshot -Paths $Paths -Settings $Settings -Secrets $Secrets -Trees $changed -BackupZip $zip

        Write-Step 'Install the new source and Python packages'
        foreach ($t in $changed) {
            Write-Info ('Extracting {0}' -f $t.Name)
            Install-SourceTree -Url $t.Url -Destination $t.Dest -Branch $Settings.OdooVersion -CacheFile $t.Cache
            Set-Content -Path (Join-Path $t.Dest $script:ArchiveMarker) -Value $t.Sha256 -Encoding ASCII
        }
        if (-not (Test-Path $Paths.OdooBin)) { throw 'odoo-bin not found after extraction.' }
        Install-OdooVenv -Paths $Paths -Mode $Settings.Mode
        foreach ($t in @($changed | Where-Object { $_.Repo })) {
            $req = Join-Path $t.Dest 'requirements.txt'
            if (Test-Path $req) {
                Invoke-Pip -Paths $Paths -PipArgs @('install', '--prefer-binary', '-r', ('"{0}"' -f $req)) -LogName ('pip-oca-' + $t.Repo)
            }
        }

        Write-Step 'Update the database (odoo-bin -u all, can take 10-20 minutes)'
        Invoke-OdooBin -Paths $Paths -OdooArgs @('-c', ('"{0}"' -f $Paths.OdooConf), '-d', $Settings.DbName, '-u', 'all', '--no-http', '--stop-after-init') `
            -LogName 'odoo-update-all'
        if (-not (Test-ModulesSettled -Paths $Paths -Settings $Settings -Secrets $Secrets)) {
            throw ('Some modules did not finish updating. See {0}' -f (Join-Path $Paths.Logs 'odoo-update-all.log.err'))
        }

        Write-Step 'Start Odoo and check it answers'
        Start-ServiceSafe -Name $odooSvc
        if (-not (Test-OdooHttp -Port $Settings.HttpPort -TimeoutSeconds $HttpTimeoutSeconds)) {
            throw ('Odoo did not answer on port {0} after the update.' -f $Settings.HttpPort)
        }
        Remove-UpdateSnapshot -Paths $Paths -Settings $Settings -Secrets $Secrets
        $snapshotStarted = $false
        Write-Ok 'Odoo is updated and running.'
        Write-Info ('Backup taken before the update: {0}' -f $zip)
    }
    catch {
        Write-Fail $_.Exception.Message
        if ($snapshotStarted) {
            try { Restore-UpdateSnapshot -Paths $Paths -Settings $Settings -Secrets $Secrets }
            catch {
                Write-Fail ('Rollback failed: {0}' -f $_.Exception.Message)
                Write-Warn 'Run "Update Odoo" again to retry the rollback, or "Restore from a backup" with the ZIP above.'
            }
        }
        else {
            # Failed before anything changed: make sure Odoo is serving again.
            try { Start-ServiceSafe -Name $odooSvc } catch { Write-Warn $_.Exception.Message }
        }
        Write-Host ('   Full log: {0}' -f $log) -ForegroundColor Yellow
        throw 'The update did not complete.'
    }
    finally { Stop-SetupLog }
}

Export-ModuleMember -Function Invoke-OdooUpdate, Restore-UpdateSnapshot
