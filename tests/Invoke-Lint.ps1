#Requires -Modules PSScriptAnalyzer
# Lints all PowerShell sources with the repository settings. Exits non-zero on findings.
$root = Split-Path $PSScriptRoot -Parent
$settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
$results = @(Invoke-ScriptAnalyzer -Path $root -Recurse -Settings $settings)
if ($results.Count -gt 0) {
    $results | Format-Table -AutoSize Severity, RuleName, ScriptName, Line, Message | Out-String -Width 220 | Write-Host
    Write-Error ('{0} PSScriptAnalyzer finding(s).' -f $results.Count)
    exit 1
}
Write-Host 'PSScriptAnalyzer: no findings.' -ForegroundColor Green
