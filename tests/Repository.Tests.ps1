# Pester shares variables between BeforeAll and It blocks, which the analyzer cannot see.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeDiscovery {
    $root = Split-Path $PSScriptRoot -Parent
    $script:sources = @(Get-ChildItem $root -Recurse -Include '*.ps1', '*.psm1', '*.psd1' |
            Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
            ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Substring($root.Length + 1) } })
}

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $components = Import-PowerShellDataFile (Join-Path $root 'config\components.psd1')
    $catalog = Import-PowerShellDataFile (Join-Path $root 'config\addons.psd1')
}

Describe 'PowerShell sources' {
    It '<Name> parses without errors' -ForEach $sources {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }
    It '<Name> is pure ASCII (Windows PowerShell 5.1 misreads UTF-8 without BOM)' -ForEach $sources {
        $bytes = [IO.File]::ReadAllBytes($Path)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}

Describe 'Component manifest' {
    It 'uses HTTPS for every download' {
        foreach ($key in @('Python', 'PostgreSQL', 'Wkhtmltopdf', 'WinSW', 'VCRedist', 'Chrome')) {
            $components[$key].Url | Should -Match '^https://'
        }
    }
    It 'has valid sha256 values where pinned' {
        foreach ($key in @('Python', 'PostgreSQL', 'Wkhtmltopdf', 'WinSW', 'VCRedist', 'Chrome')) {
            $sha = $components[$key].Sha256
            if ($sha) { $sha | Should -Match '^[0-9a-f]{64}$' }
        }
    }
    It 'offers the default Odoo version' {
        $components.OdooVersions | Should -Contain $components.DefaultVersion
    }
    It 'uses a Python supported by every offered Odoo version (3.12)' {
        $components.Python.Version | Should -Match '^3\.12\.'
    }
}

Describe 'Add-on catalog' {
    It 'has unique keys' {
        $keys = @($catalog.Apps.Key) + @($catalog.OcaBundles.Key)
        ($keys | Sort-Object -Unique).Count | Should -Be $keys.Count
    }
    It 'every OCA bundle lists repositories and modules' {
        foreach ($b in $catalog.OcaBundles) {
            $b.Repos.Count | Should -BeGreaterThan 0
            $b.Modules.Count | Should -BeGreaterThan 0
        }
    }
    It 'pre-selects accounting with the Egyptian localization' {
        $acc = $catalog.Apps | Where-Object { $_.Key -eq 'accounting' }
        $acc.Default | Should -BeTrue
        $acc.Modules | Should -Contain 'l10n_eg'
    }
}

Describe 'Answers files' {
    BeforeAll {
        Import-Module (Join-Path $root 'lib\OdooSetup.Logic.psm1') -Force
        $appKeys = [string[]]@($catalog.Apps | ForEach-Object { $_.Key })
        $bundleKeys = [string[]]@($catalog.OcaBundles | ForEach-Object { $_.Key })
    }
    It 'config\answers.example.psd1 passes the reseller package checks' {
        $a = Import-PowerShellDataFile (Join-Path $root 'config\answers.example.psd1')
        @(Get-AnswersProblems -Answers $a -OdooVersions $components.OdooVersions -AppKeys $appKeys -BundleKeys $bundleKeys) | Should -BeNullOrEmpty
    }
    It 'the setup defaults keep Windows Update active hours valid' {
        $text = Get-Content -Raw (Join-Path $root 'setup.ps1')
        $text -match 'ActiveHours\s*=\s*\[ordered\]@\{ Enabled = \$true; Start = (\d+); End = (\d+) \}' | Should -BeTrue
        Test-ActiveHours -Start ([int]$Matches[1]) -End ([int]$Matches[2]) | Should -BeTrue
    }
}

Describe 'Runtime tools' {
    It 'copies every script the scheduled tasks call into tools\' {
        $steps = Get-Content -Raw (Join-Path $root 'lib\OdooSetup.Steps.psm1')
        foreach ($f in @('backup.ps1', 'health-check.ps1', 'odoo-ctl.ps1', 'OdooSetup.Logic.psm1')) {
            $steps | Should -Match ([regex]::Escape("\$f')"))
        }
    }
}
