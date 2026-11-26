# Core helpers: logging, state (resume), downloads, process execution,
# secrets and file permissions. Windows PowerShell 5.1 compatible.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'OdooSetup.UI.psm1') -Global -DisableNameChecking

$script:StateFile = $null

# Well-known SIDs, so we never depend on the Windows display language
# (account names are translated on Arabic Windows).
$script:SidNetworkService = 'S-1-5-20'
$script:SidAdministrators = 'S-1-5-32-544'
$script:SidSystem = 'S-1-5-18'

function Get-NetworkServiceAccountName {
    $sid = New-Object System.Security.Principal.SecurityIdentifier($script:SidNetworkService)
    return $sid.Translate([System.Security.Principal.NTAccount]).Value
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-SetupLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LogDir, [string]$Prefix = 'setup')
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $path = Join-Path $LogDir ('{0}_{1}.log' -f $Prefix, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try { Start-Transcript -Path $path -Append | Out-Null } catch { Write-Verbose $_ }
    return $path
}

function Stop-SetupLog {
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'No transcript running.' }
}

# ---------------------------------------------------------------- state ----

function Initialize-State {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $script:StateFile = $Path
}

function Get-SetupState {
    if (-not $script:StateFile -or -not (Test-Path $script:StateFile)) { return @{} }
    $obj = Get-Content -Raw -Path $script:StateFile | ConvertFrom-Json
    $h = @{}
    foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Set-StepDone {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StepId)
    $state = Get-SetupState
    $state[$StepId] = (Get-Date).ToString('s')
    $dir = Split-Path $script:StateFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $state | ConvertTo-Json | Set-Content -Path $script:StateFile -Encoding UTF8
}

function Clear-StepDone {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StepId)
    $state = Get-SetupState
    if ($state.ContainsKey($StepId)) {
        $state.Remove($StepId)
        $state | ConvertTo-Json | Set-Content -Path $script:StateFile -Encoding UTF8
    }
}

function Invoke-SetupStep {
    <#
      Runs one idempotent step. Test returns $true when the step is already
      satisfied on this machine (checked every time, not just from state).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$Run,
        [scriptblock]$Test,
        [switch]$Force
    )
    Write-Step $Title
    if (-not $Force -and $Test -and (& $Test)) {
        Write-Skip 'Already done.'
        Set-StepDone $Id
        return
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $Run
    Set-StepDone $Id
    Write-Ok ('Done in {0:N0}s' -f $sw.Elapsed.TotalSeconds)
}

# ------------------------------------------------------------ downloads ----

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}

function Invoke-Download {
    <#
      Downloads to the cache with resume support (curl.exe ships with
      Windows 10 1803+), verifies sha256 when given, and reuses a cached
      file whose hash matches.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [string]$Sha256 = '',
        [switch]$NoResume,
        [switch]$Refresh
    )
    $dir = Split-Path $Destination -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if ((Test-Path $Destination) -and -not $Refresh) {
        if ($Sha256 -and (Get-FileSha256 $Destination) -eq $Sha256.ToLowerInvariant()) {
            Write-Skip ('Using cached {0}' -f (Split-Path $Destination -Leaf)); return $Destination
        }
        if (-not $Sha256 -and (Test-Path ($Destination + '.complete'))) {
            Write-Skip ('Using cached {0}' -f (Split-Path $Destination -Leaf)); return $Destination
        }
    }
    if ($Refresh -or $NoResume) { Remove-Item $Destination, ($Destination + '.complete') -Force -ErrorAction SilentlyContinue }

    Write-Info ('Downloading {0}' -f $Url)
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Test-Path $curl) {
            $curlArgs = @('-L', '--fail', '--retry', '5', '--retry-delay', '3', '--connect-timeout', '30', '-#', '-o', $Destination)
            if (-not $NoResume -and (Test-Path $Destination)) { $curlArgs += @('-C', '-') }
            $curlArgs += $Url
            & $curl @curlArgs
            $code = $LASTEXITCODE
            # 33 = server does not support resume: start over.
            if ($code -eq 33 -or $code -eq 36) { Remove-Item $Destination -Force -ErrorAction SilentlyContinue; continue }
            $ok = ($code -eq 0)
        }
        else {
            $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            try { Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing; $ok = $true }
            catch { $ok = $false } finally { $ProgressPreference = $old }
        }
        if ($ok) {
            if ($Sha256) {
                $actual = Get-FileSha256 $Destination
                if ($actual -ne $Sha256.ToLowerInvariant()) {
                    Write-Warn ('Checksum mismatch (got {0}), retrying' -f $actual)
                    Remove-Item $Destination -Force -ErrorAction SilentlyContinue
                    continue
                }
            }
            Set-Content -Path ($Destination + '.complete') -Value (Get-Date).ToString('s')
            return $Destination
        }
        Write-Warn ('Download attempt {0} failed' -f $attempt)
        Start-Sleep -Seconds (3 * $attempt)
    }
    throw ('Could not download {0}. Check the internet connection and run setup again; it resumes where it stopped.' -f $Url)
}

function Expand-Zip {
    <# Fast extraction with the built-in tar.exe (bsdtar), falling back to Expand-Archive. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$Exclude = @()
    )
    if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path $tar) {
        $tarArgs = @('-x', '-f', $Path, '-C', $Destination)
        foreach ($e in $Exclude) { $tarArgs += @('--exclude', $e) }
        & $tar @tarArgs
        if ($LASTEXITCODE -ne 0) { throw ('tar failed to extract {0}' -f $Path) }
    }
    else {
        Expand-Archive -Path $Path -DestinationPath $Destination -Force
    }
}

# ------------------------------------------------------------ processes ----

function Invoke-Native {
    <#
      Runs an executable, waits, and throws on an unexpected exit code.
      Output is captured to a log file and its tail is shown on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$SuccessCodes = @(0),
        [string]$WorkingDirectory = '',
        [string]$LogFile = '',
        [string]$StdinFile = '',
        [switch]$PassThruOutput
    )
    $params = @{ FilePath = $FilePath; Wait = $true; PassThru = $true; NoNewWindow = $true }
    if ($ArgumentList.Count -gt 0) { $params.ArgumentList = $ArgumentList }
    if ($WorkingDirectory) { $params.WorkingDirectory = $WorkingDirectory }
    if ($StdinFile) { $params.RedirectStandardInput = $StdinFile }
    if ($LogFile) {
        $params.RedirectStandardOutput = $LogFile
        $params.RedirectStandardError = $LogFile + '.err'
    }
    $proc = Start-Process @params
    $code = $proc.ExitCode
    if ($SuccessCodes -notcontains $code) {
        if ($LogFile) {
            foreach ($f in @($LogFile, ($LogFile + '.err'))) {
                if (Test-Path $f) { Get-Content $f -Tail 25 | ForEach-Object { Write-Host ('     ' + $_) -ForegroundColor DarkGray } }
            }
        }
        throw ('{0} failed with exit code {1}' -f (Split-Path $FilePath -Leaf), $code)
    }
    if ($PassThruOutput -and $LogFile -and (Test-Path $LogFile)) { return (Get-Content $LogFile -Raw) }
    return $code
}

# -------------------------------------------------------------- secrets ----

function New-RandomPassword {
    <# Alphanumeric only, so it is safe in odoo.conf, SQL literals and command lines. #>
    [CmdletBinding()]
    param([int]$Length = 24)
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'.ToCharArray()
    $bytes = New-Object byte[] ($Length)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) { [void]$sb.Append($chars[$b % $chars.Length]) }
    return $sb.ToString()
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $obj = Get-Content -Raw -Path $Path -Encoding UTF8 | ConvertFrom-Json
    return ConvertTo-Hashtable $obj
}

function ConvertTo-Hashtable {
    <# Recursively converts ConvertFrom-Json output to hashtables (PS 5.1 has no -AsHashtable). #>
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return , @($InputObject | ForEach-Object { ConvertTo-Hashtable $_ })
    }
    return $InputObject
}

function Write-JsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Data)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Data | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding UTF8
}

function Write-Utf8NoBom {
    <# Odoo and PostgreSQL configs must not start with a BOM. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

# ---------------------------------------------------------- permissions ----

function Grant-FolderAccess {
    <#
      Grants a SID inheritable rights on a folder (M = modify, F = full, RX = read).
      icacls propagates the inheritable entry to existing children, so no /T
      (which would stamp an explicit entry on every file of a large filestore).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Sid, [string]$Rights = 'M')
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    & icacls.exe $Path /grant ('*{0}:(OI)(CI){1}' -f $Sid, $Rights) /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('icacls could not grant access on {0}' -f $Path) }
}

function Grant-FileRead {
    <# Grants a SID read access to a single file. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Sid)
    & icacls.exe $Path /grant ('*{0}:R' -f $Sid) /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('icacls could not grant read access on {0}' -f $Path) }
}

function Get-CurrentUserSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Protect-Folder {
    <# Removes inherited access: only Administrators, SYSTEM and optional extra SIDs can read. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string[]]$ReadSids = @())
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $grants = @('/grant:r', ('*{0}:(OI)(CI)F' -f $script:SidAdministrators), ('*{0}:(OI)(CI)F' -f $script:SidSystem))
    foreach ($sid in $ReadSids) { $grants += ('*{0}:(OI)(CI)RX' -f $sid) }
    # Children re-inherit from the new folder ACL; explicit per-file grants are kept.
    & icacls.exe $Path /inheritance:r @grants /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('icacls could not protect {0}' -f $Path) }
}

# --------------------------------------------------------------- system ----

function Get-UsedTcpPorts {
    try { return @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Select-Object -ExpandProperty LocalPort -Unique) }
    catch { return @() }
}

function Get-TotalMemoryGB {
    $bytes = (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
    return [Math]::Round($bytes / 1GB, 1)
}

function Test-SystemDiskIsSsd {
    param([string]$DriveLetter = $env:SystemDrive.TrimEnd(':'))
    try {
        $disk = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop | Get-Disk
        $pd = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq [string]$disk.Number } | Select-Object -First 1
        if ($pd -and $pd.MediaType -eq 'HDD') { return $false }
        return $true
    }
    catch { return $true }
}

function Get-FixedDrives {
    <# Fixed local drives with free space, system drive last. #>
    $drives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        [pscustomobject]@{
            Letter  = $_.DeviceID
            Label   = $_.VolumeName
            FreeGB  = [Math]::Round($_.FreeSpace / 1GB, 1)
            SizeGB  = [Math]::Round($_.Size / 1GB, 1)
            IsSystem = ($_.DeviceID -eq $env:SystemDrive)
        }
    }
    return @($drives | Sort-Object -Property IsSystem, Letter)
}

function Get-LanAddresses {
    try {
        return @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
            Select-Object -ExpandProperty IPAddress)
    }
    catch { return @() }
}

function Wait-TcpPort {
    param([Parameter(Mandatory)][int]$Port, [int]$TimeoutSeconds = 60, [string]$HostName = '127.0.0.1')
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $client = New-Object System.Net.Sockets.TcpClient
        try { $client.Connect($HostName, $Port); return $true }
        catch { Start-Sleep -Milliseconds 700 }
        finally { $client.Dispose() }
    }
    return $false
}

Export-ModuleMember -Function * -Variable SidNetworkService, SidAdministrators, SidSystem
