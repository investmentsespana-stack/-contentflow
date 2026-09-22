param(
  [string]$PackageRoot = $PSScriptRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Assert-Admin {
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  $p=New-Object Security.Principal.WindowsPrincipal($id)
  if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'ABRE POWERSHELL COMO ADMINISTRADOR Y VUELVE A PEGAR EL PARCHE'
  }
}

Assert-Admin
if($env:COMPUTERNAME -ne 'WIN-31RCI8K7JR2'){
  throw "VPS_INCORRECTO:$env:COMPUTERNAME"
}

$required=@(
  'CygnusSQXBridge.exe',
  'asset_research.py',
  'tradingview_futures_guard.py',
  'vibe_full_preflight.py',
  'cygnus_native_smoke.yaml',
  'cygnus_futures_strategy_lab.yaml',
  'cygnus_dxy_macro_lab.yaml',
  'Start-VibeNative.ps1',
  'Stop-VibeNative.ps1'
)
foreach($name in $required){
  if(-not (Test-Path (Join-Path $PackageRoot $name) -PathType Leaf)){
    throw "ARCHIVO_FALTANTE:$name"
  }
}

$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$vibeRoot='C:\Cygnus\VibeTrading'
$vibePython=Join-Path $vibeRoot '.venv\Scripts\python.exe'
if(-not (Test-Path $vibePython -PathType Leaf)){
  throw "VIBE_PYTHON_NO_ENCONTRADO:$vibePython"
}

$config=Join-Path $env:APPDATA 'CygnusSQXBridge\config.json'
if(-not (Test-Path $config -PathType Leaf)){
  throw "PAIRING_CONFIG_NO_ENCONTRADO:$config"
}

$bridgeProc=Get-CimInstance Win32_Process -Filter "Name='CygnusSQXBridge.exe'" | Select-Object -First 1
$currentBridge=$null
if($bridgeProc -and $bridgeProc.ExecutablePath){
  $currentBridge=[string]$bridgeProc.ExecutablePath
}
if(-not $currentBridge){
  $currentBridge='C:\Cygnus\SQXBridge\CygnusSQXBridge.exe'
}
$bridgeRoot=Split-Path $currentBridge -Parent
New-Item -ItemType Directory -Force $bridgeRoot | Out-Null

$backupRoot=Join-Path $env:APPDATA ("CygnusSQXBridge\upgrade-backup-"+$stamp)
New-Item -ItemType Directory -Force $backupRoot | Out-Null

if(Test-Path $currentBridge){
  Copy-Item $currentBridge (Join-Path $backupRoot 'CygnusSQXBridge.exe') -Force
}

Get-Process -Name 'CygnusSQXBridge' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$newExe=Join-Path $PackageRoot 'CygnusSQXBridge.exe'
$expectedExeHash=(Get-FileHash $newExe -Algorithm SHA256).Hash
$tmpExe=$currentBridge+'.cygnus_tmp'
Copy-Item $newExe $tmpExe -Force
if((Get-FileHash $tmpExe -Algorithm SHA256).Hash -ne $expectedExeHash){
  throw 'HASH_DEL_PUENTE_NO_COINCIDE'
}
Move-Item $tmpExe $currentBridge -Force

foreach($name in @(
  'asset_research.py',
  'tradingview_futures_guard.py',
  'vibe_full_preflight.py',
  'Start-VibeNative.ps1',
  'Stop-VibeNative.ps1'
)){
  $src=Join-Path $PackageRoot $name
  $dest=Join-Path $vibeRoot $name
  if(Test-Path $dest){
    Copy-Item $dest (Join-Path $backupRoot $name) -Force
  }
  $tmp=$dest+'.cygnus_tmp'
  Copy-Item $src $tmp -Force
  Move-Item $tmp $dest -Force
}

$presetUser=Join-Path $HOME '.vibe-trading\swarm\presets'
$presetState=Join-Path $vibeRoot 'state\swarm\presets'
New-Item -ItemType Directory -Force $presetUser,$presetState | Out-Null

foreach($name in @(
  'cygnus_native_smoke.yaml',
  'cygnus_futures_strategy_lab.yaml',
  'cygnus_dxy_macro_lab.yaml'
)){
  $src=Join-Path $PackageRoot $name
  Copy-Item $src (Join-Path $presetUser $name) -Force
  Copy-Item $src (Join-Path $presetState $name) -Force
}

$compileArgs=@(
  '-m','py_compile',
  (Join-Path $vibeRoot 'tradingview_futures_guard.py'),
  (Join-Path $vibeRoot 'asset_research.py'),
  (Join-Path $vibeRoot 'vibe_full_preflight.py')
)
& $vibePython @compileArgs
if($LASTEXITCODE -ne 0){
  throw 'VIBE_COMPILE_FAIL'
}

$stopVibe=Join-Path $vibeRoot 'Stop-VibeNative.ps1'
$startVibe=Join-Path $vibeRoot 'Start-VibeNative.ps1'
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $stopVibe | Out-Host
Start-Sleep -Seconds 2
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $startVibe | Out-Host
if($LASTEXITCODE -ne 0){
  throw 'VIBE_RESTART_FAIL'
}

$newProc=Start-Process -FilePath $currentBridge -WorkingDirectory $bridgeRoot -PassThru
Start-Sleep -Seconds 8
if($newProc.HasExited){
  throw "PUENTE_SE_CERRO:$($newProc.ExitCode)"
}

Write-Host ''
Write-Host '============================================'
Write-Host 'CYGNUS BRIDGE V6.4 INSTALADO'
Write-Host 'PASS_LOCAL=true'
Write-Host "VPS=$env:COMPUTERNAME"
Write-Host "BRIDGE_PATH=$currentBridge"
Write-Host "BRIDGE_SHA256=$($expectedExeHash.ToLower())"
Write-Host "BRIDGE_PID=$($newProc.Id)"
Write-Host 'VIBE_SYNC=true'
Write-Host 'RESEARCH_ONLY=true'
Write-Host 'BROKER_EXECUTION=false'
Write-Host 'SQX_TOUCHED=false'
Write-Host '============================================'
