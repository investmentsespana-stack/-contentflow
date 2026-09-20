@echo off
setlocal
cd /d "%~dp0"
echo [Cygnus Research V5] Starting fail-closed research update...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-ResearchV5.ps1"
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" (
  echo [Cygnus Research V5] FAILED with code %RC%.
  echo Existing pairing/config is preserved.
) else (
  echo [Cygnus Research V5] Update launched successfully.
  echo The queued NQ6 research-only smoke command will execute automatically.
)
echo.
pause
exit /b %RC%
