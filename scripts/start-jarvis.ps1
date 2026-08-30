$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Host 'Node.js no está instalado. Instala Node.js 22 LTS y vuelve a ejecutar este archivo.' -ForegroundColor Yellow
  exit 1
}
$env:JARVIS_HOST = '127.0.0.1'
if (-not $env:JARVIS_PORT) { $env:JARVIS_PORT = '4317' }
Write-Host 'Iniciando Jarvis Desktop...' -ForegroundColor Cyan
Start-Process "http://127.0.0.1:$($env:JARVIS_PORT)"
node src/jarvis/server.mjs
