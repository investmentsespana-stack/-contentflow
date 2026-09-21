param(
  [string]$VibeInstallRoot = "C:\Cygnus\VibeTrading"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Step([string]$Message) { Write-Host "[Cygnus V6.1] $Message" }

$packageRoot = $PSScriptRoot
$runner = Join-Path $packageRoot "asset_research.py"
$primaryPreset = Join-Path $packageRoot "cygnus_single_asset_strategy_desk.yaml"
$fallbackPreset = Join-Path $packageRoot "cygnus_asset_research_minimal.yaml"
$python = Join-Path $VibeInstallRoot ".venv\Scripts\python.exe"

foreach($required in @($runner,$primaryPreset,$fallbackPreset,$python)){
  if(-not (Test-Path $required -PathType Leaf)){ throw "REQUIRED_FILE_MISSING:$required" }
}

Step "Verifying Vibe MCP 8900..."
$ready=$false
for($i=0;$i -lt 20;$i++){
  try {
    $probe=Test-NetConnection 127.0.0.1 -Port 8900 -WarningAction SilentlyContinue
    if($probe.TcpTestSucceeded){$ready=$true;break}
  } catch {}
  Start-Sleep -Seconds 1
}
if(-not $ready){ throw "VIBE_MCP_NOT_READY" }

Step "Updating only the Vibe asset runner..."
Copy-Item $runner (Join-Path $VibeInstallRoot "asset_research.py") -Force
& $python -m py_compile (Join-Path $VibeInstallRoot "asset_research.py")
if($LASTEXITCODE -ne 0){ throw "ASSET_RESEARCH_COMPILE_FAILED" }

Step "Installing primary and fail-safe presets..."
$userPresetDir=Join-Path $env:USERPROFILE ".vibe-trading\swarm\presets"
$statePresetDir=Join-Path $VibeInstallRoot "state\swarm\presets"
New-Item -ItemType Directory -Force -Path $userPresetDir,$statePresetDir | Out-Null
Copy-Item $primaryPreset (Join-Path $userPresetDir "cygnus_single_asset_strategy_desk.yaml") -Force
Copy-Item $fallbackPreset (Join-Path $userPresetDir "cygnus_asset_research_minimal.yaml") -Force
Copy-Item $primaryPreset (Join-Path $statePresetDir "cygnus_single_asset_strategy_desk.yaml") -Force
Copy-Item $fallbackPreset (Join-Path $statePresetDir "cygnus_asset_research_minimal.yaml") -Force

Write-Host ""
Write-Host "CYGNUS_VIBE_V61_PATCH=PASS"
Write-Host "BRIDGE_RESTARTED=false"
Write-Host "SQX_TOUCHED=false"
Write-Host "GOLD_TOUCHED=false"
Write-Host "MCP_RESTARTED=false"
Write-Host "RESEARCH_ONLY=true"
Write-Host "LIVE=false"
Write-Host "SHELL_TOOLS=false"
