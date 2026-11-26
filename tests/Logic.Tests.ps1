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

Describe 'Backup health' {
    BeforeAll {
        $now = [datetime]'2026-03-31T09:00:00'
        function New-Status {
            param($LastSuccess = '2026-03-30T22:00:00', $LastErrorAt = $null, $Copy = $null, $TestRestore = $null)
            if ($null -eq $Copy) { $Copy = @{ LastSuccess = '2026-03-30T22:05:00' } }
            if ($null -eq $TestRestore) { $TestRestore = @{ LastRun = '2026-03-28T22:10:00'; Ok = $true } }
            return @{ LastSuccess = $LastSuccess; LastErrorAt = $LastErrorAt; LastError = 'disk full'; Copy = $Copy; TestRestore = $TestRestore }
        }
    }
    It 'is OK after a recent backup, copy and test-restore' {
        $h = Get-BackupHealth -Status (New-Status) -Now $now -CopyConfigured $true
        $h.Level | Should -Be 'OK'
        $h.Messages.Count | Should -Be 0
    }
    It 'is Unknown before the first backup runs' {
        (Get-BackupHealth -Status $null -Now $now).Level | Should -Be 'Unknown'
    }
    It 'is an error when the last good backup is older than 2 days' {
        $h = Get-BackupHealth -Status (New-Status -LastSuccess '2026-03-28T08:00:00') -Now $now
        $h.Level | Should -Be 'Error'
        $h.Messages[0] | Should -Match '3 days old'
    }
    It 'is an error when the latest run failed, even if the last good one is recent' {
        $h = Get-BackupHealth -Status (New-Status -LastErrorAt '2026-03-31T08:00:00') -Now $now
        $h.Level | Should -Be 'Error'
        $h.Messages -join ' ' | Should -Match 'disk full'
    }
    It 'ignores an old failure that a later backup fixed' {
        (Get-BackupHealth -Status (New-Status -LastErrorAt '2026-03-29T22:00:00') -Now $now).Level | Should -Be 'OK'
    }
    It 'is an error when no backup ever succeeded' {
        (Get-BackupHealth -Status (New-Status -LastSuccess $null -LastErrorAt '2026-03-31T08:00:00') -Now $now).Level | Should -Be 'Error'
    }
    It 'warns when the second copy failed (USB drive unplugged)' {
        $copy = @{ LastSuccess = '2026-03-25T22:05:00'; LastErrorAt = '2026-03-30T22:05:00'; LastError = 'Drive E: is not connected.' }
        $h = Get-BackupHealth -Status (New-Status -Copy $copy) -Now $now -CopyConfigured $true
        $h.Level | Should -Be 'Warning'
        $h.Messages[0] | Should -Match 'not connected'
    }
    It 'does not check the copy when none is configured' {
        $copy = @{ LastErrorAt = '2026-03-30T22:05:00' }
        (Get-BackupHealth -Status (New-Status -Copy $copy) -Now $now -CopyConfigured $false).Level | Should -Be 'OK'
    }
    It 'is an error when the test-restore failed' {
        $tr = @{ LastRun = '2026-03-30T22:10:00'; Ok = $false; Message = 'base module not installed' }
        $h = Get-BackupHealth -Status (New-Status -TestRestore $tr) -Now $now
        $h.Level | Should -Be 'Error'
        $h.Messages[0] | Should -Match 'test-restore'
    }
    It 'warns when the test-restore has not run for two intervals' {
        $tr = @{ LastRun = '2026-03-10T22:10:00'; Ok = $true }
        (Get-BackupHealth -Status (New-Status -TestRestore $tr) -Now $now -TestRestoreDays 7).Level | Should -Be 'Warning'
        (Get-BackupHealth -Status (New-Status -TestRestore $tr) -Now $now -TestRestoreDays 0).Level | Should -Be 'OK'
    }
    It 'passes on a test-restore warning such as missing attachments' {
        $tr = @{ LastRun = '2026-03-30T22:10:00'; Ok = $true; Warning = '2 of 900 attachment files are not in the backup.' }
        $h = Get-BackupHealth -Status (New-Status -TestRestore $tr) -Now $now
        $h.Level | Should -Be 'Warning'
        $h.Messages[0] | Should -Match 'attachment'
    }
    It 'reads a status file in the old format (LastSuccess only)' {
        $old = '{ "LastSuccess": "2026-03-30T22:00:00", "File": "x.zip", "SizeMB": 12.5 }' | ConvertFrom-Json
        (Get-BackupHealth -Status $old -Now $now).Level | Should -Be 'OK'
    }
}

Describe 'Test-restore schedule' {
    BeforeAll { $now = [datetime]'2026-03-31T22:00:00' }
    It 'runs when it never ran' { Test-TestRestoreDue -LastRun $null -Now $now | Should -BeTrue }
    It 'waits for the interval' { Test-TestRestoreDue -LastRun '2026-03-28T22:00:00' -Now $now | Should -BeFalse }
    It 'runs after a week, even if the daily backup starts a little early' {
        Test-TestRestoreDue -LastRun '2026-03-24T22:30:00' -Now $now | Should -BeTrue
    }
    It 'retries on the next backup after a failure' {
        Test-TestRestoreDue -LastRun '2026-03-30T22:00:00' -LastRunOk $false -Now $now | Should -BeTrue
    }
    It 'never runs when switched off' { Test-TestRestoreDue -LastRun $null -IntervalDays 0 -Now $now | Should -BeFalse }
    It 'names the throwaway database within the PostgreSQL limit' {
        Get-TestRestoreDbName -DbName 'shop' | Should -Be 'shop_restore_test'
        (Get-TestRestoreDbName -DbName ('a' * 63)).Length | Should -BeLessOrEqual 63
    }
}

Describe 'Get-SettingValue' {
    It 'returns the default for settings written by an older version' {
        $old = '{ "Backup": { "Enabled": true } }' | ConvertFrom-Json
        Get-SettingValue $old.Backup 'CopyDir' '' | Should -Be ''
        Get-SettingValue $old.Backup 'Enabled' $false | Should -BeTrue
        Get-SettingValue @{ TestRestoreDays = 3 } 'TestRestoreDays' 7 | Should -Be 3
        Get-SettingValue $null 'x' 'd' | Should -Be 'd'
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
