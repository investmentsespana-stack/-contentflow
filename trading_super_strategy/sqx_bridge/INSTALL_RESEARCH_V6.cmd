@echo off
setlocal
cd /d "%~dp0"
echo [Cygnus Research V6] Starting multi-asset research bridge update...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-ResearchV6.ps1"
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" (
  echo [Cygnus Research V6] FAILED with code %RC%.
  echo Existing pairing/config is preserved.
) else (
  echo [Cygnus Research V6] PASS.
  echo Multi-asset Vibe research can now be launched remotely.
)
echo.
pause
exit /b %RC%
