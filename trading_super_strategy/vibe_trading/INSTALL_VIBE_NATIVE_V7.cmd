@echo off
setlocal
cd /d "%~dp0"
echo [Cygnus Vibe Native V7] Installing full native-agent operability...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-VibeNativeV7.ps1"
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (
  echo CYGNUS_VIBE_NATIVE_V7=PASS
) else (
  echo CYGNUS_VIBE_NATIVE_V7 requires the OAuth step or reported preflight repair.
  echo If the output showed OAUTH_READY=false, run AUTHORIZE_VIBE_CODEX.cmd.
)
echo.
pause
exit /b %RC%
