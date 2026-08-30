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
  echo [FALTA NODE.JS]
  echo Jarvis necesita Node.js para arrancar.
  start "" "https://nodejs.org/en/download"
  pause
  exit /b 2
)

if not exist "src\jarvis" mkdir "src\jarvis"
echo [INFO] Actualizando Jarvis...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/investmentsespana-stack/-contentflow/main/src/jarvis/server.mjs' -OutFile 'src\jarvis\server.mjs'; Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/investmentsespana-stack/-contentflow/main/src/jarvis/ui.html' -OutFile 'src\jarvis\ui.html'" >nul 2>&1
if errorlevel 1 (
  echo [AVISO] No se pudo actualizar por Internet. Se intentara arrancar la copia local.
) else (
  echo [OK] Jarvis actualizado
)

if not exist "src\jarvis\server.mjs" (
  echo [ERROR] No encuentro src\jarvis\server.mjs
  pause
  exit /b 1
)

for /f "delims=" %%V in ('node --version 2^>nul') do set "NODE_VERSION=%%V"
echo [OK] Node.js %NODE_VERSION%
echo [OK] Iniciando en http://127.0.0.1:4317
echo.
start "" powershell -NoProfile -WindowStyle Hidden -Command "Start-Sleep -Seconds 2; Start-Process 'http://127.0.0.1:4317'"
node "src\jarvis\server.mjs"

echo.
echo Jarvis se detuvo. Revisa el mensaje anterior.
pause
