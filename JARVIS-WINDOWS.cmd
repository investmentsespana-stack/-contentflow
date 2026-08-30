@echo off
setlocal
title Jarvis Desktop
cd /d "%~dp0"

echo.
echo ========================================
echo        JARVIS DESKTOP - WINDOWS
echo ========================================
echo.

if not exist "src\jarvis\server.mjs" (
  echo [ERROR] No encuentro src\jarvis\server.mjs
  echo Coloca este archivo en la carpeta principal de ContentFlow.
  echo.
  pause
  exit /b 1
)

where node >nul 2>&1
if errorlevel 1 (
  echo [FALTA NODE.JS]
  echo Jarvis necesita Node.js para arrancar.
  echo Se abrira la pagina oficial de descarga.
  echo Instala la version LTS, vuelve aqui y haz doble clic otra vez.
  echo.
  start "" "https://nodejs.org/en/download"
  pause
  exit /b 2
)

for /f "delims=" %%V in ('node --version 2^>nul') do set "NODE_VERSION=%%V"
echo [OK] Node.js %NODE_VERSION%
echo [OK] Proyecto Jarvis encontrado
echo [OK] Iniciando en http://127.0.0.1:4317
echo.

start "" powershell -NoProfile -WindowStyle Hidden -Command "Start-Sleep -Seconds 2; Start-Process 'http://127.0.0.1:4317'"
node "src\jarvis\server.mjs"

echo.
echo Jarvis se detuvo. Revisa el mensaje anterior.
pause
