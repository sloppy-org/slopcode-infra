@echo off
if not defined DEST set "DEST=%USERPROFILE%\slopcode"
where pwsh >nul 2>&1 || (echo PowerShell 7 pwsh is required for meeting scripts. Install it from https://aka.ms/powershell & exit /b 1)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%DEST%\meeting\meeting-notes.ps1" %*
