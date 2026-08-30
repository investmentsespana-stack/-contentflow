@echo off
setlocal
title Jarvis Desktop
cd /d "%~dp0"

echo.
echo ========================================
echo        JARVIS DESKTOP - WINDOWS
echo ========================================
echo.

where node >nul 2>&1
if errorlevel 1 (
  echo [FALTA NODE.JS] Jarvis necesita Node.js.
  pause
  exit /b 2
)

if not exist "src\jarvis\server.mjs" (
  echo [ERROR] No encuentro src\jarvis\server.mjs
  pause
  exit /b 1
)
if not exist "src\jarvis\ui.html" (
  echo [ERROR] No encuentro src\jarvis\ui.html
  pause
  exit /b 1
)

for /f "delims=" %%V in ('node --version 2^>nul') do set "NODE_VERSION=%%V"
echo [OK] Node.js %NODE_VERSION%
echo [OK] Iniciando Jarvis en http://127.0.0.1:4317
echo.
start "" "http://127.0.0.1:4317"
node "src\jarvis\server.mjs"

echo.
echo Jarvis se detuvo. Revisa el mensaje anterior.
pause
