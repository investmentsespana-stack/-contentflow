$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if($env:COMPUTERNAME -ne 'WIN-31RCI8K7JR2'){ throw "VPS_INCORRECTO:$env:COMPUTERNAME" }

$stage=Get-ChildItem $env:TEMP -Directory -Filter 'CygnusBridgeV64-*' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if(-not $stage){ throw 'NO_ENCONTRE_DESCARGA_ANTERIOR' }
$srcDir=Join-Path $stage.FullName 'src'
$repoRoot=Get-ChildItem $srcDir -Directory | Select-Object -First 1
if(-not $repoRoot){ throw 'NO_ENCONTRE_REPOSITORIO_DESCARGADO' }
$sqx=Join-Path $repoRoot.FullName 'trading_super_strategy\sqx_bridge'
$vibeSource=Join-Path $repoRoot.FullName 'trading_super_strategy\vibe_trading'
$vibeRoot='C:\Cygnus\VibeTrading'
$py=Join-Path $vibeRoot '.venv\Scripts\python.exe'
if(-not (Test-Path $py)){ throw "PYTHON_VIBE_NO_ENCONTRADO:$py" }

Write-Host '3/8 Instalando PyInstaller en el entorno existente...'
& $py -m pip install --disable-pip-version-check pyinstaller
if($LASTEXITCODE -ne 0){ throw 'PYINSTALLER_INSTALL_FAIL' }

Write-Host '4/8 Ejecutando pruebas...'
Push-Location $sqx
try {
  & $py -m py_compile app.py
  if($LASTEXITCODE -ne 0){ throw 'APP_COMPILE_FAIL' }
  foreach($test in @('test_startup_gate.py','test_live_http_telemetry.py','test_resource_repair.py','test_vibe_nq6_bridge_gate.py','test_vibe_asset_bridge_gate.py')){
    Write-Host "TEST $test"
    & $py $test
    if($LASTEXITCODE -ne 0){ throw "TEST_FAIL:$test" }
  }
  Write-Host '5/8 Compilando puente V6.4...'
  & $py -m PyInstaller --noconfirm --clean --onefile --windowed --name CygnusSQXBridge --collect-all keyring app.py
  if($LASTEXITCODE -ne 0){ throw 'PYINSTALLER_FAIL' }
} finally { Pop-Location }

$newExe=Join-Path $sqx 'dist\CygnusSQXBridge.exe'
if(-not (Test-Path $newExe)){ throw 'EXE_NO_GENERADO' }
$newHash=(Get-FileHash $newExe -Algorithm SHA256).Hash.ToLower()

Write-Host '6/8 Sincronizando Vibe...'
foreach($name in @('asset_research.py','tradingview_futures_guard.py','vibe_full_preflight.py')){
  Copy-Item (Join-Path $vibeSource $name) (Join-Path $vibeRoot $name) -Force
}
$presetUser=Join-Path $HOME '.vibe-trading\swarm\presets'
$presetState=Join-Path $vibeRoot 'state\swarm\presets'
New-Item -ItemType Directory -Force $presetUser,$presetState | Out-Null
foreach($name in @('cygnus_native_smoke.yaml','cygnus_futures_strategy_lab.yaml','cygnus_dxy_macro_lab.yaml')){
  Copy-Item (Join-Path $vibeSource $name) (Join-Path $presetUser $name) -Force
  Copy-Item (Join-Path $vibeSource $name) (Join-Path $presetState $name) -Force
}
& $py -m py_compile (Join-Path $vibeRoot 'asset_research.py') (Join-Path $vibeRoot 'tradingview_futures_guard.py') (Join-Path $vibeRoot 'vibe_full_preflight.py')
if($LASTEXITCODE -ne 0){ throw 'VIBE_COMPILE_FAIL' }

Write-Host '7/8 Reemplazando puente...'
$proc=Get-CimInstance Win32_Process -Filter "Name='CygnusSQXBridge.exe'" | Select-Object -First 1
$currentBridge=$null
if($proc -and $proc.ExecutablePath){ $currentBridge=[string]$proc.ExecutablePath }
if(-not $currentBridge){ $currentBridge='C:\Cygnus\SQXBridge\CygnusSQXBridge.exe' }
$bridgeRoot=Split-Path $currentBridge -Parent
New-Item -ItemType Directory -Force $bridgeRoot | Out-Null
$stamp=Get-Date -Format 'yyyyMMddHHmmss'
if(Test-Path $currentBridge){ Copy-Item $currentBridge ($currentBridge+'.backup-'+$stamp) -Force }
Get-Process -Name CygnusSQXBridge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
$tmp=$currentBridge+'.cygnus_tmp'
Copy-Item $newExe $tmp -Force
if((Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower() -ne $newHash){ throw 'HASH_NUEVO_PUENTE_NO_COINCIDE' }
Move-Item $tmp $currentBridge -Force

Write-Host '8/8 Arrancando V6.4...'
$newProc=Start-Process -FilePath $currentBridge -WorkingDirectory $bridgeRoot -PassThru
Start-Sleep -Seconds 10
if($newProc.HasExited){ throw "PUENTE_SE_CERRO:$($newProc.ExitCode)" }

Write-Host ''
Write-Host '============================================'
Write-Host 'CYGNUS BRIDGE V6.4 INSTALADO'
Write-Host 'PASS_LOCAL=true'
Write-Host "BRIDGE_PID=$($newProc.Id)"
Write-Host "BRIDGE_SHA256=$newHash"
Write-Host 'VIBE_SYNC=true'
Write-Host 'RESEARCH_ONLY=true'
Write-Host 'BROKER_EXECUTION=false'
Write-Host 'ARBITRARY_SHELL=false'
Write-Host 'SQX_TOUCHED=false'
Write-Host '============================================'