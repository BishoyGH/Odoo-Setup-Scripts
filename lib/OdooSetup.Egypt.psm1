# Egypt-specific install helpers: Arabic fonts for PDF reports and the
# ETA e-invoicing USB token check. Pure helpers come first so they can be unit-tested on Linux.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'OdooSetup.UI.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'OdooSetup.Core.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'OdooSetup.Steps.psm1') -Global -DisableNameChecking

# Odoo's ETA signer (iot_drivers/l10n_eg_drivers.py) loads this exact PKCS#11 library on Windows.
# It is installed by the ePass2003 token driver that Egyptian certificate providers hand out.
$script:EtaPkcs11Dll = 'eps2003csp11.dll'

$script:FontsRegistryKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

# ---------------------------------------------------------------- pure -----

function Get-FontRegistryValueName {
    <# Registry value name Windows uses for a TrueType font, e.g. 'Noto Naskh Arabic Bold (TrueType)'. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Family, [string]$Style = 'Regular')
    $name = $Family
    if ($Style -and $Style -ne 'Regular') { $name = $Family + ' ' + $Style }
    return ($name + ' (TrueType)')
}

function Get-ArabicFontList {
    <# Flattens the ArabicFonts manifest entry into one record per font file. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Components)
    if (-not $Components.Contains('ArabicFonts')) { return @() }
    $base = $Components.ArabicFonts.BaseUrl
    return @(foreach ($f in $Components.ArabicFonts.Files) {
            [ordered]@{
                Family       = $f.Family
                Style        = $f.Style
                FileName     = Split-Path $f.Path -Leaf
                Url          = $base + $f.Path
                Sha256       = $f.Sha256
                RegistryName = (Get-FontRegistryValueName -Family $f.Family -Style $f.Style)
            }
        })
}

function Get-ManifestDepends {
    <# Module names listed under 'depends' in an Odoo __manifest__.py. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ManifestText)
    $m = [regex]::Match($ManifestText, '["'']depends["'']\s*:\s*\[([^\]]*)\]')
    if (-not $m.Success) { return @() }
    return @([regex]::Matches($m.Groups[1].Value, '["'']([A-Za-z0-9_]+)["'']') | ForEach-Object { $_.Groups[1].Value })
}

function Find-EtaTokenMiddleware {
    <# Returns the path of the ePass2003 PKCS#11 library if the token driver is installed, else ''. #>
    [CmdletBinding()]
    param([string[]]$SearchDirs = @((Join-Path $env:SystemRoot 'System32')))
    foreach ($d in $SearchDirs) {
        if (-not $d) { continue }
        $p = Join-Path $d $script:EtaPkcs11Dll
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return ''
}

# --------------------------------------------------------------- fonts -----

function Test-ArabicFonts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Components)
    $fontsDir = Join-Path $env:SystemRoot 'Fonts'
    foreach ($f in (Get-ArabicFontList -Components $Components)) {
        if (-not (Test-Path (Join-Path $fontsDir $f.FileName))) { return $false }
        $reg = Get-ItemProperty -Path $script:FontsRegistryKey -Name $f.RegistryName -ErrorAction SilentlyContinue
        if (-not $reg) { return $false }
    }
    return $true
}

function Install-ArabicFonts {
    <#
      Installs the Arabic fonts for all users (C:\Windows\Fonts + HKLM registry), so the
      Odoo service account and wkhtmltopdf can use them as a fallback for Arabic text in PDFs.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths, [Parameter(Mandatory)][System.Collections.IDictionary]$Components)
    $fontsDir = Join-Path $env:SystemRoot 'Fonts'
    $cache = Join-Path $Paths.Downloads 'fonts'
    $added = 0
    foreach ($f in (Get-ArabicFontList -Components $Components)) {
        $target = Join-Path $fontsDir $f.FileName
        if (-not (Test-Path $target)) {
            $file = Invoke-Download -Url $f.Url -Destination (Join-Path $cache $f.FileName) -Sha256 $f.Sha256
            Copy-Item $file $target -Force
            $added++
        }
        New-ItemProperty -Path $script:FontsRegistryKey -Name $f.RegistryName -Value $f.FileName -PropertyType String -Force | Out-Null
    }
    if ($added -gt 0) {
        Write-Ok ('Installed {0} Arabic font file(s) for all users' -f $added)
        Write-Info 'Restart Windows once if Arabic text in PDFs still looks wrong: the service picks up new fonts after a restart.'
    }
    else { Write-Ok 'Arabic fonts already present' }
}

# ------------------------------------------------------ bundled addons -----

function Copy-BundledAddons {
    <#
      Copies the modules shipped in this repository (addons\) into addons\custom.
      A module whose dependencies are not available (for example OCA Payroll not
      downloaded, or not ported to this Odoo version yet) is left out, so installing
      the selected apps never fails on it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Paths)
    $src = Join-Path (Split-Path $PSScriptRoot -Parent) 'addons'
    if (-not (Test-Path $src)) { return }
    New-Item -ItemType Directory -Path $Paths.CustomDir -Force | Out-Null
    $others = @(Get-AddonsPathList $Paths | Where-Object { $_ -ne $Paths.CustomDir })
    $available = Get-AvailableModules -AddonsPath $others
    foreach ($dir in @(Get-ChildItem $src -Directory | Where-Object { Test-Path (Join-Path $_.FullName '__manifest__.py') })) {
        $deps = Get-ManifestDepends -ManifestText (Get-Content -Raw -Path (Join-Path $dir.FullName '__manifest__.py'))
        $missing = @($deps | Where-Object { $available -notcontains $_ })
        $target = Join-Path $Paths.CustomDir $dir.Name
        Remove-Item $target -Recurse -Force -ErrorAction SilentlyContinue
        if ($missing.Count -gt 0) { Write-Skip ('{0} needs {1}; not added' -f $dir.Name, ($missing -join ', ')); continue }
        Copy-Item $dir.FullName $target -Recurse -Force
        Write-Ok ('Added module {0}' -f $dir.Name)
    }
}

# ----------------------------------------------------------------- ETA -----

function Show-EtaTokenCheck {
    <# Non-blocking pre-flight for the ETA app: warns when the USB token driver is missing. #>
    [CmdletBinding()]
    param()
    $dll = Find-EtaTokenMiddleware
    if ($dll) { Write-KeyValue 'ETA USB token driver' ('found ({0})' -f $dll); return $true }
    Write-Warn (Get-UiText 'ETA e-invoicing: the ePass2003 USB token driver (eps2003csp11.dll) is not installed.')
    Write-Warn (Get-UiText 'Odoo installs fine without it, but invoices cannot be signed. See docs\ETA-EINVOICING.md.')
    return $false
}

Export-ModuleMember -Function *
