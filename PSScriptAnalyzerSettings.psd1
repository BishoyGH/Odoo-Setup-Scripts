@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Interactive installer: colored console output is the point.
        'PSAvoidUsingWriteHost'
        # Internal helpers, not a public module; -WhatIf adds noise without value here.
        'PSUseShouldProcessForStateChangingFunctions'
        # Generated alphanumeric secrets are passed to native tools (psql, initdb, odoo).
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingUsernameAndPasswordParams'
        # Names like Install-OcaRepos / Test-Prerequisites read better plural.
        'PSUseSingularNouns'
    )
    Rules        = @{
        # Must keep running on the Windows PowerShell 5.1 that ships with Windows 10/11.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
