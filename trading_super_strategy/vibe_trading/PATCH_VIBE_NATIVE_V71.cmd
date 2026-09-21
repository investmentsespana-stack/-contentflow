@echo off
setlocal
cd /d "%~dp0"
echo [Cygnus Vibe Native V7.1] Repairing provider precedence and OAuth...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Patch-VibeNativeV71.ps1"
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (
  echo CYGNUS_VIBE_NATIVE_V71=PASS
) else (
  echo CYGNUS_VIBE_NATIVE_V71=FAILED code %RC%
)
echo.
pause
exit /b %RC%
