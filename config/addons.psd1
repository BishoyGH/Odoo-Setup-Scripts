# Odoo apps and OCA (Odoo Community Association) bundles offered by the installer.
# Modules that do not exist for the chosen Odoo version are skipped with a warning.
@{
    # Official Odoo Community apps. 'Default' = pre-selected in the menu.
    Apps = @(
        @{ Key = 'accounting'; Name = 'Invoicing & Accounting (Egyptian chart of accounts)'; Modules = @('account', 'l10n_eg'); Default = $true }
        @{ Key = 'sales';      Name = 'Sales';               Modules = @('sale_management');                       Default = $true }
        @{ Key = 'purchase';   Name = 'Purchase';            Modules = @('purchase');                              Default = $true }
        @{ Key = 'inventory';  Name = 'Inventory';           Modules = @('stock');                                 Default = $true }
        @{ Key = 'pos';        Name = 'Point of Sale';       Modules = @('point_of_sale');                         Default = $false }
        @{ Key = 'crm';        Name = 'CRM';                 Modules = @('crm');                                   Default = $false }
        @{ Key = 'hr';         Name = 'Employees, Time Off & Attendance'; Modules = @('hr', 'hr_holidays', 'hr_attendance'); Default = $false }
        @{ Key = 'project';    Name = 'Project & Timesheets'; Modules = @('project', 'hr_timesheet');             Default = $false }
        @{ Key = 'eta';        Name = 'Egyptian e-Invoicing (ETA) - needs USB token setup'; Modules = @('l10n_eg_edi_eta'); Default = $false }
    )

    # OCA bundles fill gaps in Odoo Community.
    # Repos lists every OCA repository needed, including repositories that only provide dependencies.
    OcaBundles = @(
        @{
            Key = 'ux'; Name = 'Better UI: responsive menu, resizable dialogs, refresh button, no Enterprise ads'
            Default = $true
            Repos = @('web', 'server-brand')
            Modules = @('web_responsive', 'web_dialog_size', 'web_refresher', 'remove_odoo_enterprise', 'disable_odoo_online')
        }
        @{
            Key = 'reports'; Name = 'Financial reports: General Ledger, Trial Balance, Aged Partner, VAT report'
            Default = $true
            Repos = @('account-financial-reporting', 'reporting-engine', 'server-ux')
            Modules = @('account_financial_report', 'account_tax_balance')
        }
        @{
            Key = 'mis'; Name = 'MIS Builder: Profit & Loss / Balance Sheet templates'
            Default = $true
            Repos = @('mis-builder', 'reporting-engine', 'server-ux')
            Modules = @('mis_builder')
        }
        @{
            Key = 'reconcile'; Name = 'Bank statements & reconciliation widget'
            Default = $true
            Repos = @('account-reconcile')
            Modules = @('account_statement_base', 'account_reconcile_oca')
        }
        @{
            Key = 'assets'; Name = 'Fixed assets & depreciation'
            Default = $false
            Repos = @('account-financial-tools', 'reporting-engine')
            Modules = @('account_asset_management')
        }
        @{
            # l10n_eg_payroll_oss ships in this repository (addons\) and adds the Egyptian rules.
            Key = 'payroll'; Name = 'Payroll with Egyptian rules: social insurance, salary tax, Martyrs Fund'
            Default = $false
            Repos = @('payroll')
            Modules = @('payroll', 'payroll_account', 'l10n_eg_payroll_oss')
        }
        @{
            Key = 'devribbon'; Name = 'Environment ribbon (shows DEV banner)'
            Default = $false; DevOnly = $true
            Repos = @('web')
            Modules = @('web_environment_ribbon')
        }
    )
}
