@echo off
setlocal
cd /d "%~dp0"
echo [Cygnus V6.2] Installing deterministic Vibe strategy research fallback...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0PATCH_VIBE_V62.ps1"
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" (
  echo [Cygnus V6.2] FAILED with code %RC%.
) else (
  echo [Cygnus V6.2] PASS. No Bridge, MCP, StrategyQuant or GOLD restart was performed.
)
echo.
pause
exit /b %RC%
