# Unit tests for the Windows install steps, run on the Linux CI runner.
# Every native tool call goes through Invoke-Native, Invoke-Tool or Invoke-Download,
# and Windows-only cmdlets are stubbed, so nothing here touches the machine.

# Pester shares variables between BeforeAll and It blocks, which the analyzer cannot see.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    # Cmdlets that only exist on Windows. Pester can only mock commands that exist,
    # so on Linux we define empty stand-ins with the parameters the steps use.
    $stubs = @{
        'Get-Service'               = '[CmdletBinding()] param([string]$Name)'
        'Start-Service'             = '[CmdletBinding()] param([string]$Name)'
        'Stop-Service'              = '[CmdletBinding()] param([string]$Name, [switch]$Force)'
        'Get-CimInstance'           = '[CmdletBinding()] param([Parameter(Position = 0)][string]$ClassName, [string]$Filter)'
        'Invoke-CimMethod'          = '[CmdletBinding()] param($InputObject, [string]$MethodName, [hashtable]$Arguments)'
        'Get-NetFirewallRule'       = '[CmdletBinding()] param([string]$Name)'
        'Remove-NetFirewallRule'    = '[CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject)'
        'New-NetFirewallRule'       = '[CmdletBinding()] param([string]$Name, [string]$DisplayName, [string]$Direction, [string]$Protocol, $LocalPort, [string]$Action, [string[]]$Profile)'
        'Get-NetConnectionProfile'  = '[CmdletBinding()] param()'
        'Add-MpPreference'          = '[CmdletBinding()] param([string[]]$ExclusionPath, [string[]]$ExclusionProcess)'
        'Remove-MpPreference'       = '[CmdletBinding()] param([string[]]$ExclusionPath, [string[]]$ExclusionProcess)'
    }
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path ('function:global:' + $name) -Value ([scriptblock]::Create($stubs[$name]))
        }
    }

    Import-Module (Join-Path $PSScriptRoot '..\lib\OdooSetup.Steps.psm1') -Force -DisableNameChecking

    function New-TestPaths {
        # Real install layout, rooted in TestDrive, with separators that work on Linux too.
        $p = Get-InstallPaths -Root 'C:\Odoo'
        $result = [ordered]@{}
        foreach ($k in @($p.Keys)) {
            $rel = $p[$k].Substring('C:\Odoo'.Length).TrimStart('\') -replace '\\', [IO.Path]::DirectorySeparatorChar
            $result[$k] = if ($rel) { Join-Path $TestDrive $rel } else { [string]$TestDrive }
        }
        return $result
    }
    function New-ToolResult { param([int]$ExitCode = 0, [string[]]$Output = @()) [pscustomobject]@{ ExitCode = $ExitCode; Output = $Output } }

    $components = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\config\components.psd1')
}

Describe 'Install steps' {
    BeforeEach {
        # Keep test output readable: the console helpers only print.
        foreach ($w in @('Write-Info', 'Write-Ok', 'Write-Warn', 'Write-Skip', 'Write-KeyValue')) {
            Mock -ModuleName OdooSetup.Steps $w {}
        }
    }

    Describe 'Invoke-Tool' {
        It 'returns the exit code and both output streams without throwing' -Skip:($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6) {
            $r = Invoke-Tool -FilePath 'sh' -ArgumentList @('-c', 'echo out; echo err 1>&2; exit 3')
            $r.ExitCode | Should -Be 3
            $r.Output | Should -Contain 'out'
            $r.Output | Should -Contain 'err'
        }
        It 'throws when the tool does not exist' {
            { Invoke-Tool -FilePath 'no-such-tool-oss.exe' } | Should -Throw '*was not found*'
        }
    }

    Describe 'Folder permissions (icacls)' {
        BeforeEach { $dir = Join-Path $TestDrive 'acl' }

        It 'Grant-FolderAccess grants an inheritable right by SID, without /T' {
            Mock -ModuleName OdooSetup.Core Invoke-Tool { New-ToolResult }
            Grant-FolderAccess -Path $dir -Sid 'S-1-5-20' -Rights 'M'
            Should -Invoke -ModuleName OdooSetup.Core Invoke-Tool -Times 1 -ParameterFilter {
                $FilePath -eq 'icacls.exe' -and ($ArgumentList -join ' ') -eq ('{0} /grant *S-1-5-20:(OI)(CI)M /C /Q' -f $dir)
            }
            Test-Path $dir | Should -BeTrue
        }
        It 'Grant-FolderAccess throws when icacls fails' {
            Mock -ModuleName OdooSetup.Core Invoke-Tool { New-ToolResult -ExitCode 5 }
            { Grant-FolderAccess -Path $dir -Sid 'S-1-5-20' } | Should -Throw '*icacls*'
        }
        It 'Protect-Folder removes inheritance and replaces grants with Administrators and SYSTEM only' {
            Mock -ModuleName OdooSetup.Core Invoke-Tool { New-ToolResult }
            Protect-Folder -Path $dir
            Should -Invoke -ModuleName OdooSetup.Core Invoke-Tool -Times 1 -ParameterFilter {
                $ArgumentList[1] -eq '/inheritance:r' -and $ArgumentList[2] -eq '/grant:r' -and
                ($ArgumentList -contains '*S-1-5-32-544:(OI)(CI)F') -and ($ArgumentList -contains '*S-1-5-18:(OI)(CI)F') -and
                @($ArgumentList | Where-Object { $_ -like '*:(OI)(CI)*' }).Count -eq 2
            }
        }
        It 'Grant-FileRead grants read on one file' {
            Mock -ModuleName OdooSetup.Core Invoke-Tool { New-ToolResult }
            Grant-FileRead -Path 'x.conf' -Sid 'S-1-5-20'
            Should -Invoke -ModuleName OdooSetup.Core Invoke-Tool -ParameterFilter { ($ArgumentList -join ' ') -eq 'x.conf /grant *S-1-5-20:R /C /Q' }
        }
    }

    Describe 'Chrome and VC++ runtime' {
        BeforeEach {
            $paths = New-TestPaths
            Mock -ModuleName OdooSetup.Steps Invoke-Download { $Destination }
            Mock -ModuleName OdooSetup.Steps Invoke-Native { 0 }
        }
        It 'installs Chrome silently and accepts reboot-required codes' {
            Mock -ModuleName OdooSetup.Steps Find-Chrome { 'C:\chrome.exe' }
            Install-Chrome -Paths $paths -Components $components
            Should -Invoke -ModuleName OdooSetup.Steps Invoke-Native -Times 1 -ParameterFilter {
                $FilePath -eq 'msiexec.exe' -and $ArgumentList -contains '/qn' -and $SuccessCodes -contains 3010
            }
        }
        It 'fails when chrome.exe is still missing after the install' {
            Mock -ModuleName OdooSetup.Steps Find-Chrome { $null }
            { Install-Chrome -Paths $paths -Components $components } | Should -Throw '*chrome.exe was not found*'
        }
        It 'installs VC++ quietly, treating "newer version present" (1638) as success' {
            Install-VCRedist -Paths $paths -Components $components
            Should -Invoke -ModuleName OdooSetup.Steps Invoke-Native -Times 1 -ParameterFilter {
                $ArgumentList -contains '/quiet' -and $SuccessCodes -contains 1638
            }
        }
    }

    Describe 'Python' {
        BeforeEach {
            $paths = New-TestPaths
            New-Item -ItemType File -Path $paths.PythonExe -Force | Out-Null
        }
        It 'Test-Python is true only for the pinned version' {
            Mock -ModuleName OdooSetup.Steps Invoke-Tool { New-ToolResult -Output @('3.12.10') }
            Test-Python -Paths $paths -Version '3.12.10' | Should -BeTrue
            Test-Python -Paths $paths -Version '3.12.11' | Should -BeFalse
        }
        It 'Test-Python is false when python.exe fails' {
            Mock -ModuleName OdooSetup.Steps Invoke-Tool { New-ToolResult -ExitCode 1 -Output @('3.12.10') }
            Test-Python -Paths $paths -Version '3.12.10' | Should -BeFalse
        }
        It 'Test-Python is false without running anything when python.exe is missing' {
            Remove-Item $paths.PythonExe
            Mock -ModuleName OdooSetup.Steps Invoke-Tool { throw 'should not run' }
            Test-Python -Paths $paths -Version '3.12.10' | Should -BeFalse
        }
        It 'Install-Python installs privately: no PATH change, no file associations' {
            Mock -ModuleName OdooSetup.Steps Invoke-Download { $Destination }
            Mock -ModuleName OdooSetup.Steps Invoke-Native { 0 }
            Install-Python -Paths $paths -Components $components
            Should -Invoke -ModuleName OdooSetup.Steps Invoke-Native -Times 1 -ParameterFilter {
                $ArgumentList -contains 'PrependPath=0' -and $ArgumentList -contains 'AssociateFiles=0' -and
                $ArgumentList -contains ('TargetDir="{0}"' -f $paths.Python)
            }
        }
    }

    Describe 'PostgreSQL' {
        BeforeEach { $paths = New-TestPaths }

        Context 'Initialize-PgCluster' {
            BeforeEach {
                $env:TEMP = [string]$TestDrive
                Remove-Item $paths.PgData -Recurse -Force -ErrorAction SilentlyContinue
                Mock -ModuleName OdooSetup.Steps Grant-FolderAccess {}
                Mock -ModuleName OdooSetup.Steps Get-CurrentUserSid { 'S-1-5-21-1' }
                Mock -ModuleName OdooSetup.Steps Invoke-Native { 0 }
            }
            It 'refuses to use a folder that has other files in it' {
                New-Item -ItemType File -Path (Join-Path $paths.PgData 'stray.txt') -Force | Out-Null
                { Initialize-PgCluster -Paths $paths -SuperPassword 'pw' } | Should -Throw '*not a PostgreSQL cluster*'
                Should -Invoke -ModuleName OdooSetup.Steps Invoke-Native -Times 0
            }
            It 'runs initdb with checksums and scram, and deletes the password file' {
                Initialize-PgCluster -Paths $paths -SuperPassword 'pw'
                Should -Invoke -ModuleName OdooSetup.Steps Invoke-Native -Times 1 -ParameterFilter {
                    $FilePath -like '*initdb.exe' -and $ArgumentList -contains '--data-checksums' -and $ArgumentList -contains '--auth=scram-sha-256'
                }
                Should -Invoke -ModuleName OdooSetup.Steps Grant-FolderAccess -ParameterFilter { $Sid -eq 'S-1-5-21-1' }
                @(Get-ChildItem $TestDrive -Filter 'pg-*.tmp').Count | Should -Be 0
            }
        }

        Context 'Install-PgService' {
            BeforeEach {
                Mock -ModuleName OdooSetup.Steps Invoke-Native { 0 }
                Mock -ModuleName OdooSetup.Steps Invoke-Tool { New-ToolResult }
                Mock -ModuleName OdooSetup.Steps Start-ServiceSafe {}
                Mock -ModuleName OdooSetup.Steps Wait-TcpPort { $true }
                Mock -ModuleName OdooSetup.Steps Get-NetworkServiceAccountName { 'NT AUTHORITY\NETWORK SERVICE' }
            }
            It 'registers the service as NetworkService with restart-on-failure when it is missing' {
                Mock -ModuleName OdooSetup.Steps Get-Service { $null }
                Install-PgService -Paths $paths -Port 5433
                Should -Invoke -ModuleName OdooSetup.Steps Invoke-Native -Times 1 -ParameterFilter {
                    $FilePath -like '*pg_ctl.exe' -and $ArgumentList[0] -eq 'register' -and $ArgumentList -notcontains '-w' -and
                    $ArgumentList -contains '"NT AUTHORITY\NETWORK SERVICE"'
                }
                Should -Invoke -ModuleName OdooSetup.Steps Invoke-Tool -Times 1 -ParameterFilter {
                    $FilePath -eq 'sc.exe' -and $ArgumentList[0] -eq 'failure' -and $ArgumentList -contains 'actions='
                }
            }
            It 'only starts an existing service' {
                Mock -ModuleName OdooSetup.Steps Get-Service { [pscustomobject]@{ Status = 'Stopped' } }
                Install-PgService -Paths $paths -Port 5433
                Should -Invoke -ModuleName OdooSetup.Steps Invoke-Native -Times 0
                Should -Invoke -ModuleName OdooSetup.Steps Start-ServiceSafe -Times 1 -ParameterFilter { $Name -eq 'OdooPostgreSQL' }
            }
            It 'fails with the log folder when the port never opens' {
                Mock -ModuleName OdooSetup.Steps Get-Service { [pscustomobject]@{ Status = 'Running' } }
                Mock -ModuleName OdooSetup.Steps Wait-TcpPort { $false }
                { Install-PgService -Paths $paths -Port 5433 } | Should -Throw '*did not start on port 5433*'
            }
        }

        Context 'Invoke-Psql' {
            It 'connects over TCP to localhost, stops on error and restores PGPASSWORD' {
                $env:PGPASSWORD = 'before'
                Mock -ModuleName OdooSetup.Steps Invoke-Tool { $env:PGPASSWORD | Should -Be 'secret'; New-ToolResult -Output @(' 1 ', '') }
                Invoke-Psql -Paths $paths -Port 5433 -User 'odoo' -Password 'secret' -Sql 'SELECT 1' | Should -Be '1'
                Should -Invoke -ModuleName OdooSetup.Steps Invoke-Tool -ParameterFilter {
                    ($ArgumentList -join ' ') -eq '-h 127.0.0.1 -p 5433 -U odoo -d postgres -v ON_ERROR_STOP=1 -tAc SELECT 1'
                }
                $env:PGPASSWORD | Should -Be 'before'
            }
            It 'throws with the psql message on failure' {
                Mock -ModuleName OdooSetup.Steps Invoke-Tool { New-ToolResult -ExitCode 1 -Output @('FATAL: password authentication failed') }
                { Invoke-Psql -Paths $paths -Port 5433 -User 'odoo' -Password 'x' -Sql 'SELECT 1' } | Should -Throw '*password authentication failed*'
            }
        }

        Context 'Database state' {
            It 'Set-PgOdooRole creates or updates a CREATEDB role without superuser' {
                Mock -ModuleName OdooSetup.Steps Invoke-Psql { '' }
                Set-PgOdooRole -Paths $paths -Port 5433 -SuperPassword 'su' -OdooPassword 'abc123'
                Should -Invoke -ModuleName OdooSetup.Steps Invoke-Psql -Times 1 -ParameterFilter {
                    $User -eq 'postgres' -and $Sql -match "CREATE ROLE odoo LOGIN CREATEDB PASSWORD 'abc123'" -and $Sql -notmatch 'SUPERUSER'
                }
            }
            It 'Get-OdooDatabaseState is <Expected> when <Case>' -ForEach @(
                @{ Case = 'the database does not exist'; Exists = ''; Base = ''; Expected = 'missing' }
                @{ Case = 'base is not installed'; Exists = '1'; Base = 'to install'; Expected = 'partial' }
                @{ Case = 'base is installed'; Exists = '1'; Base = 'installed'; Expected = 'ready' }
            ) {
                $script:exists = $Exists; $script:base = $Base
                Mock -ModuleName OdooSetup.Steps Invoke-Psql { $script:exists } -ParameterFilter { $Sql -like '*pg_database*' }
                Mock -ModuleName OdooSetup.Steps Invoke-Psql { $script:base } -ParameterFilter { $Sql -like '*ir_module_module*' }
                Get-OdooDatabaseState -Paths $paths -Port 5433 -Password 'pw' -DbName 'odoo' | Should -Be $Expected
            }
            It 'Get-OdooDatabaseState is partial when the module table is missing' {
                Mock -ModuleName OdooSetup.Steps Invoke-Psql { '1' } -ParameterFilter { $Sql -like '*pg_database*' }
                Mock -ModuleName OdooSetup.Steps Invoke-Psql { throw 'relation "ir_module_module" does not exist' } -ParameterFilter { $Sql -like '*ir_module_module*' }
                Get-OdooDatabaseState -Paths $paths -Port 5433 -Password 'pw' -DbName 'odoo' | Should -Be 'partial'
            }
            It 'Test-DatabaseExists is false when PostgreSQL cannot be reached' {
                Mock -ModuleName OdooSetup.Steps Invoke-Psql { throw 'could not connect' }
                Test-DatabaseExists -Paths $paths -Port 5433 -Password 'pw' -DbName 'odoo' | Should -BeFalse
            }
        }
    }

    Describe 'Odoo Python environment and add-ons' {
        BeforeEach {
            $paths = New-TestPaths
            New-Item -ItemType Directory -Path $paths.OdooSrc -Force | Out-Null
            Set-Content -Path (Join-Path $paths.OdooSrc 'requirements.txt') -Value 'lxml'
            Mock -ModuleName OdooSetup.Steps Invoke-Native { New-Item -ItemType File -Path $paths.VenvPython -Force | Out-Null; 0 }
            Mock -ModuleName OdooSetup.Steps Invoke-Pip {}
        }
        It 'Install-OdooVenv adds watchdog only in development mode, then the venv tests as current' {
            Install-OdooVenv -Paths $paths -Mode 'dev'
            Should -Invoke -ModuleName OdooSetup.Steps Invoke-Pip -Times 1 -ParameterFilter { $PipArgs -contains 'watchdog' }
            Test-OdooVenv -Paths $paths -Mode 'dev' | Should -BeTrue
            Test-OdooVenv -Paths $paths -Mode 'prod' | Should -BeFalse
        }
        It 'Test-OdooVenv is false after requirements.txt changes' {
            Install-OdooVenv -Paths $paths -Mode 'prod'
            Should -Invoke -ModuleName OdooSetup.Steps Invoke-Pip -Times 0 -ParameterFilter { $PipArgs -contains 'watchdog' }
            Set-Content -Path (Join-Path $paths.OdooSrc 'requirements.txt') -Value 'lxml==5'
            Test-OdooVenv -Paths $paths -Mode 'prod' | Should -BeFalse
        }
        It 'Install-OcaRepos skips present repos and keeps going when one has no branch' {
            $present = Join-Path $paths.OcaDir 'web'
            New-Item -ItemType Directory -Path $present -Force | Out-Null
            Set-Content -Path (Join-Path $present '.oss-branch') -Value '19.0'
            Mock -ModuleName OdooSetup.Steps Install-SourceTree { throw 'HTTP 404' } -ParameterFilter { $Destination -like '*missing-repo' }
            Mock -ModuleName OdooSetup.Steps Install-SourceTree {} -ParameterFilter { $Destination -like '*account-financial-reporting' }
            Install-OcaRepos -Paths $paths -Components $components -Version '19.0' -Repos @('web', 'missing-repo', 'account-financial-reporting')
            Should -Invoke -ModuleName OdooSetup.Steps Install-SourceTree -Times 2
            Should -Invoke -ModuleName OdooSetup.Steps Write-Skip -Times 1 -ParameterFilter { $Message -like '*OCA/web*' }
            Should -Invoke -ModuleName OdooSetup.Steps Write-Warn -Times 1 -ParameterFilter { $Message -like '*OCA/missing-repo*' }
        }
    }

    Describe 'Odoo database and modules' {
        BeforeEach {
            $paths = New-TestPaths
            $settings = @{ DbName = 'odoo'; OdooVersion = '19.0'; WithDemo = $false }
            Mock -ModuleName OdooSetup.Steps Get-AddonsPathList { @('addons') }
            Mock -ModuleName OdooSetup.Steps Invoke-OdooBin {}
            Mock -ModuleName OdooSetup.Steps Invoke-OdooShellScript {}
        }
        It 'New-OdooDatabase loads Arabic and stops after init' {
            New-OdooDatabase -Paths $paths -Settings $settings
            Should -Invoke -ModuleName OdooSetup.Steps Invoke-OdooBin -Times 1 -ParameterFilter {
                $OdooArgs -contains '--load-language=ar_001' -and $OdooArgs -contains '--stop-after-init' -and $OdooArgs -contains 'base'
            }
        }
        It 'Install-OdooModules installs only available modules and warns about the rest' {
            Mock -ModuleName OdooSetup.Steps Get-AvailableModules { @('sale', 'crm') }
            Install-OdooModules -Paths $paths -Settings $settings -Modules @('sale', 'crm', 'not_there')
            Should -Invoke -ModuleName OdooSetup.Steps Invoke-OdooBin -Times 1 -ParameterFilter { $OdooArgs -contains 'crm,sale' -or $OdooArgs -contains 'sale,crm' }
            Should -Invoke -ModuleName OdooSetup.Steps Write-Warn -Times 1 -ParameterFilter { $Message -like '*not_there*' }
            Should -Invoke -ModuleName OdooSetup.Steps Invoke-OdooShellScript -Times 0
        }
        It 'Install-OdooModules loads the Egyptian chart of accounts when Accounting is installed' {
            Mock -ModuleName OdooSetup.Steps Get-AvailableModules { @('account', 'l10n_eg') }
            Install-OdooModules -Paths $paths -Settings $settings -Modules @('account', 'l10n_eg')
            Should -Invoke -ModuleName OdooSetup.Steps Invoke-OdooShellScript -Times 1 -ParameterFilter { $ScriptName -eq 'post_install.py' }
        }
        It 'Install-OdooModules runs nothing when no module is available' {
            Mock -ModuleName OdooSetup.Steps Get-AvailableModules { @() }
            Install-OdooModules -Paths $paths -Settings $settings -Modules @('pos')
            Should -Invoke -ModuleName OdooSetup.Steps Invoke-OdooBin -Times 0
        }
    }

    Describe 'Install-OdooService' {
        BeforeEach {
            $paths = New-TestPaths
            New-Item -ItemType Directory -Path $paths.Tools, $paths.Downloads -Force | Out-Null
            $winsw = Join-Path $paths.Downloads 'WinSW-x64.exe'
            Set-Content -Path $winsw -Value 'exe'
            Mock -ModuleName OdooSetup.Steps Invoke-Download { $winsw }
            Mock -ModuleName OdooSetup.Steps Invoke-Native { 0 }
            Mock -ModuleName OdooSetup.Steps Invoke-Tool { New-ToolResult }
            Mock -ModuleName OdooSetup.Steps Get-Service { $null }
            Mock -ModuleName OdooSetup.Steps Get-CimInstance { [pscustomobject]@{ Name = 'odoo' } }
            Mock -ModuleName OdooSetup.Steps Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0 } }
            Mock -ModuleName OdooSetup.Steps Get-NetworkServiceAccountName { 'NT AUTHORITY\NETWORK SERVICE' }
            Mock -ModuleName OdooSetup.Steps Start-ServiceSafe {}
            Mock -ModuleName OdooSetup.Steps Test-OdooHttp { $true }
            Mock -ModuleName OdooSetup.Steps Stop-ServiceSafe {}
            Mock -ModuleName OdooSetup.Steps Start-Sleep {}
            Remove-Item (Join-Path $paths.Tools 'odoo-service.exe') -Force -ErrorAction SilentlyContinue
        }
        It 'starts at boot in production (<Mode> -> <Start>)' -ForEach @(
            @{ Mode = 'prod'; Start = 'auto' }, @{ Mode = 'dev'; Start = 'demand' }
        ) {
            Install-OdooService -Paths $paths -Components $components -Settings @{ Mode = $Mode; OdooVersion = '19.0'; HttpPort = 8069 }
            Should -Invoke -ModuleName OdooSetup.Steps Invoke-Tool -Times 1 -ParameterFilter {
                $FilePath -eq 'sc.exe' -and ($ArgumentList -join ' ') -eq ('config odoo start= {0}' -f $Start)
            }
            Should -Invoke -ModuleName OdooSetup.Steps Invoke-Tool -Times 1 -ParameterFilter {
                ($ArgumentList -join ' ') -eq 'config odoo depend= OdooPostgreSQL'
            }
        }
        It 'writes WinSW XML with escaped paths and restart-on-failure' {
            $paths.OdooSrc = Join-Path $TestDrive 'R&D <src>'
            Install-OdooService -Paths $paths -Components $components -Settings @{ Mode = 'prod'; OdooVersion = '19.0'; HttpPort = 8069 }
            $xml = [xml](Get-Content -Raw (Join-Path $paths.Tools 'odoo-service.xml'))
            $xml.service.id | Should -Be 'odoo'
            $xml.service.workingdirectory | Should -Be $paths.OdooSrc
            @($xml.service.onfailure).Count | Should -Be 3
            Should -Invoke -ModuleName OdooSetup.Steps Invoke-CimMethod -Times 1 -ParameterFilter { $Arguments.StartName -eq 'NT AUTHORITY\NETWORK SERVICE' }
        }
        It 'removes an existing service with sc.exe when the WinSW wrapper is gone' {
            Mock -ModuleName OdooSetup.Steps Get-Service { [pscustomobject]@{ Status = 'Running' } }
            Install-OdooService -Paths $paths -Components $components -Settings @{ Mode = 'prod'; OdooVersion = '19.0'; HttpPort = 8069 }
            Should -Invoke -ModuleName OdooSetup.Steps Stop-ServiceSafe -Times 1
            Should -Invoke -ModuleName OdooSetup.Steps Invoke-Tool -Times 1 -ParameterFilter { ($ArgumentList -join ' ') -eq 'delete odoo' }
        }
        It 'removes an existing service with the WinSW wrapper when it is there' {
            Set-Content -Path (Join-Path $paths.Tools 'odoo-service.exe') -Value 'old'
            Mock -ModuleName OdooSetup.Steps Get-Service { [pscustomobject]@{ Status = 'Running' } }
            Install-OdooService -Paths $paths -Components $components -Settings @{ Mode = 'prod'; OdooVersion = '19.0'; HttpPort = 8069 }
            Should -Invoke -ModuleName OdooSetup.Steps Invoke-Tool -Times 1 -ParameterFilter { $FilePath -like '*odoo-service.exe' -and $ArgumentList[0] -eq 'uninstall' }
            Should -Invoke -ModuleName OdooSetup.Steps Invoke-Tool -Times 0 -ParameterFilter { $ArgumentList[0] -eq 'delete' }
        }
        It 'fails with the error log path when Odoo never answers' {
            Mock -ModuleName OdooSetup.Steps Test-OdooHttp { $false }
            { Install-OdooService -Paths $paths -Components $components -Settings @{ Mode = 'prod'; OdooVersion = '19.0'; HttpPort = 8070 } } |
                Should -Throw '*did not answer on port 8070*odoo-service.err.log*'
        }
    }

    Describe 'Windows tweaks' {
        It 'Set-OdooFirewallRule opens the port on Domain and Private only' {
            Mock -ModuleName OdooSetup.Steps Get-NetFirewallRule { $null }
            Mock -ModuleName OdooSetup.Steps New-NetFirewallRule {}
            Mock -ModuleName OdooSetup.Steps Get-NetConnectionProfile { @() }
            Set-OdooFirewallRule -Port 8069
            Should -Invoke -ModuleName OdooSetup.Steps New-NetFirewallRule -Times 1 -ParameterFilter {
                $LocalPort -eq 8069 -and $Direction -eq 'Inbound' -and $Profile -notcontains 'Public'
            }
            Should -Invoke -ModuleName OdooSetup.Steps Write-Warn -Times 0
        }
        It 'Set-OdooFirewallRule warns when the network is Public' {
            Mock -ModuleName OdooSetup.Steps Get-NetFirewallRule { $null }
            Mock -ModuleName OdooSetup.Steps New-NetFirewallRule {}
            Mock -ModuleName OdooSetup.Steps Get-NetConnectionProfile { [pscustomobject]@{ Name = 'Cafe WiFi'; NetworkCategory = 'Public' } }
            Set-OdooFirewallRule -Port 8069
            Should -Invoke -ModuleName OdooSetup.Steps Write-Warn -ParameterFilter { $Message -like '*Cafe WiFi*' }
        }
        It 'Set-DefenderExclusions returns false instead of failing without Defender' {
            Mock -ModuleName OdooSetup.Steps Add-MpPreference { throw 'not available' }
            Set-DefenderExclusions -Paths (New-TestPaths) | Should -BeFalse
        }
        It 'Disable-SleepOnAC turns off standby and hibernate on mains power' {
            Mock -ModuleName OdooSetup.Steps Invoke-Tool { New-ToolResult }
            Disable-SleepOnAC
            Should -Invoke -ModuleName OdooSetup.Steps Invoke-Tool -Times 2 -ParameterFilter { $FilePath -eq 'powercfg.exe' -and $ArgumentList[2] -eq '0' }
        }
    }
}
