<#
.SYNOPSIS
  Interactive, native (no Docker) Odoo setup for Windows 10/11, tuned for
  4 GB / 8 GB PCs and configured for Egyptian businesses.

.DESCRIPTION
  Double-click install.cmd, or run from an elevated PowerShell:
    powershell -ExecutionPolicy Bypass -File .\setup.ps1

  Actions: Install (default menu), Repair, Backup, Restore, Status, Uninstall.
  Unattended: .\setup.ps1 -Action Install -ConfigFile .\config\answers.example.psd1

.PARAMETER Action
  Skip the menu and run one action.

.PARAMETER ConfigFile
  A .psd1 answers file (see config\answers.example.psd1). Implies no prompts.

.PARAMETER Root
  Installation folder for Repair/Backup/Restore/Status/Uninstall when it is not C:\Odoo.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Install', 'Repair', 'Backup', 'Restore', 'Status', 'Uninstall')]
    [string]$Action = 'Menu',
    [string]$ConfigFile = '',
    [string]$Root = 'C:\Odoo'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$here = $PSScriptRoot
$script:InstallRoot = $Root
Import-Module (Join-Path $here 'lib\OdooSetup.Maintenance.psm1') -Force -DisableNameChecking

$script:Components = Import-PowerShellDataFile (Join-Path $here 'config\components.psd1')
$script:Catalog = Import-PowerShellDataFile (Join-Path $here 'config\addons.psd1')
$script:Unattended = [bool]$ConfigFile

# ------------------------------------------------------------- answers -----

function Get-DefaultSettings {
    $ram = Get-TotalMemoryGB
    return [ordered]@{
        Root           = $script:InstallRoot
        Mode           = 'prod'
        OdooVersion    = $script:Components.DefaultVersion
        RamProfile     = (Get-RamProfileName -TotalMemoryGB $ram)
        Ssd            = (Test-SystemDiskIsSsd)
        PgPort         = 5432
        HttpPort       = 8069
        CompanyName    = 'My Company'
        DbName         = 'odoo'
        AdminLogin     = 'admin'
        AdminPassword  = ''
        UiLanguage     = 'ar_001'
        Apps           = @($script:Catalog.Apps | Where-Object { $_.Default } | ForEach-Object { $_.Key })
        OcaBundles     = @($script:Catalog.OcaBundles | Where-Object { $_.Default } | ForEach-Object { $_.Key })
        WithDemo       = $false
        Defender       = $true
        DisableSleep   = $true
        MakeNetworkPrivate = $false
        Backup         = [ordered]@{ Enabled = $false; Dir = ''; Time = '22:00'; RetentionDays = 14; CopyDir = ''; TestRestoreDays = 7 }
    }
}

function Read-InstallSettings {
    $s = Get-DefaultSettings
    Write-Section 'Setup questions'
    Write-Host '   Press Enter to accept the value in [brackets].' -ForegroundColor DarkGray
    Write-Host ''

    $mode = Read-Choice -Prompt 'What kind of installation is this?' -Options @(
        'Production  - the company uses it every day (service starts with Windows, LAN access, backups)',
        'Development - for testing or building modules on this PC only (localhost, debug, demo data option)'
    ) -DefaultIndex 0
    $s.Mode = @('prod', 'dev')[$mode]

    $versions = [string[]]$script:Components.OdooVersions
    $labels = foreach ($v in $versions) {
        $note = ''
        if ($v -eq $script:Components.DefaultVersion) { $note = '  (recommended: all community apps available)' }
        elseif ([double]$v -gt [double]$script:Components.DefaultVersion) { $note = '  (newest; some community apps not ported yet)' }
        'Odoo ' + $v + $note
    }
    $s.OdooVersion = $versions[(Read-Choice -Prompt 'Which Odoo version?' -Options $labels -DefaultIndex ([array]::IndexOf($versions, $s.OdooVersion)))]

    $s.Root = Read-Value -Prompt 'Install folder' -Default $s.Root -Validate { param($v) $v -match '^[A-Za-z]:\\[^"<>|?*]*$' }

    $ram = Get-TotalMemoryGB
    $profiles = @('4GB', '8GB', '16GB')
    $pi = Read-Choice -Prompt ('Detected {0} GB RAM. Which tuning profile?' -f $ram) -Options @(
        '4 GB  - small office, up to ~5 users', '8 GB  - up to ~15 users', '16 GB+ - up to ~25 users'
    ) -DefaultIndex ([array]::IndexOf($profiles, $s.RamProfile))
    $s.RamProfile = $profiles[$pi]

    Write-Host ''
    $s.CompanyName = Read-Value -Prompt 'Company name (Arabic or English)' -Default $s.CompanyName -Validate { param($v) $v.Length -ge 2 }
    $s.DbName = Read-Value -Prompt 'Database name (English letters, digits, _)' -Default (ConvertTo-DatabaseName $s.CompanyName) `
        -Validate { param($v) Test-DatabaseName $v } -ValidationMessage 'Start with a letter; use letters, digits, _ . - only.'
    $s.AdminLogin = Read-Value -Prompt 'Administrator login (an email is best)' -Default $s.AdminLogin
    $s.AdminPassword = Read-Password -Prompt 'Administrator password'
    $li = Read-Choice -Prompt 'Language for the administrator' -Options @('Arabic (both Arabic and English are installed)', 'English') -DefaultIndex 0
    $s.UiLanguage = @('ar_001', 'en_US')[$li]

    Write-Host ''
    $s.Apps = Read-MultiChoice -Prompt 'Which Odoo apps should be installed?' -Items $script:Catalog.Apps
    $bundles = @($script:Catalog.OcaBundles | Where-Object { $s.Mode -eq 'dev' -or -not ($_.ContainsKey('DevOnly') -and $_.DevOnly) } | ForEach-Object {
            $b = @{} + $_
            if ($s.Mode -eq 'dev' -and $b.ContainsKey('DevOnly') -and $b.DevOnly) { $b.Default = $true }
            $b
        })
    $s.OcaBundles = Read-MultiChoice -Prompt 'Community (OCA) add-ons that fill gaps in Odoo Community:' -Items $bundles

    if ($s.Mode -eq 'dev') {
        $s.WithDemo = Read-YesNo -Prompt 'Load demo data (sample products, customers, invoices)?' -Default $false
        $s.DisableSleep = $false
        $s.Defender = Read-YesNo -Prompt 'Add Windows Defender exclusions for the database (faster)?' -Default $true
    }
    else {
        Write-Host ''
        $s.Backup.Enabled = Read-YesNo -Prompt 'Enable automatic daily backups?' -Default $true
        if ($s.Backup.Enabled) {
            $s.Backup.Dir = Select-BackupFolder
            $s.Backup.Time = Read-Value -Prompt 'Daily backup time (24h, HH:mm). If the PC is off it runs at next start' -Default $s.Backup.Time `
                -Validate { param($v) $v -match '^([01]\d|2[0-3]):[0-5]\d$' }
            $s.Backup.RetentionDays = [int](Read-Value -Prompt 'Keep backups for how many days?' -Default '14' -Validate { param($v) $v -match '^\d+$' -and [int]$v -ge 1 -and [int]$v -le 3650 })
            Write-Host '   A second copy on a USB drive or another disk survives a failed disk, theft or ransomware on this one.' -ForegroundColor Gray
            if (Read-YesNo -Prompt 'Also copy every backup to a second drive?' -Default $true) {
                $s.Backup.CopyDir = Select-BackupCopyFolder -PrimaryDir $s.Backup.Dir
            }
        }
        $s.Defender = Read-YesNo -Prompt 'Add Windows Defender exclusions for the database and attachments (faster)?' -Default $true
        $s.DisableSleep = Read-YesNo -Prompt 'Prevent this PC from sleeping while plugged in (needed for a server)?' -Default $true
        $public = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.NetworkCategory -eq 'Public' })
        if ($public.Count -gt 0) {
            $s.MakeNetworkPrivate = Read-YesNo -Prompt ('Network "{0}" is Public, which blocks other PCs. Switch it to Private?' -f $public[0].Name) -Default $true
        }
    }
    return $s
}

function Merge-Settings {
    param([System.Collections.IDictionary]$Base, [System.Collections.IDictionary]$Override)
    foreach ($k in @($Override.Keys)) {
        if ($Base.Contains($k) -and $Base[$k] -is [System.Collections.IDictionary] -and $Override[$k] -is [System.Collections.IDictionary]) {
            Merge-Settings -Base $Base[$k] -Override $Override[$k]
        }
        else { $Base[$k] = $Override[$k] }
    }
}

function Show-Summary {
    param([System.Collections.IDictionary]$S)
    Write-Section 'Summary'
    Write-KeyValue 'Mode' $(if ($S.Mode -eq 'prod') { 'Production' } else { 'Development' })
    Write-KeyValue 'Odoo version' $S.OdooVersion
    Write-KeyValue 'Install folder' $S.Root
    Write-KeyValue 'RAM profile' ('{0} ({1})' -f $S.RamProfile, $(if ($S.Ssd) { 'SSD' } else { 'HDD' }))
    Write-KeyValue 'Company' $S.CompanyName
    Write-KeyValue 'Database' $S.DbName
    Write-KeyValue 'Admin login' $S.AdminLogin
    Write-KeyValue 'Localization' 'Egypt, EGP, Africa/Cairo, Arabic + English'
    Write-KeyValue 'Apps' ($S.Apps -join ', ')
    Write-KeyValue 'OCA add-ons' ($S.OcaBundles -join ', ')
    if ($S.Mode -eq 'prod') {
        $b = 'disabled'
        if ($S.Backup.Enabled) { $b = '{0} daily at {1}, keep {2} days' -f $S.Backup.Dir, $S.Backup.Time, $S.Backup.RetentionDays }
        Write-KeyValue 'Backups' $b
        if ($S.Backup.Enabled) {
            Write-KeyValue 'Second copy' $(if ($S.Backup.CopyDir) { $S.Backup.CopyDir } else { 'none' })
            Write-KeyValue 'Test-restore' $(if ($S.Backup.TestRestoreDays -gt 0) { 'every {0} days' -f $S.Backup.TestRestoreDays } else { 'off' })
        }
    }
}

function Get-Secrets {
    param([System.Collections.IDictionary]$Paths, [string]$AdminPassword)
    $existing = Read-JsonFile $Paths.Secrets
    $sec = [ordered]@{
        PgSuperPassword = (New-RandomPassword); OdooDbPassword = (New-RandomPassword)
        MasterPassword = (New-RandomPassword); AdminPassword = (New-RandomPassword -Length 14)
    }
    if ($existing) { foreach ($k in @($existing.Keys)) { if ($existing[$k]) { $sec[$k] = $existing[$k] } } }
    if ($AdminPassword) { $sec.AdminPassword = $AdminPassword }
    New-Item -ItemType Directory -Path $Paths.Conf -Force | Out-Null
    Protect-Folder -Path $Paths.Conf
    Write-JsonFile -Path $Paths.Secrets -Data $sec
    return $sec
}

function Save-Settings {
    param([System.Collections.IDictionary]$Paths, [System.Collections.IDictionary]$S)
    $copy = [ordered]@{}
    foreach ($k in $S.Keys) { if ($k -ne 'AdminPassword') { $copy[$k] = $S[$k] } }   # secrets live in secrets.json only
    Write-JsonFile -Path $Paths.Settings -Data $copy
}

# ------------------------------------------------------------- install -----

function Invoke-Install {
    param([System.Collections.IDictionary]$S, [switch]$Repair)
    $P = Get-InstallPaths -Root $S.Root
    $C = $script:Components
    New-Item -ItemType Directory -Path $P.Root, $P.Logs, $P.Downloads, $P.Conf -Force | Out-Null
    $log = Start-SetupLog -LogDir $P.Logs -Prefix $(if ($Repair) { 'repair' } else { 'install' })
    Initialize-State -Path $P.State
    try {
        Write-Section 'Checking this PC'
        $problems = @(Test-Prerequisites -Paths $P)
        if ($problems.Count -gt 0) { foreach ($p in $problems) { Write-Fail $p }; throw 'Pre-flight checks failed.' }

        # Port conflicts (ignore our own services on repair)
        $used = @(Get-UsedTcpPorts)
        if (-not (Get-Service (Get-PgServiceName) -ErrorAction SilentlyContinue) -and $used -contains $S.PgPort) {
            $S.PgPort = Get-FreePort -Candidates @(5433, 5434, 5435, 5436) -UsedPorts $used
            Write-Warn ('Port 5432 is busy; PostgreSQL will use {0}' -f $S.PgPort)
        }
        if (-not (Get-Service (Get-OdooServiceName) -ErrorAction SilentlyContinue) -and $used -contains $S.HttpPort) {
            $S.HttpPort = Get-FreePort -Candidates @(8070, 8071, 8072, 8080, 8090) -UsedPorts $used
            Write-Warn ('Port 8069 is busy; Odoo will use {0}' -f $S.HttpPort)
        }

        $X = Get-Secrets -Paths $P -AdminPassword $S.AdminPassword
        Save-Settings -Paths $P -S $S
        $sel = Resolve-AddonSelection -Catalog $script:Catalog -AppKeys $S.Apps -BundleKeys $S.OcaBundles
        $isProd = ($S.Mode -eq 'prod')
        $total = 18
        Initialize-StepCounter -Total $total
        Write-Section $(if ($Repair) { 'Repairing' } else { 'Installing' })

        Invoke-SetupStep -Id 'chrome' -Title 'Google Chrome' -Test { [bool](Find-Chrome) } -Run { Install-Chrome -Paths $P -Components $C }
        Invoke-SetupStep -Id 'vcredist' -Title 'Microsoft Visual C++ runtime' -Test { Test-VCRedist } -Run { Install-VCRedist -Paths $P -Components $C }
        Invoke-SetupStep -Id 'python' -Title ('Python {0} (private copy)' -f $C.Python.Version) -Test { Test-Python -Paths $P -Version $C.Python.Version } -Run { Install-Python -Paths $P -Components $C }
        Invoke-SetupStep -Id 'pg-binaries' -Title ('PostgreSQL {0}' -f $C.PostgreSQL.Version) -Test { Test-PgBinaries $P } -Run { Install-PgBinaries -Paths $P -Components $C }
        Invoke-SetupStep -Id 'pg-cluster' -Title 'PostgreSQL database cluster' -Test { Test-PgCluster $P } -Run { Initialize-PgCluster -Paths $P -SuperPassword $X.PgSuperPassword }
        Invoke-SetupStep -Id 'pg-tuning' -Title 'PostgreSQL performance tuning' -Run { Set-PgTuning -Paths $P -Settings $S; Stop-ServiceSafe -Name (Get-PgServiceName) }
        Invoke-SetupStep -Id 'pg-service' -Title 'PostgreSQL Windows service' -Run { Install-PgService -Paths $P -Port $S.PgPort }
        Invoke-SetupStep -Id 'pg-role' -Title 'Odoo database role' -Run { Set-PgOdooRole -Paths $P -Port $S.PgPort -SuperPassword $X.PgSuperPassword -OdooPassword $X.OdooDbPassword }
        Invoke-SetupStep -Id 'wkhtmltopdf' -Title 'wkhtmltopdf (PDF reports)' -Test { Test-Wkhtmltopdf $P } -Run { Install-Wkhtmltopdf -Paths $P -Components $C }
        Invoke-SetupStep -Id 'odoo-source' -Title ('Odoo {0} source code' -f $S.OdooVersion) -Test { Test-SourceTree -Path $P.OdooSrc -Branch $S.OdooVersion } -Run { Install-OdooSource -Paths $P -Components $C -Version $S.OdooVersion }
        Invoke-SetupStep -Id 'odoo-venv' -Title 'Odoo Python packages' -Test { (-not $Repair) -and (Test-OdooVenv -Paths $P -Mode $S.Mode) } -Run { Install-OdooVenv -Paths $P -Mode $S.Mode -Rebuild:$Repair }
        Invoke-SetupStep -Id 'oca' -Title ('Community add-ons ({0} repositories)' -f $sel.Repos.Count) -Run { Install-OcaRepos -Paths $P -Components $C -Version $S.OdooVersion -Repos $sel.Repos }
        Invoke-SetupStep -Id 'config' -Title 'Odoo configuration and permissions' -Run {
            Copy-OdooTools -Paths $P
            Write-OdooConfig -Paths $P -Settings $S -Secrets $X
            Write-CredentialsFile -Paths $P -Settings $S -Secrets $X
        }
        $dbTest = { (Get-OdooDatabaseState -Paths $P -Port $S.PgPort -Password $X.OdooDbPassword -DbName $S.DbName) -eq 'ready' }
        Invoke-SetupStep -Id 'database' -Title ('Database "{0}" with Arabic' -f $S.DbName) -Test $dbTest -Run {
            Stop-ServiceSafe -Name (Get-OdooServiceName)
            if ((Get-OdooDatabaseState -Paths $P -Port $S.PgPort -Password $X.OdooDbPassword -DbName $S.DbName) -eq 'partial') {
                Write-Warn 'Removing a half-created database from an interrupted run...'
                Remove-OdooDatabase -Paths $P -Port $S.PgPort -SuperPassword $X.PgSuperPassword -DbName $S.DbName
                Clear-StepDone 'company'; Clear-StepDone 'modules'
            }
            New-OdooDatabase -Paths $P -Settings $S
        }
        $state = Get-SetupState
        Invoke-SetupStep -Id 'company' -Title 'Company: Egypt, EGP, Africa/Cairo, administrator' -Test { $state.ContainsKey('company') } -Run {
            Set-OdooCompanyDefaults -Paths $P -Settings $S -Secrets $X
        }
        Invoke-SetupStep -Id 'modules' -Title 'Apps and community add-ons' -Test { (-not $Repair) -and $state.ContainsKey('modules') } -Run {
            Stop-ServiceSafe -Name (Get-OdooServiceName)
            Install-OdooModules -Paths $P -Settings $S -Modules $sel.Modules
        }
        Invoke-SetupStep -Id 'service' -Title 'Odoo Windows service' -Run { Install-OdooService -Paths $P -Settings $S -Components $C }
        Invoke-SetupStep -Id 'os' -Title 'Firewall, backups, Defender, power, shortcut' -Run {
            if ($isProd) {
                if ($S.MakeNetworkPrivate) {
                    Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Public' } | Set-NetConnectionProfile -NetworkCategory Private
                    Write-Ok 'Network switched to Private'
                }
                Set-OdooFirewallRule -Port $S.HttpPort; Write-Ok ('Firewall: TCP {0} open on Private/Domain networks' -f $S.HttpPort)
                if ($S.DisableSleep) { Disable-SleepOnAC; Write-Ok 'Sleep on AC power disabled' }
            }
            else { Remove-OdooFirewallRule }
            if ($S.Backup.Enabled -and $isProd) {
                New-Item -ItemType Directory -Path $S.Backup.Dir -Force | Out-Null
                Protect-Folder -Path $S.Backup.Dir
                Register-BackupTask -Paths $P -Time $S.Backup.Time
                Write-Ok ('Daily backup at {0} to {1}' -f $S.Backup.Time, $S.Backup.Dir)
                if ($S.Backup.CopyDir) {
                    if (Test-Path ((Split-Path $S.Backup.CopyDir -Qualifier) + '\')) {
                        New-Item -ItemType Directory -Path $S.Backup.CopyDir -Force | Out-Null
                        try { Protect-Folder -Path $S.Backup.CopyDir }
                        catch { Write-Warn 'Could not restrict access to the second-copy folder (FAT/exFAT drives have no permissions).' }
                        Write-Ok ('Second copy of every backup to {0}' -f $S.Backup.CopyDir)
                    }
                    else { Write-Warn ('Second-copy drive {0} is not connected; plug it in before the next backup.' -f (Split-Path $S.Backup.CopyDir -Qualifier)) }
                }
            }
            else { Unregister-BackupTask }
            if ($S.Defender) { if (Set-DefenderExclusions -Paths $P) { Write-Ok 'Defender exclusions added' } }
            $lnk = New-OdooShortcut -Port $S.HttpPort
            Write-Ok ('Desktop shortcut: {0}' -f $lnk)
        }

        Save-Settings -Paths $P -S $S
        Set-StepDone 'complete'
        Show-Finish -P $P -S $S -X $X
    }
    catch {
        Write-Host ''
        Write-Fail $_.Exception.Message
        Write-Host ('   Full log: {0}' -f $log) -ForegroundColor Yellow
        Write-Host '   Fix the problem and run setup again: finished steps are skipped automatically.' -ForegroundColor Yellow
        throw
    }
    finally { Stop-SetupLog }
}

function Show-Finish {
    param($P, $S, $X)
    Write-Section 'Odoo is ready'
    Write-KeyValue 'Open on this PC' ('http://localhost:{0}' -f $S.HttpPort)
    if ($S.Mode -eq 'prod') {
        foreach ($ip in (Get-LanAddresses)) { Write-KeyValue 'Open from other PCs' ('http://{0}:{1}' -f $ip, $S.HttpPort) }
    }
    Write-KeyValue 'Login' $S.AdminLogin
    Write-KeyValue 'Password' $X.AdminPassword
    Write-KeyValue 'All credentials' $P.Credentials
    Write-KeyValue 'Daily control' ('{0}\odoo-ctl.ps1 status|restart|logs|backup' -f $P.Tools)
    Write-Host ''
    Write-Host '   Write down the password above and keep CREDENTIALS.txt safe.' -ForegroundColor Yellow
    if (-not $script:Unattended -and (Find-Chrome)) {
        if (Read-YesNo -Prompt 'Open Odoo now?' -Default $true) { Start-Process (Find-Chrome) ('--app=http://localhost:{0}/web' -f $S.HttpPort) }
    }
}

function Get-InstalledContext {
    param([string]$RootPath)
    $P = Get-InstallPaths -Root $RootPath
    $S = Read-JsonFile $P.Settings
    if (-not $S) { throw ('No installation found in {0}. Use -Root if you installed elsewhere.' -f $RootPath) }
    $X = Read-JsonFile $P.Secrets
    return @{ P = $P; S = $S; X = $X }
}

# ---------------------------------------------------------------- main -----

function Invoke-Action {
    param([string]$Name)
    switch ($Name) {
        'Install' {
            $s = Get-DefaultSettings
            $P0 = Get-InstallPaths -Root $script:InstallRoot
            $previous = Read-JsonFile $P0.Settings
            $state = $null
            if ($previous) { Initialize-State -Path $P0.State; $state = Get-SetupState }
            if ($script:Unattended) {
                Merge-Settings -Base $s -Override (Import-PowerShellDataFile $ConfigFile)
            }
            elseif ($previous -and -not $state.ContainsKey('complete')) {
                Write-Warn ('An unfinished installation was found in {0}.' -f $P0.Root)
                if (Read-YesNo -Prompt 'Resume it with the same answers?' -Default $true) { Merge-Settings -Base $s -Override $previous }
                else { $s = Read-InstallSettings }
            }
            elseif ($previous) {
                Write-Warn ('Odoo is already installed in {0}. Use Repair to fix it, or Uninstall first.' -f $P0.Root)
                return
            }
            else { $s = Read-InstallSettings }
            Show-Summary $s
            if (-not $script:Unattended -and -not (Read-YesNo -Prompt 'Start the installation?' -Default $true)) { return }
            Invoke-Install -S $s
        }
        'Repair' {
            $ctx = Get-InstalledContext $script:InstallRoot
            $s = Get-DefaultSettings; Merge-Settings -Base $s -Override $ctx.S
            Write-Info 'Repair re-checks every component, rebuilds Python packages, rewrites configs and restarts services.'
            Invoke-Install -S $s -Repair
        }
        'Backup' {
            $ctx = Get-InstalledContext $script:InstallRoot
            & (Join-Path $ctx.P.Tools 'backup.ps1') -Root $ctx.P.Root
        }
        'Restore' {
            $ctx = Get-InstalledContext $script:InstallRoot
            $db = Invoke-OdooRestore -Paths $ctx.P -Settings $ctx.S -Secrets $ctx.X
            if ($db -and $db -ne $ctx.S.DbName -and $ctx.S.Mode -eq 'prod') {
                if (Read-YesNo -Prompt ('Make "{0}" the database Odoo serves (production allows one)?' -f $db) -Default $false) {
                    $s = Get-DefaultSettings; Merge-Settings -Base $s -Override $ctx.S; $s.DbName = $db
                    Write-OdooConfig -Paths $ctx.P -Settings $s -Secrets $ctx.X
                    Save-Settings -Paths $ctx.P -S $s
                    Restart-Service (Get-OdooServiceName) -Force
                }
            }
        }
        'Status' { $P = Get-InstallPaths -Root $script:InstallRoot; Show-OdooStatus -Paths $P -Settings (Read-JsonFile $P.Settings) }
        'Uninstall' { $P = Get-InstallPaths -Root $script:InstallRoot; Invoke-OdooUninstall -Paths $P }
    }
}

if (-not (Test-IsAdministrator)) {
    Write-Fail 'Please run as Administrator (double-click install.cmd, it asks for permission automatically).'
    exit 1
}

Write-Banner
if ($Action -ne 'Menu') {
    try { Invoke-Action $Action; exit 0 } catch { Write-Fail $_.Exception.Message; exit 1 }
}

while ($true) {
    $choice = Read-Choice -Prompt 'What would you like to do?' -Options @(
        'Install Odoo', 'Status', 'Back up now', 'Restore from a backup', 'Repair installation', 'Uninstall', 'Exit'
    ) -DefaultIndex 0
    $name = @('Install', 'Status', 'Backup', 'Restore', 'Repair', 'Uninstall', 'Exit')[$choice]
    if ($name -eq 'Exit') { break }
    try { Invoke-Action $name } catch { Write-Fail $_.Exception.Message }
    Wait-AnyKey
}
