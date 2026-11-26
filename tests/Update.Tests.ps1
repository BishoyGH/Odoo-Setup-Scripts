# Pester shares variables between BeforeAll and It blocks, which the analyzer cannot see.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\lib\OdooSetup.Logic.psm1') -Force
    $root = Split-Path $PSScriptRoot -Parent
}

Describe 'Get-PreUpdateDatabaseName' {
    It 'adds a suffix' {
        Get-PreUpdateDatabaseName -DbName 'acme' | Should -Be 'acme_preupdate'
    }
    It 'stays within the 63-character PostgreSQL limit' {
        $name = Get-PreUpdateDatabaseName -DbName ('a' * 63)
        $name.Length | Should -Be 63
        $name | Should -Match '_preupdate$'
    }
}

Describe 'Get-UpdateFreeSpaceNeededMB' {
    It 'adds the rollback copies, new source and 1 GB headroom' {
        Get-UpdateFreeSpaceNeededMB -DatabaseMB 500 -FilestoreMB 200 -VenvMB 300 -NewSourceMB 1000 | Should -Be 3024
    }
    It 'counts the backup ZIP when it is written to the same drive' {
        $other = Get-UpdateFreeSpaceNeededMB -DatabaseMB 500 -FilestoreMB 200 -VenvMB 300 -NewSourceMB 1000
        $same = Get-UpdateFreeSpaceNeededMB -DatabaseMB 500 -FilestoreMB 200 -VenvMB 300 -NewSourceMB 1000 -BackupOnSameDrive $true
        ($same - $other) | Should -Be 700
    }
    It 'rounds up' {
        Get-UpdateFreeSpaceNeededMB -DatabaseMB 0.2 | Should -Be 1025
    }
}

Describe 'Update wiring' {
    It 'setup.ps1 offers the Update action in the menu and on the command line' {
        $text = Get-Content -Raw (Join-Path $root 'setup.ps1')
        $text | Should -Match "ValidateSet\([^)]*'Update'"
        $text | Should -Match "'Update Odoo"
        $text | Should -Match 'Invoke-OdooUpdate'
    }
    It 'reuses the same download cache names as the installer' {
        $steps = Get-Content -Raw (Join-Path $root 'lib\OdooSetup.Steps.psm1')
        $update = Get-Content -Raw (Join-Path $root 'lib\OdooSetup.Update.psm1')
        foreach ($pattern in @("'odoo-{0}.zip'", "'oca-{0}-{1}.zip'")) {
            $steps | Should -Match ([regex]::Escape($pattern))
            $update | Should -Match ([regex]::Escape($pattern))
        }
    }
}
