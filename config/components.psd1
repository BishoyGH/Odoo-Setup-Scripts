# Pinned third-party components.
# Sha256 is checked when present. Leave it empty only for URLs that always
# serve the latest build (Microsoft VC++ runtime, Google Chrome) or that are
# generated on the fly (GitHub branch archives).
@{
    Python = @{
        Version = '3.12.10'
        Url     = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe'
        Sha256  = ''
        # Same Python as a plain package, used when another Python 3.12 is already
        # installed on the PC (the .exe above would modify that one instead).
        NuGetUrl    = 'https://www.nuget.org/api/v2/package/python/3.12.10'
        NuGetSha256 = ''
    }
    PostgreSQL = @{
        Version = '17.6'
        Url     = 'https://get.enterprisedb.com/postgresql/postgresql-17.6-1-windows-x64-binaries.zip'
        Sha256  = ''
    }
    Wkhtmltopdf = @{
        Version = '0.12.6-1'
        Url     = 'https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox-0.12.6-1.msvc2015-win64.exe'
        Sha256  = '1efcfaf8472871268fd399865a3e62b435b91d4413009b80830eaaff7a57d088'
    }
    WinSW = @{
        Version = '2.12.0'
        Url     = 'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe'
        Sha256  = '05b82d46ad331cc16bdc00de5c6332c1ef818df8ceefcd49c726553209b3a0da'
    }
    VCRedist = @{
        Version = '14 (2015-2022)'
        Url     = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
        Sha256  = ''
    }
    Chrome = @{
        Version = 'latest stable'
        Url     = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
        Sha256  = ''
    }
    # {0} = branch, e.g. 19.0
    OdooSourceUrl = 'https://codeload.github.com/odoo/odoo/zip/refs/heads/{0}'
    # {0} = repository, {1} = branch
    OcaSourceUrl  = 'https://codeload.github.com/OCA/{0}/zip/refs/heads/{1}'

    OdooVersions   = @('18.0', '19.0', '20.0')
    DefaultVersion = '19.0'
}
