@echo off
setlocal
cd /d "%~dp0"
echo [Cygnus Vibe Native V7] OpenAI Codex OAuth authorization
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Authorize-VibeCodex.ps1"
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (
  echo VIBE_NATIVE_OAUTH_AND_PREFLIGHT=PASS
) else (
  echo VIBE_NATIVE_OAUTH_AND_PREFLIGHT=FAILED code %RC%
)
echo.
pause
exit /b %RC%
