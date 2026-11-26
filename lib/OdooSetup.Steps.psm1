# Windows install steps. Every function is safe to run again:
# it checks the machine first and only does what is missing.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'OdooSetup.UI.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'OdooSetup.Core.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'OdooSetup.Logic.psm1') -Global -DisableNameChecking

$script:PgServiceName = 'OdooPostgreSQL'
$script:OdooServiceName = 'odoo'
$script:FirewallRuleName = 'OdooSetup-HTTP'
$script:BackupTaskName = 'Odoo Daily Backup'

function Get-PgServiceName { return $script:PgServiceName }
function Get-OdooServiceName { return $script:OdooServiceName }
function Get-BackupTaskName { return $script:BackupTaskName }

function Get-CachedFileName {
    param([Parameter(Mandatory)][string]$Url, [string]$Fallback = 'download.bin')
    $leaf = ($Url -split '[?#]')[0].Split('/')[-1]
    if (-not $leaf -or $leaf -notmatch '\.') { return $Fallback }
    return $leaf
}

# ------------------------------------------------------------ pre-flight ---

function Test-Prerequisites {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths, [double]$RequiredGB = 8)
    $problems = @()
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    Write-KeyValue 'Windows' ('{0} (build {1})' -f $os.Caption, $build)
    if ($build -lt 17134) { $problems += 'Windows 10 version 1803 or newer is required (built-in curl.exe and tar.exe).' }
    if (-not [Environment]::Is64BitOperatingSystem) { $problems += 'A 64-bit Windows is required.' }
    if (-not (Test-IsAdministrator)) { $problems += 'Run as Administrator (install.cmd does this for you).' }

    $drive = (Split-Path $Paths.Root -Qualifier)
    $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive)
    if ($disk) {
        $free = [Math]::Round($disk.FreeSpace / 1GB, 1)
        Write-KeyValue ('Free space on ' + $drive) ('{0} GB' -f $free)
        if ($free -lt $RequiredGB) { $problems += ('At least {0} GB free on {1} is needed.' -f $RequiredGB, $drive) }
    }
    Write-KeyValue 'Memory' ('{0} GB' -f (Get-TotalMemoryGB))

    try {
        $null = Invoke-WebRequest -Uri 'https://codeload.github.com' -Method Head -UseBasicParsing -TimeoutSec 20
        Write-KeyValue 'Internet' 'OK'
    }
    catch {
        # codeload answers HEAD / with an error status but that still proves connectivity.
        if ($_.Exception.Response) { Write-KeyValue 'Internet' 'OK' }
        else { $problems += 'No internet connection (needed to download components).' }
    }
    return $problems
}

# ---------------------------------------------------------------- chrome ---

function Find-Chrome {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $reg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
    if (Test-Path $reg) {
        $p = (Get-ItemProperty $reg).'(default)'
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

function Install-Chrome {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths, [Parameter(Mandatory)][System.Collections.IDictionary]$Components)
    $c = $Components.Chrome
    $msi = Invoke-Download -Url $c.Url -Destination (Join-Path $Paths.Downloads 'chrome-enterprise-x64.msi') -Sha256 $c.Sha256
    Write-Info 'Installing Google Chrome silently...'
    Invoke-Native -FilePath 'msiexec.exe' -ArgumentList @('/i', ('"{0}"' -f $msi), '/qn', '/norestart') -SuccessCodes @(0, 1641, 3010) | Out-Null
    if (-not (Find-Chrome)) { throw 'Chrome installation finished but chrome.exe was not found.' }
}

# --------------------------------------------------------------- runtime ---

function Test-VCRedist {
    $key = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    if (-not (Test-Path $key)) { return $false }
    $p = Get-ItemProperty $key
    return ($p.Installed -eq 1 -and [int]$p.Major -ge 14 -and [int]$p.Minor -ge 30)
}

function Install-VCRedist {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths, [Parameter(Mandatory)][System.Collections.IDictionary]$Components)
    $c = $Components.VCRedist
    $exe = Invoke-Download -Url $c.Url -Destination (Join-Path $Paths.Downloads 'vc_redist.x64.exe') -Sha256 $c.Sha256
    Invoke-Native -FilePath $exe -ArgumentList @('/install', '/quiet', '/norestart') -SuccessCodes @(0, 1638, 3010) | Out-Null
}

# ---------------------------------------------------------------- python ---

function Test-Python {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths, [Parameter(Mandatory)][string]$Version)
    if (-not (Test-Path $Paths.PythonExe)) { return $false }
    $ErrorActionPreference = 'Continue'
    $v = (& $Paths.PythonExe -c 'import platform; print(platform.python_version())' 2>$null)
    return ($v -eq $Version)
}

function Get-RegisteredPythonPath {
    <#
      Returns the folder of a Python with the same major.minor version that the
      python.org installer already registered on this PC, or $null. The
      installer cannot put a second copy of the same 3.x side by side: it
      modifies or upgrades the registered one and ignores TargetDir.
    #>
    param([Parameter(Mandatory)][string]$Version)
    $minor = ($Version -split '\.')[0..1] -join '.'
    foreach ($hive in @('HKLM:', 'HKCU:')) {
        $key = '{0}\SOFTWARE\Python\PythonCore\{1}\InstallPath' -f $hive, $minor
        $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($item -and $item.'(default)') { return $item.'(default)'.TrimEnd('\') }
    }
    return $null
}

function Install-PythonFromNuGet {
    <# Unpacks the official python.org NuGet package: a full Python with no registry entries or uninstaller. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths, [Parameter(Mandatory)][System.Collections.IDictionary]$Components)
    $c = $Components.Python
    $pkg = Invoke-Download -Url $c.NuGetUrl -Destination (Join-Path $Paths.Downloads ('python.{0}.nupkg' -f $c.Version)) -Sha256 $c.NuGetSha256
    $tmp = Join-Path $Paths.Downloads 'python-nuget'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Zip -Path $pkg -Destination $tmp
    if (-not (Test-Path (Join-Path $tmp 'tools\python.exe'))) { throw ('The Python package {0} has no tools\python.exe' -f $pkg) }
    if (Test-Path $Paths.Python) { Remove-Item $Paths.Python -Recurse -Force }
    Move-Item -Path (Join-Path $tmp 'tools') -Destination $Paths.Python
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    # Marks this copy as unpacked, so Uninstall never runs the python.org
    # uninstaller (that would remove the other Python on this PC).
    Set-Content -Path (Join-Path $Paths.Python 'odoo-setup-nuget.txt') -Value $c.Version -Encoding ASCII
}

function Install-Python {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths, [Parameter(Mandatory)][System.Collections.IDictionary]$Components)
    $c = $Components.Python
    $existing = Get-RegisteredPythonPath -Version $c.Version
    if ($existing -and ($existing -ne $Paths.Python.TrimEnd('\'))) {
        Write-Info ('Python {0} is already installed at {1}; leaving it alone and unpacking a private copy to {2}' -f (($c.Version -split '\.')[0..1] -join '.'), $existing, $Paths.Python)
        Install-PythonFromNuGet -Paths $Paths -Components $Components
        return
    }
    $exe = Invoke-Download -Url $c.Url -Destination (Join-Path $Paths.Downloads (Get-CachedFileName $c.Url)) -Sha256 $c.Sha256
    Write-Info ('Installing private Python {0} to {1}' -f $c.Version, $Paths.Python)
    $installArgs = @(
        '/quiet', 'InstallAllUsers=1', ('TargetDir="{0}"' -f $Paths.Python), 'PrependPath=0', 'AssociateFiles=0',
        'Shortcuts=0', 'Include_launcher=0', 'InstallLauncherAllUsers=0', 'Include_test=0', 'Include_doc=0',
        'Include_tcltk=0', 'Include_dev=0', 'CompileAll=0', ('/log "{0}"' -f (Join-Path $Paths.Logs 'python-install.log'))
    )
    Invoke-Native -FilePath $exe -ArgumentList $installArgs -SuccessCodes @(0, 3010) | Out-Null
    if (-not (Test-Path $Paths.PythonExe)) {
        Write-Warn ('The Python installer did not use {0}; unpacking a private copy instead.' -f $Paths.Python)
        Install-PythonFromNuGet -Paths $Paths -Components $Components
    }
}

# ------------------------------------------------------------ postgresql ---

function Test-PgBinaries { param($Paths) return (Test-Path (Join-Path $Paths.PgBin 'postgres.exe')) }

function Install-PgBinaries {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths, [Parameter(Mandatory)][System.Collections.IDictionary]$Components)
    $c = $Components.PostgreSQL
    $zip = Invoke-Download -Url $c.Url -Destination (Join-Path $Paths.Downloads (Get-CachedFileName $c.Url)) -Sha256 $c.Sha256
    Write-Info 'Extracting PostgreSQL (without pgAdmin and StackBuilder)...'
    # The archive has a top-level "pgsql" folder.
    Expand-Zip -Path $zip -Destination $Paths.Root -Exclude @('pgsql/pgAdmin 4/*', 'pgsql/pgAdmin 4', 'pgsql/StackBuilder/*', 'pgsql/symbols/*', 'pgsql/doc/*')
    if (-not (Test-PgBinaries $Paths)) { throw 'postgres.exe not found after extraction.' }
}

function Test-PgCluster { param($Paths) return (Test-Path (Join-Path $Paths.PgData 'PG_VERSION')) }

function Initialize-PgCluster {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths, [Parameter(Mandatory)][string]$SuperPassword)
    if ((Test-Path $Paths.PgData) -and (Get-ChildItem $Paths.PgData -Force | Select-Object -First 1)) {
        throw ('{0} exists but is not a PostgreSQL cluster. Move it away and run setup again.' -f $Paths.PgData)
    }
    New-Item -ItemType Directory -Path $Paths.PgData -Force | Out-Null
    Grant-FolderAccess -Path $Paths.PgData -Sid $SidNetworkService -Rights 'F'
    # initdb drops Administrator rights (restricted token), so the user needs explicit access too.
    Grant-FolderAccess -Path $Paths.PgData -Sid (Get-CurrentUserSid) -Rights 'F'
    $pwFile = Join-Path $env:TEMP ('pg-{0}.tmp' -f [guid]::NewGuid())
    Write-Utf8NoBom -Path $pwFile -Content $SuperPassword
    try {
        Invoke-Native -FilePath (Join-Path $Paths.PgBin 'initdb.exe') -ArgumentList @(
            '-D', ('"{0}"' -f $Paths.PgData), '-U', 'postgres', ('--pwfile="{0}"' -f $pwFile),
            '-E', 'UTF8', '--locale=C', '--auth=scram-sha-256', '--data-checksums'
        ) -LogFile (Join-Path $Paths.Logs 'initdb.log') | Out-Null
    }
    finally { Remove-Item $pwFile -Force -ErrorAction SilentlyContinue }
}

function Set-PgTuning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings
    )
    $tuning = Get-TuningProfile -Name $Settings.RamProfile
    $content = ConvertTo-PostgresTuningConf -Tuning $tuning -Port $Settings.PgPort -Ssd ([bool]$Settings.Ssd) -ProfileName $Settings.RamProfile
    Write-Utf8NoBom -Path (Join-Path $Paths.PgData 'odoo-tuning.conf') -Content $content
    $main = Join-Path $Paths.PgData 'postgresql.conf'
    $text = Get-Content -Raw $main
    if ($text -notmatch "include_if_exists\s*=\s*'odoo-tuning.conf'") {
        Add-Content -Path $main -Value "`r`n# Odoo-Setup-Scripts tuning (keep this line last)`r`ninclude_if_exists = 'odoo-tuning.conf'" -Encoding ASCII
    }
    Write-Ok ('PostgreSQL tuned for {0} RAM ({1})' -f $Settings.RamProfile, $(if ($Settings.Ssd) { 'SSD' } else { 'HDD' }))
}

function Install-PgService {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths, [Parameter(Mandatory)][int]$Port)
    $svc = Get-Service -Name $script:PgServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Invoke-Native -FilePath (Join-Path $Paths.PgBin 'pg_ctl.exe') -ArgumentList @(
            'register', '-N', $script:PgServiceName, '-U', ('"{0}"' -f (Get-NetworkServiceAccountName)),
            '-D', ('"{0}"' -f $Paths.PgData), '-S', 'auto'
        ) | Out-Null
        & sc.exe description $script:PgServiceName 'PostgreSQL database for Odoo (Odoo-Setup-Scripts)' | Out-Null
        & sc.exe failure $script:PgServiceName reset= 3600 actions= restart/10000/restart/30000/restart/60000 | Out-Null
    }
    Start-ServiceSafe -Name $script:PgServiceName
    if (-not (Wait-TcpPort -Port $Port -TimeoutSeconds 60)) {
        throw ('PostgreSQL did not start on port {0}. See {1}\log' -f $Port, $Paths.PgData)
    }
}

function Start-ServiceSafe {
    param([Parameter(Mandatory)][string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { throw ('Service {0} is not installed.' -f $Name) }
    if ($svc.Status -ne 'Running') {
        Start-Service -Name $Name
        $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(90))
    }
}

function Stop-ServiceSafe {
    param([Parameter(Mandatory)][string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Stop-Service -Name $Name -Force
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
    }
}

function Invoke-Psql {
    <# Runs SQL as the given role and returns trimmed output. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$Sql,
        [string]$Database = 'postgres'
    )
    $old = $env:PGPASSWORD
    $env:PGPASSWORD = $Password
    $ErrorActionPreference = 'Continue'   # psql notices on stderr must not throw
    try {
        $out = & (Join-Path $Paths.PgBin 'psql.exe') -h 127.0.0.1 -p $Port -U $User -d $Database -v ON_ERROR_STOP=1 -tAc $Sql 2>&1
        if ($LASTEXITCODE -ne 0) { throw ('psql failed: {0}' -f ($out -join ' ')) }
        return (($out | Out-String).Trim())
    }
    finally { $env:PGPASSWORD = $old }
}

function Set-PgOdooRole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$SuperPassword,
        [Parameter(Mandatory)][string]$OdooPassword
    )
    # Passwords are alphanumeric (New-RandomPassword), so they are safe as SQL literals.
    $sql = "DO `$`$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='odoo') THEN " +
           "CREATE ROLE odoo LOGIN CREATEDB PASSWORD '$OdooPassword'; " +
           "ELSE ALTER ROLE odoo LOGIN CREATEDB PASSWORD '$OdooPassword'; END IF; END`$`$;"
    Invoke-Psql -Paths $Paths -Port $Port -User 'postgres' -Password $SuperPassword -Sql $sql | Out-Null
    Write-Ok 'Database role "odoo" ready (no superuser rights).'
}

function Get-OdooDatabaseState {
    <# Returns 'missing', 'partial' (created but base not installed) or 'ready'. #>
    param($Paths, [int]$Port, [string]$Password, [string]$DbName)
    if (-not (Test-DatabaseExists -Paths $Paths -Port $Port -Password $Password -DbName $DbName)) { return 'missing' }
    try {
        $r = Invoke-Psql -Paths $Paths -Port $Port -User 'odoo' -Password $Password -Database $DbName `
            -Sql "SELECT state FROM ir_module_module WHERE name = 'base'"
        if ($r -eq 'installed') { return 'ready' }
    }
    catch { Write-Verbose $_ }
    return 'partial'
}

function Remove-OdooDatabase {
    param($Paths, [int]$Port, [string]$SuperPassword, [string]$DbName)
    Invoke-Psql -Paths $Paths -Port $Port -User 'postgres' -Password $SuperPassword `
        -Sql ("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='{0}'" -f $DbName) | Out-Null
    Invoke-Psql -Paths $Paths -Port $Port -User 'postgres' -Password $SuperPassword -Sql ('DROP DATABASE IF EXISTS "{0}"' -f $DbName) | Out-Null
    $fs = Join-Path $Paths.Data ('filestore\' + $DbName)
    if (Test-Path $fs) { Remove-Item $fs -Recurse -Force }
}

function Test-DatabaseExists {
    param($Paths, [int]$Port, [string]$Password, [string]$DbName)
    try {
        $r = Invoke-Psql -Paths $Paths -Port $Port -User 'odoo' -Password $Password -Sql ("SELECT 1 FROM pg_database WHERE datname='{0}'" -f $DbName)
        return ($r -eq '1')
    }
    catch { return $false }
}

# ----------------------------------------------------------- wkhtmltopdf ---

function Test-Wkhtmltopdf { param($Paths) return (Test-Path (Join-Path $Paths.WkhtmlBin 'wkhtmltopdf.exe')) }

function Install-Wkhtmltopdf {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths, [Parameter(Mandatory)][System.Collections.IDictionary]$Components)
    $c = $Components.Wkhtmltopdf
    $exe = Invoke-Download -Url $c.Url -Destination (Join-Path $Paths.Downloads (Get-CachedFileName $c.Url)) -Sha256 $c.Sha256
    # NSIS: /D must be last and unquoted.
    Invoke-Native -FilePath $exe -ArgumentList @('/S', ('/D={0}' -f $Paths.Wkhtml)) | Out-Null
    if (-not (Test-Wkhtmltopdf $Paths)) { throw 'wkhtmltopdf.exe not found after installation.' }
}

# ------------------------------------------------------------------ odoo ---

function Test-SourceTree {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Branch)
    $marker = Join-Path $Path '.oss-branch'
    return ((Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq $Branch))
}

function Install-SourceTree {
    <# Downloads a GitHub branch archive and puts its single top folder at Destination. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$CacheFile,
        [switch]$Refresh
    )
    $zip = Invoke-Download -Url $Url -Destination $CacheFile -NoResume:$false -Refresh:$Refresh
    $parent = Split-Path $Destination -Parent
    $tmp = Join-Path $parent ('_extract_{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        Expand-Zip -Path $zip -Destination $tmp
        $top = @(Get-ChildItem $tmp -Directory)
        if ($top.Count -ne 1) { throw ('Unexpected archive layout in {0}' -f $zip) }
        if (Test-Path $Destination) {
            $old = $Destination + '.old'
            Remove-Item $old -Recurse -Force -ErrorAction SilentlyContinue
            Rename-Item $Destination (Split-Path $old -Leaf)
        }
        Move-Item $top[0].FullName $Destination
        Set-Content -Path (Join-Path $Destination '.oss-branch') -Value $Branch -Encoding ASCII
        Remove-Item ($Destination + '.old') -Recurse -Force -ErrorAction SilentlyContinue
    }
    finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Install-OdooSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Components,
        [Parameter(Mandatory)][string]$Version,
        [switch]$Refresh
    )
    Write-Info 'Odoo source is a large download (about 300-500 MB). Please be patient.'
    Install-SourceTree -Url ($Components.OdooSourceUrl -f $Version) -Destination $Paths.OdooSrc -Branch $Version `
        -CacheFile (Join-Path $Paths.Downloads ('odoo-{0}.zip' -f $Version)) -Refresh:$Refresh
    if (-not (Test-Path $Paths.OdooBin)) { throw 'odoo-bin not found after extraction.' }
}

function Get-RequirementsStamp {
    param([string[]]$Files)
    $parts = foreach ($f in $Files) { if (Test-Path $f) { (Get-FileHash -Algorithm SHA256 $f).Hash } }
    return ($parts -join '-')
}

function Invoke-Pip {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths, [Parameter(Mandatory)][string[]]$PipArgs, [string]$LogName = 'pip')
    $env:PIP_CACHE_DIR = Join-Path $Paths.Downloads 'pip-cache'
    $env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
    $all = @('-m', 'pip') + $PipArgs
    Invoke-Native -FilePath $Paths.VenvPython -ArgumentList $all -LogFile (Join-Path $Paths.Logs ($LogName + '.log')) | Out-Null
}

function Test-OdooVenv {
    param($Paths, [string]$Mode)
    $stampFile = Join-Path $Paths.Venv '.oss-requirements'
    if (-not (Test-Path $Paths.VenvPython) -or -not (Test-Path $stampFile)) { return $false }
    $want = (Get-RequirementsStamp @((Join-Path $Paths.OdooSrc 'requirements.txt'))) + '|' + $Mode
    return ((Get-Content $stampFile -Raw).Trim() -eq $want)
}

function Install-OdooVenv {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths, [Parameter(Mandatory)][string]$Mode, [switch]$Rebuild)
    if ($Rebuild -and (Test-Path $Paths.Venv)) { Remove-Item $Paths.Venv -Recurse -Force }
    if (-not (Test-Path $Paths.VenvPython)) {
        Write-Info 'Creating virtual environment...'
        Invoke-Native -FilePath $Paths.PythonExe -ArgumentList @('-m', 'venv', ('"{0}"' -f $Paths.Venv)) | Out-Null
    }
    Write-Info 'Upgrading pip...'
    Invoke-Pip -Paths $Paths -PipArgs @('install', '--upgrade', 'pip', 'wheel', 'setuptools') -LogName 'pip-bootstrap'
    Write-Info 'Installing Odoo Python requirements (binary wheels, a few minutes)...'
    $req = Join-Path $Paths.OdooSrc 'requirements.txt'
    Invoke-Pip -Paths $Paths -PipArgs @('install', '--prefer-binary', '-r', ('"{0}"' -f $req)) -LogName 'pip-odoo'
    if ($Mode -eq 'dev') {
        Invoke-Pip -Paths $Paths -PipArgs @('install', '--prefer-binary', 'watchdog') -LogName 'pip-dev'
    }
    $stamp = (Get-RequirementsStamp @($req)) + '|' + $Mode
    Set-Content -Path (Join-Path $Paths.Venv '.oss-requirements') -Value $stamp -Encoding ASCII
}

function Install-OcaRepos {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Components,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Repos,
        [switch]$Refresh
    )
    New-Item -ItemType Directory -Path $Paths.OcaDir -Force | Out-Null
    foreach ($repo in $Repos) {
        $dest = Join-Path $Paths.OcaDir $repo
        if (-not $Refresh -and (Test-SourceTree -Path $dest -Branch $Version)) { Write-Skip ('OCA/{0} already present' -f $repo); continue }
        Write-Info ('OCA/{0} ({1})' -f $repo, $Version)
        try {
            Install-SourceTree -Url ($Components.OcaSourceUrl -f $repo, $Version) -Destination $dest -Branch $Version `
                -CacheFile (Join-Path $Paths.Downloads ('oca-{0}-{1}.zip' -f $repo, $Version)) -Refresh:$Refresh
        }
        catch { Write-Warn ('OCA/{0} has no {1} branch or could not be downloaded; its modules will be skipped.' -f $repo, $Version); continue }
        $req = Join-Path $dest 'requirements.txt'
        if (Test-Path $req) {
            try { Invoke-Pip -Paths $Paths -PipArgs @('install', '--prefer-binary', '-r', ('"{0}"' -f $req)) -LogName ('pip-oca-' + $repo) }
            catch { Write-Warn ('Some Python packages for OCA/{0} failed to install; see logs\pip-oca-{0}.log' -f $repo) }
        }
    }
}

function Get-AddonsPathList {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths)
    $list = @((Join-Path $Paths.OdooSrc 'addons'))
    if (Test-Path $Paths.OcaDir) {
        $list += @(Get-ChildItem $Paths.OcaDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName '.oss-branch') } |
            Sort-Object Name | ForEach-Object { $_.FullName })
    }
    New-Item -ItemType Directory -Path $Paths.CustomDir -Force | Out-Null
    $list += $Paths.CustomDir
    return $list
}

function Get-AvailableModules {
    param([Parameter(Mandatory)][string[]]$AddonsPath)
    $names = foreach ($dir in $AddonsPath) {
        if (Test-Path $dir) {
            Get-ChildItem $dir -Directory | Where-Object { Test-Path (Join-Path $_.FullName '__manifest__.py') } | ForEach-Object { $_.Name }
        }
    }
    return @($names | Sort-Object -Unique)
}

function Write-OdooConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Secrets
    )
    foreach ($d in @($Paths.Data, $Paths.Logs, $Paths.Tools, $Paths.Conf)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $conf = New-OdooConfSettings -Mode $Settings.Mode -Version $Settings.OdooVersion `
        -Tuning (Get-TuningProfile -Name $Settings.RamProfile) -AddonsPath (Get-AddonsPathList $Paths) `
        -DataDir $Paths.Data -DbPassword $Secrets.OdooDbPassword -MasterPassword $Secrets.MasterPassword `
        -DbPort $Settings.PgPort -HttpPort $Settings.HttpPort -DbName $Settings.DbName `
        -PgPath $Paths.PgBin -BinPath $Paths.WkhtmlBin -WithDemo ([bool]$Settings.WithDemo)
    Write-Utf8NoBom -Path $Paths.OdooConf -Content (ConvertTo-OdooConf $conf)

    # Service account: write data + logs, read config. Config folder holds secrets.
    Grant-FolderAccess -Path $Paths.Data -Sid $SidNetworkService -Rights 'M'
    Grant-FolderAccess -Path $Paths.Logs -Sid $SidNetworkService -Rights 'M'
    # conf\ holds secrets.json and CREDENTIALS.txt: admins only. The service may read odoo.conf alone.
    Protect-Folder -Path $Paths.Conf
    Grant-FileRead -Path $Paths.OdooConf -Sid $SidNetworkService
    Write-Ok ('Wrote {0}' -f $Paths.OdooConf)
}

function Invoke-OdooBin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][string[]]$OdooArgs,
        [Parameter(Mandatory)][string]$LogName,
        [string]$StdinFile = ''
    )
    # The launcher drops PG*/ODOO_* variables, which Odoo 19 would prefer over odoo.conf.
    $launcher = Join-Path $PSScriptRoot '..\scripts\odoo-launch.py'
    $all = @(('"{0}"' -f $launcher), ('"{0}"' -f $Paths.OdooBin)) + $OdooArgs
    if ($env:PATH -notlike ('*' + $Paths.WkhtmlBin + '*')) { $env:PATH = $Paths.WkhtmlBin + ';' + $Paths.PgBin + ';' + $env:PATH }
    $env:PYTHONUTF8 = '1'
    Invoke-Native -FilePath $Paths.VenvPython -ArgumentList $all -WorkingDirectory $Paths.OdooSrc `
        -LogFile (Join-Path $Paths.Logs ($LogName + '.log')) -StdinFile $StdinFile | Out-Null
}

function New-OdooDatabase {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    Write-Info ('Creating database "{0}" with Arabic and English...' -f $Settings.DbName)
    $odooArgs = @('-c', ('"{0}"' -f $Paths.OdooConf), '-d', $Settings.DbName, '-i', 'base', '--load-language=ar_001', '--no-http', '--stop-after-init')
    $odooArgs += Get-DemoArguments -Version $Settings.OdooVersion -WithDemo ([bool]$Settings.WithDemo)
    Invoke-OdooBin -Paths $Paths -OdooArgs $odooArgs -LogName 'odoo-create-db'
}

function Set-OdooCompanyDefaults {
    <# Egypt, EGP, Africa/Cairo, admin login/password/language via odoo-bin shell. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Secrets
    )
    Invoke-OdooShellScript -Paths $Paths -DbName $Settings.DbName -ScriptName 'company_setup.py' -Environment @{
        OSS_COMPANY_NAME = $Settings.CompanyName; OSS_ADMIN_LOGIN = $Settings.AdminLogin
        OSS_ADMIN_PASSWORD = $Secrets.AdminPassword; OSS_LANG = $Settings.UiLanguage; OSS_TZ = 'Africa/Cairo'
    }
}

function Invoke-OdooShellScript {
    <# Runs a Python file from scripts\ inside "odoo-bin shell" and checks it printed its OK marker. #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][string]$DbName,
        [Parameter(Mandatory)][string]$ScriptName,
        [hashtable]$Environment = @{}
    )
    $scriptFile = Join-Path $Paths.Tools $ScriptName
    Copy-Item (Join-Path $PSScriptRoot ('..\scripts\' + $ScriptName)) $scriptFile -Force
    $logName = 'odoo-' + [IO.Path]::GetFileNameWithoutExtension($ScriptName)
    foreach ($k in $Environment.Keys) { Set-Item -Path ('env:' + $k) -Value ([string]$Environment[$k]) }
    try {
        Invoke-OdooBin -Paths $Paths -OdooArgs @('shell', '-c', ('"{0}"' -f $Paths.OdooConf), '-d', $DbName, '--no-http') `
            -LogName $logName -StdinFile $scriptFile
    }
    finally { foreach ($k in $Environment.Keys) { Remove-Item -Path ('env:' + $k) -ErrorAction SilentlyContinue } }
    $log = Join-Path $Paths.Logs ($logName + '.log')
    if (-not (Select-String -Path $log -Pattern 'OSS_SETUP_OK' -Quiet)) { throw ('{0} did not finish. See {1}' -f $ScriptName, $log) }
}

function Install-OdooModules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Modules
    )
    $available = Get-AvailableModules -AddonsPath (Get-AddonsPathList $Paths)
    $split = Split-ModulesByAvailability -Modules $Modules -AvailableModules $available
    foreach ($m in $split.Missing) { Write-Warn ('Module {0} is not available for Odoo {1}, skipped.' -f $m, $Settings.OdooVersion) }
    if ($split.Present.Count -eq 0) { Write-Skip 'No modules to install.'; return }
    Write-Info ('Installing {0} modules: {1}' -f $split.Present.Count, ($split.Present -join ', '))
    Write-Info 'This can take 5-15 minutes on a 4 GB machine.'
    $odooArgs = @('-c', ('"{0}"' -f $Paths.OdooConf), '-d', $Settings.DbName, '-i', ($split.Present -join ','), '--no-http', '--stop-after-init')
    $odooArgs += Get-DemoArguments -Version $Settings.OdooVersion -WithDemo ([bool]$Settings.WithDemo)
    Invoke-OdooBin -Paths $Paths -OdooArgs $odooArgs -LogName 'odoo-install-modules'
    if ($split.Present -contains 'account') {
        # Make sure the Egyptian chart of accounts is loaded even if auto-detection did not run.
        Invoke-OdooShellScript -Paths $Paths -DbName $Settings.DbName -ScriptName 'post_install.py'
    }
}

# --------------------------------------------------------------- service ---

function ConvertTo-XmlText { param([string]$Text) return [System.Security.SecurityElement]::Escape($Text) }

function Install-OdooService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Components
    )
    $c = $Components.WinSW
    $winsw = Invoke-Download -Url $c.Url -Destination (Join-Path $Paths.Downloads 'WinSW-x64.exe') -Sha256 $c.Sha256
    $exe = Join-Path $Paths.Tools 'odoo-service.exe'
    $xml = Join-Path $Paths.Tools 'odoo-service.xml'

    if (Get-Service -Name $script:OdooServiceName -ErrorAction SilentlyContinue) {
        Stop-ServiceSafe -Name $script:OdooServiceName
        if (Test-Path $exe) { & $exe uninstall | Out-Null } else { & sc.exe delete $script:OdooServiceName | Out-Null }
        Start-Sleep -Seconds 2
    }
    Copy-Item $winsw $exe -Force
    $launcher = Join-Path $Paths.Tools 'odoo-launch.py'
    Copy-Item (Join-Path $PSScriptRoot '..\scripts\odoo-launch.py') $launcher -Force

    $pathValue = ConvertTo-XmlText ($Paths.WkhtmlBin + ';' + $Paths.PgBin + ';%PATH%')
    $arguments = Get-OdooServiceArguments -OdooBin $Paths.OdooBin -ConfigFile $Paths.OdooConf -Mode $Settings.Mode
    $arguments = '"{0}" {1}' -f $launcher, $arguments
    $content = @"
<service>
  <id>$($script:OdooServiceName)</id>
  <name>Odoo $($Settings.OdooVersion)</name>
  <description>Odoo $($Settings.OdooVersion) ($($Settings.Mode)) managed by Odoo-Setup-Scripts</description>
  <executable>$(ConvertTo-XmlText $Paths.VenvPython)</executable>
  <arguments>$(ConvertTo-XmlText $arguments)</arguments>
  <workingdirectory>$(ConvertTo-XmlText $Paths.OdooSrc)</workingdirectory>
  <env name="PATH" value="$pathValue"/>
  <env name="PYTHONUNBUFFERED" value="1"/>
  <env name="PYTHONUTF8" value="1"/>
  <stoptimeout>20 sec</stoptimeout>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <onfailure action="restart" delay="60 sec"/>
  <resetfailure>1 hour</resetfailure>
  <logpath>$(ConvertTo-XmlText $Paths.Logs)</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>8</keepFiles>
  </log>
</service>
"@
    Write-Utf8NoBom -Path $xml -Content $content
    Invoke-Native -FilePath $exe -ArgumentList @('install') | Out-Null

    # Run as NetworkService instead of LocalSystem.
    $svc = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $script:OdooServiceName)
    $r = Invoke-CimMethod -InputObject $svc -MethodName Change -Arguments @{ StartName = (Get-NetworkServiceAccountName); StartPassword = '' }
    if ($r.ReturnValue -ne 0) { Write-Warn ('Could not switch the service account (code {0}); it runs as LocalSystem.' -f $r.ReturnValue) }

    $startType = 'demand'
    if ($Settings.Mode -eq 'prod') { $startType = 'auto' }   # starts right after PostgreSQL, before anyone logs in
    & sc.exe config $script:OdooServiceName start= $startType | Out-Null
    & sc.exe config $script:OdooServiceName depend= $script:PgServiceName | Out-Null

    Start-ServiceSafe -Name $script:OdooServiceName
    Write-Info 'Waiting for Odoo to answer...'
    if (-not (Test-OdooHttp -Port $Settings.HttpPort -TimeoutSeconds 180)) {
        throw ('Odoo did not answer on port {0}. See {1}\odoo-service.err.log' -f $Settings.HttpPort, $Paths.Logs)
    }
}

function Test-OdooHttp {
    param([int]$Port = 8069, [int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri ('http://127.0.0.1:{0}/web/login' -f $Port) -UseBasicParsing -TimeoutSec 15
            if ($r.StatusCode -eq 200) { return $true }
        }
        catch { Start-Sleep -Seconds 3 }
    }
    return $false
}

# ------------------------------------------------------------ os tweaks ----

function Set-OdooFirewallRule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Port)
    Get-NetFirewallRule -Name $script:FirewallRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Name $script:FirewallRuleName -DisplayName ('Odoo (TCP {0})' -f $Port) -Direction Inbound `
        -Protocol TCP -LocalPort $Port -Action Allow -Profile Domain, Private | Out-Null
    $public = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.NetworkCategory -eq 'Public' })
    if ($public.Count -gt 0) {
        Write-Warn ('Network "{0}" is set to Public, so other PCs cannot reach Odoo.' -f $public[0].Name)
        Write-Warn 'Switch it to Private in Settings > Network, or re-run setup and accept the prompt.'
    }
}

function Remove-OdooFirewallRule {
    Get-NetFirewallRule -Name $script:FirewallRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
}

function Set-DefenderExclusions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths, [switch]$Remove)
    $folders = @($Paths.PgData, $Paths.Data)
    $procs = @((Join-Path $Paths.PgBin 'postgres.exe'))
    try {
        if ($Remove) { Remove-MpPreference -ExclusionPath $folders -ExclusionProcess $procs -ErrorAction Stop }
        else { Add-MpPreference -ExclusionPath $folders -ExclusionProcess $procs -ErrorAction Stop }
        return $true
    }
    catch { Write-Warn 'Windows Defender is not active or managed by another antivirus; skipped.'; return $false }
}

function Disable-SleepOnAC {
    & powercfg.exe /change standby-timeout-ac 0 | Out-Null
    & powercfg.exe /change hibernate-timeout-ac 0 | Out-Null
}

function New-OdooShortcut {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Port, [string]$Name = 'Odoo')
    $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $lnk = Join-Path $desktop ($Name + '.lnk')
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($lnk)
    $chrome = Find-Chrome
    if ($chrome) {
        $sc.TargetPath = $chrome
        $sc.Arguments = ('--app=http://localhost:{0}/web' -f $Port)
        $sc.IconLocation = $chrome + ',0'
    }
    else {
        $sc.TargetPath = ('http://localhost:{0}/web' -f $Port)
    }
    $sc.Description = 'Open Odoo'
    $sc.Save()
    return $lnk
}

function Remove-OdooShortcut {
    $lnk = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Odoo.lnk'
    Remove-Item $lnk -Force -ErrorAction SilentlyContinue
}

function Copy-OdooTools {
    <# Copies the runtime helpers so they keep working after the setup folder is deleted. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths)
    New-Item -ItemType Directory -Path $Paths.Tools -Force | Out-Null
    $root = Split-Path $PSScriptRoot -Parent
    Copy-Item (Join-Path $root 'scripts\backup.ps1') $Paths.Tools -Force
    Copy-Item (Join-Path $root 'scripts\odoo-ctl.ps1') $Paths.Tools -Force
    Copy-Item (Join-Path $root 'lib\OdooSetup.Logic.psm1') $Paths.Tools -Force
}

function Write-CredentialsFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Paths,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Secrets
    )
    $text = @"
Odoo installation credentials - keep this file safe and private.
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')

Odoo URL ............ http://localhost:$($Settings.HttpPort)
Database ............ $($Settings.DbName)
Admin login ......... $($Settings.AdminLogin)
Admin password ...... $($Secrets.AdminPassword)
Master password ..... $($Secrets.MasterPassword)   (database manager / restore)

PostgreSQL port ..... $($Settings.PgPort)
PostgreSQL superuser  postgres / $($Secrets.PgSuperPassword)
Odoo DB role ........ odoo / $($Secrets.OdooDbPassword)
"@
    Write-Utf8NoBom -Path $Paths.Credentials -Content $text
}

# ---------------------------------------------------------------- backup ---

function Register-BackupTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths, [Parameter(Mandatory)][string]$Time)
    $backupScript = Join-Path $Paths.Tools 'backup.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -NonInteractive -File "{0}" -Root "{1}"' -f $backupScript, $Paths.Root)
    $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($Time, 'HH:mm', $null))
    $system = (New-Object System.Security.Principal.SecurityIdentifier($SidSystem)).Translate([System.Security.Principal.NTAccount]).Value
    $principal = New-ScheduledTaskPrincipal -UserId $system -LogonType ServiceAccount -RunLevel Highest
    # StartWhenAvailable: if the PC was off at backup time, run as soon as it is back on.
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 4) -MultipleInstances IgnoreNew -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName $script:BackupTaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Daily Odoo database + filestore backup (Odoo-Setup-Scripts)' -Force | Out-Null
}

function Unregister-BackupTask {
    if (Get-ScheduledTask -TaskName $script:BackupTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:BackupTaskName -Confirm:$false
    }
}

Export-ModuleMember -Function *
