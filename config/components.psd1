# Pinned third-party components.
# Sha256 is checked when present. Leave it empty only for URLs that always
# serve the latest build (Microsoft VC++ runtime, Google Chrome) or that are
# generated on the fly (GitHub branch archives).
@{
    Python = @{
        Version = '3.12.10'
        Url     = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe'
        Sha256  = ''
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

    # Arabic fonts installed for all users so PDF invoices render Arabic cleanly
    # (Odoo's own Tajawal report font is selected for Arabic companies; these are the fallback).
    # Pinned to a commit of the official Noto fonts site, SIL Open Font License.
    ArabicFonts = @{
        BaseUrl = 'https://raw.githubusercontent.com/notofonts/notofonts.github.io/d14cc173a70dc57962ed2d4ad278fc9df83bf9f3/fonts/'
        Files   = @(
            @{ Family = 'Noto Naskh Arabic'; Style = 'Regular'; Path = 'NotoNaskhArabic/hinted/ttf/NotoNaskhArabic-Regular.ttf'; Sha256 = '6f0a92031367b2f5a2078fe9d24f3433122b61a0bad57c423aad8f3c39aa2e6e' }
            @{ Family = 'Noto Naskh Arabic'; Style = 'Bold';    Path = 'NotoNaskhArabic/hinted/ttf/NotoNaskhArabic-Bold.ttf';    Sha256 = '04017b0ccdd1156dcde3bc386734c1b03165261762f16a025c8afc9088ae76e9' }
            @{ Family = 'Noto Kufi Arabic';  Style = 'Regular'; Path = 'NotoKufiArabic/hinted/ttf/NotoKufiArabic-Regular.ttf';   Sha256 = '76f539d38a44907365dbccc98466c9c607e74abbfd209add21a254a8ce8668da' }
            @{ Family = 'Noto Kufi Arabic';  Style = 'Bold';    Path = 'NotoKufiArabic/hinted/ttf/NotoKufiArabic-Bold.ttf';      Sha256 = '1feda69b8b77a5efd9c55f03081f309c8776b08030296638c519d154d9971447' }
        )
    }
}
