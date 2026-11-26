<#
  One-line installer. In an Administrator PowerShell window:

    irm https://raw.githubusercontent.com/BishoyGH/Odoo-Setup-Scripts/main/bootstrap.ps1 | iex

  Downloads this repository (no Git needed) and starts setup.ps1.
#>
& {
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $branch = if ($env:ODOO_SETUP_BRANCH) { $env:ODOO_SETUP_BRANCH } else { 'main' }
    $url = 'https://codeload.github.com/BishoyGH/Odoo-Setup-Scripts/zip/refs/heads/' + $branch
    $work = Join-Path $env:TEMP ('odoo-setup-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $zip = Join-Path $work 'setup.zip'
    Write-Host 'Downloading Odoo-Setup-Scripts...' -ForegroundColor Cyan
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $work -Force
    $folder = Get-ChildItem $work -Directory | Select-Object -First 1
    $setup = Join-Path $folder.FullName 'setup.ps1'

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup
    }
    else {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $setup))
    }
}
