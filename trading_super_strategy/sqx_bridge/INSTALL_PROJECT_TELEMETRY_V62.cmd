@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-ProjectTelemetryV62.ps1"
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (
  echo CYGNUS_SQX_BRIDGE_V62_WRAPPER=PASS
) else (
  echo CYGNUS_SQX_BRIDGE_V62_WRAPPER=FAIL rc=%RC%
)
echo SQX_PROCESS_TOUCHED=false
echo GOLD_TOUCHED=false
pause
exit /b %RC%
