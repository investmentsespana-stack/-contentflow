@echo off
setlocal
cd /d "%~dp0"
echo [Cygnus V6.1] Applying Vibe swarm launch hotfix...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0PATCH_VIBE_V61.ps1"
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" (
  echo [Cygnus V6.1] FAILED with code %RC%.
) else (
  echo [Cygnus V6.1] PASS. StrategyQuant and GOLD were not touched.
)
echo.
pause
exit /b %RC%
