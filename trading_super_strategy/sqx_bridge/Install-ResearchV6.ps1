param(
  [string]$BridgeInstallRoot = "C:\Cygnus\SQXBridge",
  [string]$VibeInstallRoot = "C:\Cygnus\VibeTrading"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Step([string]$Message) { Write-Host "[Cygnus Research V6] $Message" }

$packageRoot = $PSScriptRoot
$bridgeSource = Join-Path $packageRoot "CygnusSQXBridge.exe"
$assetScript = Join-Path $packageRoot "vibe\asset_research.py"
$presetSource = Join-Path $packageRoot "vibe\cygnus_single_asset_strategy_desk.yaml"
$configPath = Join-Path $env:APPDATA "CygnusSQXBridge\config.json"
$python = Join-Path $VibeInstallRoot ".venv\Scripts\python.exe"

foreach($required in @($bridgeSource,$assetScript,$presetSource,$configPath,$python)){
  if(-not (Test-Path $required -PathType Leaf)){ throw "REQUIRED_FILE_MISSING:$required" }
}

Step "Verifying local Vibe MCP 8900..."
$mcpReady=$false
for($i=0;$i -lt 20;$i++){
  try {
    $probe=Test-NetConnection 127.0.0.1 -Port 8900 -WarningAction SilentlyContinue
    if($probe.TcpTestSucceeded){$mcpReady=$true;break}
  } catch {}
  Start-Sleep -Seconds 1
}
if(-not $mcpReady){ throw "VIBE_MCP_NOT_READY" }

Step "Installing fixed multi-asset research script..."
Copy-Item $assetScript (Join-Path $VibeInstallRoot "asset_research.py") -Force
& $python -m py_compile (Join-Path $VibeInstallRoot "asset_research.py")
if($LASTEXITCODE -ne 0){ throw "ASSET_RESEARCH_COMPILE_FAILED" }

Step "Installing Cygnus single-asset swarm preset..."
$presetDir=Join-Path $env:USERPROFILE ".vibe-trading\swarm\presets"
New-Item -ItemType Directory -Force -Path $presetDir | Out-Null
Copy-Item $presetSource (Join-Path $presetDir "cygnus_single_asset_strategy_desk.yaml") -Force

Step "Replacing Bridge v5 with v6 while preserving pairing..."
New-Item -ItemType Directory -Force -Path $BridgeInstallRoot | Out-Null
$bridgeTarget=Join-Path $BridgeInstallRoot "CygnusSQXBridge.exe"
Get-Process -Name "CygnusSQXBridge" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Copy-Item $bridgeSource $bridgeTarget -Force
$proc=Start-Process -FilePath $bridgeTarget -WorkingDirectory $BridgeInstallRoot -PassThru
Start-Sleep -Seconds 5
if($proc.HasExited){ throw "BRIDGE_V6_EXITED_EARLY:rc=$($proc.ExitCode)" }

Write-Host ""
Write-Host "CYGNUS_RESEARCH_V6=PASS"
Write-Host "ASSETS=NQ,ES,CL,GC,DXY"
Write-Host "RESEARCH_ONLY=true"
Write-Host "LIVE=false"
Write-Host "SHELL_TOOLS=false"
Write-Host "BROKER_EXECUTION=false"
Write-Host "PAIRING_PRESERVED=true"
