@echo off
rem GT3 Revisited for Xbox: drag your GT3 disc image (.iso or .chd) onto this file, or double-click it.
setlocal
cd /d "%~dp0"
set "PWSH=pwsh"
where pwsh >/dev/null 2>nul
if not errorlevel 1 goto run
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
  set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
  goto run
)
echo PowerShell 7 is needed for the setup; installing it with winget (a minute)...
winget install --id Microsoft.PowerShell -e --silent --accept-source-agreements --accept-package-agreements
if not exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
  echo Could not install PowerShell 7. Install it from https://aka.ms/powershell and run this again.
  pause
  exit /b 1
)
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
:run
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
echo.
pause
