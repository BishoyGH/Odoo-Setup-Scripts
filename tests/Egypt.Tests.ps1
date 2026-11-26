# Pester shares variables between BeforeAll and It blocks, which the analyzer cannot see.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeDiscovery {
    $root = Split-Path $PSScriptRoot -Parent
    # Every literal English string the installer shows through the translating UI helpers.
    $setup = Get-Content -Raw (Join-Path $root 'setup.ps1')
    $patterns = @(
        "-Prompt '([^']+)'",
        "Write-Section '([^']+)'",
        "Write-KeyValue '([^']+)'",
        "Get-UiText '([^']+)'",
        "-ValidationMessage '([^']+)'"
    )
    $found = foreach ($p in $patterns) { [regex]::Matches($setup, $p) | ForEach-Object { $_.Groups[1].Value } }
    # Menu options: every quoted string inside "-Options @( ... )".
    foreach ($m in [regex]::Matches($setup, '-Options @\(([^)]*)\)')) {
        $found += [regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
    }
    $catalog = Import-PowerShellDataFile (Join-Path $root 'config\addons.psd1')
    $found += @($catalog.Apps.Name) + @($catalog.OcaBundles.Name)
    # Shown before the language is chosen, or proper names that stay as they are.
    $notTranslated = @('Installer language', 'English', 'Odoo ', 'Arabic text displays best in Windows Terminal. If you see boxes, the English text under each question says the same.')
    $script:uiStrings = @($found | Where-Object { $_ -and $notTranslated -notcontains $_ } | Sort-Object -Unique | ForEach-Object { @{ Text = $_ } })
}

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'lib\OdooSetup.Egypt.psm1') -Force -DisableNameChecking
    $arPath = Join-Path $root 'config\i18n\ar.json'
    $ar = Import-UiStrings -Language 'ar'
    $components = Import-PowerShellDataFile (Join-Path $root 'config\components.psd1')
    $catalog = Import-PowerShellDataFile (Join-Path $root 'config\addons.psd1')
}

AfterAll { Set-UiLanguage -Language 'en' }

Describe 'Arabic installer text (config/i18n/ar.json)' {
    It 'is valid UTF-8 without a BOM' {
        $bytes = [IO.File]::ReadAllBytes($arPath)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        { $strict.GetString($bytes) } | Should -Not -Throw
    }
    It 'contains Arabic for every entry and keeps the {n} placeholders' {
        foreach ($k in @($ar.Keys | Where-Object { -not $_.StartsWith('_') })) {
            $v = [string]$ar[$k]
            $v | Should -Match '[\u0600-\u06FF]' -Because $k
            $keyHoles = @([regex]::Matches($k, '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object)
            $valueHoles = @([regex]::Matches($v, '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object)
            ($valueHoles -join ',') | Should -Be ($keyHoles -join ',') -Because $k
        }
    }
    It 'translates "<Text>"' -ForEach $uiStrings {
        $ar.ContainsKey($Text) | Should -BeTrue
    }
}

Describe 'UI language switching' {
    AfterEach { Set-UiLanguage -Language 'en' }

    It 'returns English unchanged in English mode' {
        Set-UiLanguage -Language 'en'
        Get-UiText 'Install folder' | Should -Be 'Install folder'
    }
    It 'returns Arabic in Arabic mode and fills placeholders' {
        Set-UiLanguage -Language 'ar'
        Get-UiLanguage | Should -Be 'ar'
        Get-UiText 'Install folder' | Should -Be $ar['Install folder']
        Get-UiText 'Choose 1-{0}' 3 | Should -Be ($ar['Choose 1-{0}'] -f 3)
    }
    It 'falls back to English for unknown text' {
        Set-UiLanguage -Language 'ar'
        Get-UiText 'Not in the table {0}' 7 | Should -Be 'Not in the table 7'
    }
    It 'accepts Arabic yes/no answers only in Arabic mode' {
        Test-YesAnswer 'y' | Should -BeTrue
        Test-YesAnswer $ar['_yes'][0] | Should -BeFalse
        Set-UiLanguage -Language 'ar'
        Test-YesAnswer $ar['_yes'][0] | Should -BeTrue
        Test-NoAnswer $ar['_no'][0] | Should -BeTrue
        Test-YesAnswer $ar['_no'][0] | Should -BeFalse
    }
    It 'defaults to Arabic only on Arabic Windows' {
        Get-DefaultUiLanguage -CultureName 'ar-EG' | Should -Be 'ar'
        Get-DefaultUiLanguage -CultureName 'en-US' | Should -Be 'en'
    }
}

Describe 'Arabic PDF fonts' {
    It 'pins every font to a commit, over HTTPS, with a sha256' {
        $fonts = @(Get-ArabicFontList -Components $components)
        $fonts.Count | Should -BeGreaterThan 0
        foreach ($f in $fonts) {
            $f.Url | Should -Match '^https://raw\.githubusercontent\.com/notofonts/notofonts\.github\.io/[0-9a-f]{40}/'
            $f.Sha256 | Should -Match '^[0-9a-f]{64}$'
            $f.FileName | Should -Match '\.ttf$'
        }
    }
    It 'builds the Windows registry names' {
        Get-FontRegistryValueName -Family 'Noto Naskh Arabic' | Should -Be 'Noto Naskh Arabic (TrueType)'
        Get-FontRegistryValueName -Family 'Noto Naskh Arabic' -Style 'Bold' | Should -Be 'Noto Naskh Arabic Bold (TrueType)'
    }
    It 'returns no fonts for an older manifest without ArabicFonts' {
        @(Get-ArabicFontList -Components @{}).Count | Should -Be 0
    }
}

Describe 'ETA USB token driver check' {
    It 'finds eps2003csp11.dll when present' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('eta-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            Find-EtaTokenMiddleware -SearchDirs @($dir) | Should -Be ''
            Set-Content -Path (Join-Path $dir 'eps2003csp11.dll') -Value 'x'
            Find-EtaTokenMiddleware -SearchDirs @($dir) | Should -Be (Join-Path $dir 'eps2003csp11.dll')
        }
        finally { Remove-Item $dir -Recurse -Force }
    }
}

Describe 'Bundled Egyptian payroll module' {
    It 'reads manifest dependencies' {
        Get-ManifestDepends -ManifestText "{'name': 'x', 'depends': ['payroll', `"hr`"], 'data': []}" | Should -Be @('payroll', 'hr')
        @(Get-ManifestDepends -ManifestText "{'name': 'x'}").Count | Should -Be 0
    }
    It 'depends only on OCA payroll' {
        $manifest = Get-Content -Raw (Join-Path $root 'addons\l10n_eg_payroll_oss\__manifest__.py')
        Get-ManifestDepends -ManifestText $manifest | Should -Be @('payroll')
    }
    It 'is installed by the payroll bundle' {
        ($catalog.OcaBundles | Where-Object { $_.Key -eq 'payroll' }).Modules | Should -Contain 'l10n_eg_payroll_oss'
    }
}
