@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Patch-VibeNativeV73.ps1"
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (
  echo CYGNUS_VIBE_NATIVE_V73_WRAPPER=PASS
) else (
  echo CYGNUS_VIBE_NATIVE_V73_WRAPPER=FAIL rc=%RC%
)
echo SQX_TOUCHED=false
echo GOLD_TOUCHED=false
pause
exit /b %RC%
