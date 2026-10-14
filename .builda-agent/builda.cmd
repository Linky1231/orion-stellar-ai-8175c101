@echo off
setlocal
set "BUILDA_WINDOWS_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%BUILDA_WINDOWS_POWERSHELL%" (
  echo BUILDA_POWERSHELL_NOT_FOUND: Windows PowerShell 5.1 is required. 1>&2
  exit /b 2
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0builda.ps1" %*
exit /b %ERRORLEVEL%
