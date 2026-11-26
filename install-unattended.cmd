@echo off
rem Reseller package: installs Odoo with no questions, using answers.psd1 next to this file.
rem Asks for Administrator rights automatically. Build a package with reseller\New-ResellerPackage.ps1.
setlocal
cd /d "%~dp0"
if not exist "%~dp0answers.psd1" (
    echo answers.psd1 was not found next to this file.
    echo Copy config\answers.example.psd1 to answers.psd1 and edit it, or use install.cmd for the interactive setup.
    pause
    exit /b 1
)
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
title Odoo Setup (unattended)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Action Install -ConfigFile "%~dp0answers.psd1"
set rc=%errorlevel%
echo.
if %rc% equ 0 (
    echo Finished. Passwords are in conf\CREDENTIALS.txt inside the install folder, C:\Odoo by default.
) else (
    echo Setup failed. Run this file again to resume; finished steps are skipped. Logs are in the install folder.
)
pause
exit /b %rc%
