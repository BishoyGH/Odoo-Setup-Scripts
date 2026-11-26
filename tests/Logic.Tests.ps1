# Pester shares variables between BeforeAll and It blocks, which the analyzer cannot see.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\lib\OdooSetup.Logic.psm1') -Force
}

Describe 'Get-RamProfileName' {
    It 'maps <Gb> GB to <Expected>' -ForEach @(
        @{ Gb = 3.8; Expected = '4GB' }, @{ Gb = 4; Expected = '4GB' }, @{ Gb = 6; Expected = '4GB' },
        @{ Gb = 7.8; Expected = '8GB' }, @{ Gb = 12; Expected = '8GB' }, @{ Gb = 15.9; Expected = '16GB' }, @{ Gb = 64; Expected = '16GB' }
    ) {
        Get-RamProfileName -TotalMemoryGB $Gb | Should -Be $Expected
    }
}

Describe 'Get-TuningProfile' {
    It 'keeps shared_buffers well below a quarter of RAM on 4 GB' {
        (Get-TuningProfile 4GB).shared_buffers | Should -Be '384MB'
    }
    It 'gives 8 GB more connections and cron threads than 4 GB' {
        $small = Get-TuningProfile 4GB; $big = Get-TuningProfile 8GB
        $big.max_connections | Should -BeGreaterThan $small.max_connections
        $big.max_cron_threads | Should -BeGreaterThan $small.max_cron_threads
    }
    It 'never lets Odoo open more connections than PostgreSQL allows (<Name>)' -ForEach @(@{ Name = '4GB' }, @{ Name = '8GB' }, @{ Name = '16GB' }) {
        $t = Get-TuningProfile $Name
        ($t.db_maxconn + 10) | Should -BeLessOrEqual $t.max_connections
    }
}

Describe 'ConvertTo-PostgresTuningConf' {
    BeforeAll { $t = Get-TuningProfile 8GB }
    It 'listens on localhost only and sets the port' {
        $c = ConvertTo-PostgresTuningConf -Tuning $t -Port 5433
        $c | Should -Match "listen_addresses = 'localhost'"
        $c | Should -Match 'port = 5433'
    }
    It 'uses SSD vs HDD page cost' {
        ConvertTo-PostgresTuningConf -Tuning $t -Port 5432 -Ssd $true | Should -Match 'random_page_cost = 1.1'
        ConvertTo-PostgresTuningConf -Tuning $t -Port 5432 -Ssd $false | Should -Match 'random_page_cost = 4.0'
    }
    It 'does not set effective_io_concurrency (unsupported on Windows)' {
        ConvertTo-PostgresTuningConf -Tuning $t -Port 5432 | Should -Not -Match 'effective_io_concurrency'
    }
    It 'uses Cairo time' {
        ConvertTo-PostgresTuningConf -Tuning $t -Port 5432 | Should -Match "timezone = 'Africa/Cairo'"
    }
}

Describe 'New-OdooConfSettings' {
    BeforeAll {
        $t = Get-TuningProfile 4GB
        $common = @{ Tuning = $t; AddonsPath = @('C:\a', 'C:\b'); DataDir = 'C:\Odoo\data'; DbPassword = 'p'; MasterPassword = 'm' }
    }
    It 'production hides the database manager, listens on LAN and filters to one database' {
        $s = New-OdooConfSettings -Mode prod -Version '19.0' -DbName 'shop' @common
        $s.list_db | Should -Be 'False'
        $s.http_interface | Should -Be '0.0.0.0'
        $s.dbfilter | Should -Be '^shop$'
        $s.with_demo | Should -Be 'False'
    }
    It 'development listens on localhost only' {
        $s = New-OdooConfSettings -Mode dev -Version '19.0' @common
        $s.http_interface | Should -Be '127.0.0.1'
        $s.list_db | Should -Be 'True'
    }
    It 'uses without_demo for 18.0' {
        $s = New-OdooConfSettings -Mode prod -Version '18.0' @common
        $s.without_demo | Should -Be 'all'
        $s.Contains('with_demo') | Should -BeFalse
    }
    It 'never writes POSIX-only options (workers, limit_memory_*) because Windows ignores them' {
        $s = New-OdooConfSettings -Mode prod -Version '19.0' @common
        $s.Contains('workers') | Should -BeFalse
        $s.Contains('limit_memory_soft') | Should -BeFalse
    }
    It 'joins addons_path with commas' {
        (New-OdooConfSettings -Mode dev -Version '19.0' @common).addons_path | Should -Be 'C:\a,C:\b'
    }
}

Describe 'ConvertTo-OdooConf' {
    It 'renders an [options] section' {
        $text = ConvertTo-OdooConf ([ordered]@{ a = 1; b = $true })
        $text | Should -Match '\[options\]'
        $text | Should -Match 'a = 1'
        $text | Should -Match 'b = True'
    }
}

Describe 'Get-DemoArguments' {
    It '18.0 needs --without-demo to skip demo data' { Get-DemoArguments -Version '18.0' | Should -Be '--without-demo=all' }
    It '18.0 with demo passes nothing' { @(Get-DemoArguments -Version '18.0' -WithDemo $true).Count | Should -Be 0 }
    It '19.0 skips demo by default' { @(Get-DemoArguments -Version '19.0').Count | Should -Be 0 }
    It '20.0 with demo passes --with-demo' { Get-DemoArguments -Version '20.0' -WithDemo $true | Should -Be '--with-demo' }
}

Describe 'Resolve-AddonSelection' {
    BeforeAll { $catalog = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\config\addons.psd1') }
    It 'includes the Egyptian chart of accounts with accounting' {
        (Resolve-AddonSelection -Catalog $catalog -AppKeys @('accounting')).Modules | Should -Contain 'l10n_eg'
    }
    It 'pulls dependency repositories for MIS Builder' {
        $r = Resolve-AddonSelection -Catalog $catalog -BundleKeys @('mis')
        $r.Repos | Should -Contain 'reporting-engine'
        $r.Repos | Should -Contain 'server-ux'
    }
    It 'does not duplicate repositories shared by bundles' {
        $r = Resolve-AddonSelection -Catalog $catalog -BundleKeys @('reports', 'mis')
        @($r.Repos | Where-Object { $_ -eq 'server-ux' }).Count | Should -Be 1
    }
}

Describe 'Split-ModulesByAvailability' {
    It 'splits present and missing modules' {
        $r = Split-ModulesByAvailability -Modules @('account', 'nope') -AvailableModules @('account', 'sale')
        $r.Present | Should -Be @('account')
        $r.Missing | Should -Be @('nope')
    }
}

Describe 'Backup naming and retention' {
    BeforeAll {
        $now = [datetime]'2026-03-31T23:00:00'
        $files = 1..20 | ForEach-Object { [pscustomobject]@{ Name = "b$_.zip"; LastWriteTime = $now.AddDays(-$_) } }
    }
    It 'names backups by database and time' {
        Get-BackupFileName -DbName 'shop' -Timestamp ([datetime]'2026-03-05T09:07:00') | Should -Be 'shop_2026-03-05_0907.zip'
    }
    It 'prunes backups older than the retention period' {
        (Select-BackupsToPrune -Files $files -RetentionDays 14 -Now $now).Name | Should -Be @('b15.zip', 'b16.zip', 'b17.zip', 'b18.zip', 'b19.zip', 'b20.zip')
    }
    It 'always keeps the newest backups even when all are old' {
        $old = $files | Select-Object -Last 3
        @(Select-BackupsToPrune -Files $old -RetentionDays 1 -KeepMinimum 3 -Now $now).Count | Should -Be 0
    }
}

Describe 'Database names' {
    It 'suggests <Expected> for "<Company>"' -ForEach @(
        @{ Company = 'Al Nour Trading Co.'; Expected = 'al_nour_trading_co' }
        @{ Company = '123 Shop'; Expected = 'odoo_123_shop' }
        @{ Company = ''; Expected = 'odoo' }
    ) {
        ConvertTo-DatabaseName $Company | Should -Be $Expected
    }
    It 'falls back to odoo for Arabic-only names' {
        ConvertTo-DatabaseName ([string][char]0x0634 + [char]0x0631 + [char]0x0643 + [char]0x0629) | Should -Be 'odoo'
    }
    It 'validates names' {
        Test-DatabaseName 'shop_1' | Should -BeTrue
        Test-DatabaseName '1shop' | Should -BeFalse
        Test-DatabaseName 'my shop' | Should -BeFalse
    }
}

Describe 'Ports and paths' {
    It 'picks the first free port' { Get-FreePort -Candidates @(5433, 5434) -UsedPorts @(5433) | Should -Be 5434 }
    It 'throws when no port is free' { { Get-FreePort -Candidates @(1) -UsedPorts @(1) } | Should -Throw }
    It 'derives paths from the root' {
        $p = Get-InstallPaths -Root 'D:\Odoo\'
        $p.OdooConf | Should -Be 'D:\Odoo\conf\odoo.conf'
        $p.VenvPython | Should -Be 'D:\Odoo\venv\Scripts\python.exe'
    }
    It 'adds --dev only in development' {
        Get-OdooServiceArguments -OdooBin 'C:\o\odoo-bin' -ConfigFile 'C:\c.conf' -Mode prod | Should -Not -Match '--dev'
        Get-OdooServiceArguments -OdooBin 'C:\o\odoo-bin' -ConfigFile 'C:\c.conf' -Mode dev | Should -Match '--dev=reload'
    }
}

Describe 'Test-ActiveHours' {
    It 'accepts <Start>-<End>' -ForEach @(
        @{ Start = 8; End = 23 }, @{ Start = 9; End = 17 }, @{ Start = 6; End = 0 }, @{ Start = 22; End = 6 }, @{ Start = 0; End = 18 }
    ) {
        Test-ActiveHours -Start $Start -End $End | Should -BeTrue
    }
    It 'rejects <Start>-<End>' -ForEach @(
        @{ Start = 8; End = 8 }, @{ Start = 0; End = 23 }, @{ Start = 5; End = 4 }, @{ Start = -1; End = 10 }, @{ Start = 8; End = 24 }
    ) {
        Test-ActiveHours -Start $Start -End $End | Should -BeFalse
    }
    It 'counts hours across midnight' {
        Get-ActiveHoursSpan -Start 22 -End 6 | Should -Be 8
    }
}

Describe 'Get-HealthCheckAction' {
    It 'returns <Expected> for <Case>' -ForEach @(
        @{ Case = 'answering'; Expected = 'ok'; P = @{ ServiceStatus = 'Running'; HttpOk = $true } }
        @{ Case = 'paused by setup'; Expected = 'paused'; P = @{ ServiceStatus = 'Stopped'; HttpOk = $false; Paused = $true } }
        @{ Case = 'no service'; Expected = 'missing'; P = @{ ServiceStatus = ''; HttpOk = $false } }
        @{ Case = 'stopped'; Expected = 'start'; P = @{ ServiceStatus = 'Stopped'; HttpOk = $false } }
        @{ Case = 'starting'; Expected = 'wait'; P = @{ ServiceStatus = 'StartPending'; HttpOk = $false } }
        @{ Case = 'first failure'; Expected = 'wait'; P = @{ ServiceStatus = 'Running'; HttpOk = $false; PreviousFailures = 0 } }
        @{ Case = 'second failure'; Expected = 'restart'; P = @{ ServiceStatus = 'Running'; HttpOk = $false; PreviousFailures = 1 } }
        @{ Case = 'just started (boot)'; Expected = 'wait'; P = @{ ServiceStatus = 'Running'; HttpOk = $false; PreviousFailures = 5; ServiceUptimeMinutes = 2 } }
        @{ Case = 'restart loop'; Expected = 'backoff'; P = @{ ServiceStatus = 'Running'; HttpOk = $false; PreviousFailures = 1; RestartsLastHour = 3 } }
        @{ Case = 'answering after restarts'; Expected = 'ok'; P = @{ ServiceStatus = 'Running'; HttpOk = $true; RestartsLastHour = 3 } }
    ) {
        Get-HealthCheckAction @P | Should -Be $Expected
    }
}

Describe 'Get-AnswersProblems' {
    BeforeAll {
        $versions = @('18.0', '19.0', '20.0')
        $good = @{
            Mode = 'prod'; OdooVersion = '19.0'; CompanyName = 'Nile Trading'; DbName = 'nile'
            Apps = @('accounting'); OcaBundles = @('ux')
            Backup = @{ Enabled = $true; Dir = 'D:\OdooBackups'; Time = '22:00' }
            ActiveHours = @{ Enabled = $true; Start = 9; End = 22 }
        }
    }
    It 'accepts a complete answers file' {
        @(Get-AnswersProblems -Answers $good -OdooVersions $versions -AppKeys @('accounting') -BundleKeys @('ux')).Count | Should -Be 0
    }
    It 'reports <Case>' -ForEach @(
        @{ Case = 'a typo in a setting name'; Change = @{ DbNmae = 'x' }; Pattern = 'Unknown setting "DbNmae"' }
        @{ Case = 'an unsupported version'; Change = @{ OdooVersion = '17.0' }; Pattern = 'OdooVersion' }
        @{ Case = 'a bad database name'; Change = @{ DbName = '1shop' }; Pattern = 'DbName' }
        @{ Case = 'a missing backup folder'; Change = @{ Backup = @{ Enabled = $true; Dir = '' } }; Pattern = 'Backup.Dir' }
        @{ Case = 'too many business hours'; Change = @{ ActiveHours = @{ Enabled = $true; Start = 0; End = 23 } }; Pattern = 'ActiveHours' }
        @{ Case = 'an unknown app'; Change = @{ Apps = @('accounting', 'helpdesk') }; Pattern = 'helpdesk' }
    ) {
        $a = @{} + $good
        foreach ($k in $Change.Keys) { $a[$k] = $Change[$k] }
        (Get-AnswersProblems -Answers $a -OdooVersions $versions -AppKeys @('accounting') -BundleKeys @('ux')) -join ' ' | Should -Match ([regex]::Escape($Pattern))
    }
}
