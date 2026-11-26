<#
.SYNOPSIS
  Builds a reseller package: one ZIP that installs Odoo on a client PC with no questions.

.DESCRIPTION
  Copy config\answers.example.psd1, fill it in for the client, then run:
    powershell -ExecutionPolicy Bypass -File .\reseller\New-ResellerPackage.ps1 -AnswersFile .\client-answers.psd1

  The answers file is checked first (unknown settings, database name, backup
  folder, business hours...). The ZIP holds the installer, the answers file as
  answers.psd1, and install-unattended.cmd. On the client PC: extract the ZIP
  and double-click install-unattended.cmd. Runs on Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER AnswersFile
  The client's answers file (.psd1).

.PARAMETER OutputDir
  Where to write the ZIP. Default: dist\ in the repository.

.PARAMETER Name
  Short name used in the ZIP file name. Default: the database name from the answers file.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AnswersFile,
    [string]$OutputDir = '',
    [string]$Name = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'lib/OdooSetup.Logic.psm1') -Force -DisableNameChecking

$AnswersFile = (Resolve-Path $AnswersFile).Path
$answers = Import-PowerShellDataFile $AnswersFile
$components = Import-PowerShellDataFile (Join-Path $repo 'config/components.psd1')
$catalog = Import-PowerShellDataFile (Join-Path $repo 'config/addons.psd1')

$problems = @(Get-AnswersProblems -Answers $answers -OdooVersions ([string[]]$components.OdooVersions) `
        -AppKeys ([string[]]@($catalog.Apps | ForEach-Object { $_.Key })) -BundleKeys ([string[]]@($catalog.OcaBundles | ForEach-Object { $_.Key })))
if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host ('  x ' + $p) -ForegroundColor Red }
    throw ('{0} problem(s) in {1}. Fix them and run again.' -f $problems.Count, $AnswersFile)
}
if ($answers.Contains('AdminPassword') -and $answers.AdminPassword) {
    Write-Warning 'AdminPassword is set, so it travels inside the ZIP in plain text. Leave it empty to generate one on the client PC (saved in conf\CREDENTIALS.txt).'
}
if ($answers.Contains('Mode') -and $answers.Mode -eq 'dev') {
    Write-Warning 'Mode is "dev": no backups, no LAN access and no health check. Use "prod" for a client.'
}

if (-not $Name) { $Name = [string]$answers.DbName }
$Name = ($Name -replace '[^A-Za-z0-9_.-]', '_')
if (-not $OutputDir) { $OutputDir = Join-Path $repo 'dist' }
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$folderName = 'OdooSetup-{0}' -f $Name
$zip = Join-Path (Resolve-Path $OutputDir).Path ('{0}-{1}.zip' -f $folderName, (Get-Date -Format 'yyyyMMdd-HHmm'))

$staging = Join-Path ([IO.Path]::GetTempPath()) ('oss-pkg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$pkg = Join-Path $staging $folderName
try {
    New-Item -ItemType Directory -Path $pkg -Force | Out-Null
    foreach ($f in @('setup.ps1', 'install.cmd', 'install-unattended.cmd', 'README.md')) { Copy-Item (Join-Path $repo $f) $pkg }
    foreach ($d in @('lib', 'config', 'scripts')) { Copy-Item (Join-Path $repo $d) $pkg -Recurse }
    Copy-Item $AnswersFile (Join-Path $pkg 'answers.psd1')

    $company = [string]$answers.CompanyName
    $readme = @(
        ('Odoo installer for {0}' -f $company),
        ('Built {0} from Odoo-Setup-Scripts.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm')),
        '',
        '1. Extract this ZIP to a folder on the client PC (not inside the ZIP viewer).',
        '2. Double-click install-unattended.cmd and accept the Administrator prompt.',
        '3. Wait. There are no questions. It takes 20-60 minutes, mostly downloads.',
        '4. Passwords are written to conf\CREDENTIALS.txt in the install folder (C:\Odoo by default).',
        '',
        'If it stops (power cut, no internet), run install-unattended.cmd again: finished steps are skipped.',
        'The answers used are in answers.psd1. install.cmd starts the normal interactive setup instead.'
    )
    Set-Content -Path (Join-Path $pkg 'READ-ME-FIRST.txt') -Value $readme -Encoding ASCII

    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path $pkg -DestinationPath $zip
}
finally { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ('Package ready: {0}' -f $zip) -ForegroundColor Green
return $zip
