# Unattended install answers. Copy, edit, then run (as Administrator):
#   powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Action Install -ConfigFile .\my-answers.psd1
# Anything left out uses the interactive default.
# Reseller package (one ZIP, no questions): .\reseller\New-ResellerPackage.ps1 -AnswersFile .\my-answers.psd1
@{
    Root          = 'C:\Odoo'
    Mode          = 'prod'            # 'prod' or 'dev'
    OdooVersion   = '19.0'            # '18.0', '19.0' or '20.0'
    RamProfile    = '8GB'             # '4GB', '8GB' or '16GB' (default: detected)
    CompanyName   = 'My Company'
    DbName        = 'mycompany'
    AdminLogin    = 'admin@example.com'
    AdminPassword = ''                # empty = generate (see conf\CREDENTIALS.txt)
    UiLanguage    = 'ar_001'          # 'ar_001' (Arabic) or 'en_US'
    Apps          = @('accounting', 'sales', 'purchase', 'inventory')
    OcaBundles    = @('ux', 'reports', 'mis', 'reconcile')
    WithDemo      = $false            # development only
    Defender      = $true
    DisableSleep  = $true
    MakeNetworkPrivate = $false
    Backup        = @{ Enabled = $true; Dir = 'D:\OdooBackups'; Time = '22:00'; RetentionDays = 14 }
    # Production only. Windows Update will not restart the PC between Start and End (hours 0-23, at most 18 apart).
    ActiveHours   = @{ Enabled = $true; Start = 8; End = 23 }
    HealthCheck   = $true             # production: restart Odoo if it stops answering (checked every 5 minutes)
}
