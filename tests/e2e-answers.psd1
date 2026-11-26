# Answers used by the Windows end-to-end workflow. __VERSION__ is replaced at run time.
@{
    Root          = 'C:\Odoo'
    Mode          = 'prod'
    OdooVersion   = '__VERSION__'
    RamProfile    = '8GB'
    CompanyName   = 'CI Test Company'
    DbName        = 'citest'
    AdminLogin    = 'admin'
    AdminPassword = 'CiTestPassword123'
    UiLanguage    = 'ar_001'
    Apps          = @('accounting', 'sales')
    OcaBundles    = @('ux', 'reports')
    Defender      = $false
    DisableSleep  = $false
    Backup        = @{ Enabled = $true; Dir = 'C:\OdooBackups'; Time = '22:00'; RetentionDays = 7; CopyDir = 'C:\OdooBackupsCopy'; TestRestoreDays = 7 }
}
