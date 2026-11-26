# Console UI helpers: colors, banner, prompts and menus.
# Plain ASCII only so it renders on any Windows PowerShell 5.1 console font.

Set-StrictMode -Version 2.0

$script:StepIndex = 0
$script:StepTotal = 0
$script:UiLanguage = 'en'
$script:UiStrings = @{}

# ------------------------------------------------------------ language -----
# Translations live in config\i18n\<lang>.json (UTF-8), keyed by the English text,
# so these .psm1 files stay pure ASCII for Windows PowerShell 5.1.

function Get-UiStringsPath {
    param([Parameter(Mandatory)][string]$Language)
    $root = Split-Path $PSScriptRoot -Parent
    return (Join-Path (Join-Path (Join-Path $root 'config') 'i18n') ($Language + '.json'))
}

function Import-UiStrings {
    <# Returns the translation table for a language as a hashtable ('en' is empty: English is the key). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Language)
    $table = @{}
    if ($Language -eq 'en') { return $table }
    $path = Get-UiStringsPath -Language $Language
    if (-not (Test-Path $path)) { return $table }
    $json = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($p in $json.PSObject.Properties) { $table[$p.Name] = $p.Value }
    return $table
}

function Set-UiLanguage {
    <# 'en' = English only. 'ar' = Arabic prompts with the English text underneath. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('en', 'ar')][string]$Language)
    $script:UiStrings = Import-UiStrings -Language $Language
    $script:UiLanguage = $Language
    if ($Language -ne 'en' -and $script:UiStrings.Count -eq 0) { $script:UiLanguage = 'en' }
    if ($script:UiLanguage -ne 'en') {
        try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { Write-Verbose 'Console encoding unchanged.' }
    }
}

function Get-UiLanguage { return $script:UiLanguage }

function Get-DefaultUiLanguage {
    <# Arabic when Windows itself is in Arabic, otherwise English. #>
    param([string]$CultureName = (Get-UICulture).Name)
    if ($CultureName -like 'ar*') { return 'ar' }
    return 'en'
}

function Get-UiText {
    <#
      Translates an English UI string (exact match) and fills {0} placeholders.
      Unknown strings come back in English, so a missing translation never breaks a prompt.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(ValueFromRemainingArguments)][object[]]$FormatArgs)
    $out = $Text
    if ($script:UiLanguage -ne 'en' -and $Text -and $script:UiStrings.ContainsKey($Text)) { $out = [string]$script:UiStrings[$Text] }
    if ($FormatArgs -and $FormatArgs.Count -gt 0) { $out = $out -f $FormatArgs }
    return $out
}

function Test-UiTranslated {
    param([AllowEmptyString()][string]$Text)
    return ($script:UiLanguage -ne 'en' -and $Text -and $script:UiStrings.ContainsKey($Text))
}

function Write-EnglishHint {
    <# In Arabic mode, repeats the English original in grey so the question is clear even if Arabic renders poorly. #>
    param([AllowEmptyString()][string]$Text, [string]$Indent = '     ')
    if (Test-UiTranslated $Text) { Write-Host ($Indent + $Text) -ForegroundColor DarkGray }
}

function Test-YesAnswer {
    param([AllowEmptyString()][string]$Answer)
    $yes = @('y', 'yes')
    if ($script:UiStrings.ContainsKey('_yes')) { $yes += @($script:UiStrings['_yes']) }
    return ($yes -contains $Answer)
}

function Test-NoAnswer {
    param([AllowEmptyString()][string]$Answer)
    $no = @('n', 'no')
    if ($script:UiStrings.ContainsKey('_no')) { $no += @($script:UiStrings['_no']) }
    return ($no -contains $Answer)
}

function Write-Banner {
    [CmdletBinding()]
    param([string]$Subtitle = 'Native Odoo setup for Windows 10/11')
    $art = @(
        '   ___      _               ____       _               '
        '  / _ \  __| | ___   ___   / ___|  ___| |_ _   _ _ __  '
        ' | | | |/ _` |/ _ \ / _ \  \___ \ / _ \ __| | | | ''_ \ '
        ' | |_| | (_| | (_) | (_) |  ___) |  __/ |_| |_| | |_) |'
        '  \___/ \__,_|\___/ \___/  |____/ \___|\__|\__,_| .__/ '
        '                                                |_|    '
    )
    Write-Host ''
    $colors = @('Magenta', 'Magenta', 'DarkMagenta', 'DarkMagenta', 'Cyan', 'Cyan')
    for ($i = 0; $i -lt $art.Count; $i++) { Write-Host $art[$i] -ForegroundColor $colors[$i] }
    Write-Host ('  ' + $Subtitle) -ForegroundColor White
    Write-Host '  Made for Egyptian small businesses  |  No Docker  |  4 GB / 8 GB tuned' -ForegroundColor DarkGray
    Write-Host ''
}

function Write-Section {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title)
    $line = '=' * [Math]::Max(60, $Title.Length + 4)
    Write-Host ''
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ('  ' + (Get-UiText $Title)) -ForegroundColor Cyan
    Write-EnglishHint $Title -Indent '  '
    Write-Host $line -ForegroundColor DarkCyan
}

function Initialize-StepCounter {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Total)
    $script:StepIndex = 0
    $script:StepTotal = $Total
}

function Write-Step {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title)
    $script:StepIndex++
    Write-Host ''
    Write-Host ('[{0}/{1}] ' -f $script:StepIndex, $script:StepTotal) -ForegroundColor Yellow -NoNewline
    Write-Host $Title -ForegroundColor White
}

function Write-Ok   { param([string]$Message) Write-Host '   [ OK ] ' -ForegroundColor Green -NoNewline; Write-Host $Message }
function Write-Info { param([string]$Message) Write-Host '   [....] ' -ForegroundColor Cyan -NoNewline; Write-Host $Message -ForegroundColor Gray }
function Write-Skip { param([string]$Message) Write-Host '   [SKIP] ' -ForegroundColor DarkGreen -NoNewline; Write-Host $Message -ForegroundColor DarkGray }
function Write-Warn { param([string]$Message) Write-Host '   [WARN] ' -ForegroundColor Yellow -NoNewline; Write-Host $Message -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host '   [FAIL] ' -ForegroundColor Red -NoNewline; Write-Host $Message -ForegroundColor Red }

function Write-KeyValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Value, [int]$Width = 24)
    Write-Host ('   ' + (Get-UiText $Key).PadRight($Width)) -ForegroundColor DarkCyan -NoNewline
    Write-Host $Value -ForegroundColor White
}

function Read-Value {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default = '',
        [scriptblock]$Validate,
        [string]$ValidationMessage = 'Invalid value, please try again.'
    )
    while ($true) {
        Write-EnglishHint $Prompt
        Write-Host ('   ? ' + (Get-UiText $Prompt)) -ForegroundColor Magenta -NoNewline
        if ($Default -ne '') { Write-Host (' [' + $Default + ']') -ForegroundColor DarkGray -NoNewline }
        Write-Host ': ' -NoNewline
        $answer = Read-Host
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
        $answer = $answer.Trim()
        if (-not $Validate -or (& $Validate $answer)) { return $answer }
        Write-Warn (Get-UiText $ValidationMessage)
    }
}

function Read-YesNo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prompt, [bool]$Default = $true)
    $hint = 'y/N'
    if ($Default) { $hint = 'Y/n' }
    while ($true) {
        Write-EnglishHint $Prompt
        Write-Host ('   ? ' + (Get-UiText $Prompt)) -ForegroundColor Magenta -NoNewline
        Write-Host (' [' + $hint + ']: ') -ForegroundColor DarkGray -NoNewline
        $answer = (Read-Host).Trim().ToLowerInvariant()
        if ($answer -eq '') { return $Default }
        if (Test-YesAnswer $answer) { return $true }
        if (Test-NoAnswer $answer) { return $false }
        Write-Warn (Get-UiText 'Please answer y or n.')
    }
}

function Read-Choice {
    <# Returns the zero-based index of the chosen option. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$Options,
        [int]$DefaultIndex = 0
    )
    Write-EnglishHint $Prompt
    Write-Host ('   ? ' + (Get-UiText $Prompt)) -ForegroundColor Magenta
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $marker = '  '
        $color = 'Gray'
        if ($i -eq $DefaultIndex) { $marker = '> '; $color = 'White' }
        Write-Host ('     ' + $marker) -ForegroundColor Green -NoNewline
        Write-Host ('{0}) ' -f ($i + 1)) -ForegroundColor Yellow -NoNewline
        Write-Host (Get-UiText $Options[$i]) -ForegroundColor $color
    }
    $max = $Options.Count
    $answer = Read-Value -Prompt (Get-UiText 'Choose 1-{0}' $max) -Default ([string]($DefaultIndex + 1)) -Validate {
        param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le $max
    }.GetNewClosure()
    return ([int]$answer - 1)
}

function Read-MultiChoice {
    <#
      Toggle menu. Items are hashtables with Key, Name and Default.
      Returns the keys of the selected items.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prompt, [Parameter(Mandatory)][object[]]$Items)
    $selected = @{}
    foreach ($item in $Items) { $selected[$item.Key] = [bool]$item.Default }
    while ($true) {
        Write-EnglishHint $Prompt
        Write-Host ('   ? ' + (Get-UiText $Prompt)) -ForegroundColor Magenta
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $on = $selected[$Items[$i].Key]
            $box = '[ ]'; $color = 'DarkGray'
            if ($on) { $box = '[x]'; $color = 'White' }
            Write-Host ('     {0,2}) ' -f ($i + 1)) -ForegroundColor Yellow -NoNewline
            Write-Host ($box + ' ') -ForegroundColor Green -NoNewline
            Write-Host (Get-UiText $Items[$i].Name) -ForegroundColor $color
        }
        Write-Host ('     ' + (Get-UiText 'Type numbers to toggle (e.g. 2 5), A = all, N = none, Enter = accept')) -ForegroundColor DarkGray
        Write-Host '   > ' -ForegroundColor Magenta -NoNewline
        $answer = (Read-Host).Trim()
        if ($answer -eq '') { break }
        if ($answer -ieq 'a') { foreach ($item in $Items) { $selected[$item.Key] = $true }; continue }
        if ($answer -ieq 'n') { foreach ($item in $Items) { $selected[$item.Key] = $false }; continue }
        foreach ($token in ($answer -split '[\s,]+')) {
            $n = 0
            if ([int]::TryParse($token, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) {
                $key = $Items[$n - 1].Key
                $selected[$key] = -not $selected[$key]
            }
        }
    }
    return @($Items | Where-Object { $selected[$_.Key] } | ForEach-Object { $_.Key })
}

function Read-Password {
    <# Returns a plain string. Empty input returns '' so the caller can generate one. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prompt, [int]$MinLength = 8)
    while ($true) {
        Write-EnglishHint $Prompt
        Write-Host ('   ? ' + (Get-UiText $Prompt) + ' ' + (Get-UiText '(Enter = generate a strong one)') + ': ') -ForegroundColor Magenta -NoNewline
        $first = Read-Host -AsSecureString
        $plain = ConvertFrom-SecureStringPlain $first
        if ($plain -eq '') { return '' }
        if ($plain.Length -lt $MinLength) { Write-Warn (Get-UiText 'Use at least {0} characters.' $MinLength); continue }
        Write-Host ('   ? ' + (Get-UiText 'Repeat password') + ': ') -ForegroundColor Magenta -NoNewline
        $second = ConvertFrom-SecureStringPlain (Read-Host -AsSecureString)
        if ($plain -ceq $second) { return $plain }
        Write-Warn (Get-UiText 'Passwords do not match.')
    }
}

function ConvertFrom-SecureStringPlain {
    param([System.Security.SecureString]$Secure)
    if (-not $Secure) { return '' }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Wait-AnyKey {
    param([string]$Message = 'Press Enter to continue...')
    Write-Host ''
    Write-Host ('   ' + (Get-UiText $Message)) -ForegroundColor DarkGray -NoNewline
    [void](Read-Host)
}

Export-ModuleMember -Function *
