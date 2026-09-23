param([string]$Root = "C:\Cygnus\VibeTrading")
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Step([string]$Message){ Write-Host "[Cygnus Vibe Native V7.3] $Message" }

$pkg=$PSScriptRoot
$python="$Root\.venv\Scripts\python.exe"
if(-not (Test-Path $python -PathType Leaf)){ throw "VIBE_PYTHON_MISSING:$python" }

$required=@(
  "asset_research.py",
  "canonical_market_data.py",
  "apply_vibe_upstream_artifact_handoff_fix.py",
  "apply_vibe_canonical_grounding_isolation_fix.py",
  "tradingview_futures_guard.py",
  "Start-VibeNative.ps1",
  "Authorize-VibeCodex.ps1",
  "Vibe-Codex-DeviceAuth.py",
  "vibe_full_preflight.py",
  "cygnus_native_smoke.yaml",
  "cygnus_futures_strategy_lab.yaml",
  "cygnus_dxy_macro_lab.yaml"
)
foreach($name in $required){
  if(-not (Test-Path (Join-Path $pkg $name) -PathType Leaf)){ throw "PACKAGE_FILE_MISSING:$name" }
}

Step "Installing supported ChatGPT Codex model and preset-discovery repair..."
Copy-Item (Join-Path $pkg "asset_research.py") "$Root\asset_research.py" -Force
Copy-Item (Join-Path $pkg "canonical_market_data.py") "$Root\canonical_market_data.py" -Force
Copy-Item (Join-Path $pkg "tradingview_futures_guard.py") "$Root\tradingview_futures_guard.py" -Force
Copy-Item (Join-Path $pkg "Start-VibeNative.ps1") "$Root\Start-VibeNative.ps1" -Force
Copy-Item (Join-Path $pkg "Authorize-VibeCodex.ps1") "$Root\Authorize-VibeCodex.ps1" -Force
Copy-Item (Join-Path $pkg "Vibe-Codex-DeviceAuth.py") "$Root\Vibe-Codex-DeviceAuth.py" -Force
Copy-Item (Join-Path $pkg "vibe_full_preflight.py") "$Root\vibe_full_preflight.py" -Force

# Vibe-Trading 0.1.15 hard-codes custom swarm preset discovery to
# ~/.vibe-trading/swarm/presets rather than VIBE_TRADING_HOME. Install our
# presets into that exact user path as well as the canonical Cygnus state path.
$userPresetDir = Join-Path $HOME ".vibe-trading\swarm\presets"
$statePresetDir = "$Root\state\swarm\presets"
New-Item -ItemType Directory -Force -Path $userPresetDir,$statePresetDir | Out-Null
foreach($preset in @("cygnus_native_smoke.yaml","cygnus_futures_strategy_lab.yaml","cygnus_dxy_macro_lab.yaml")){
  Copy-Item (Join-Path $pkg $preset) (Join-Path $userPresetDir $preset) -Force
  Copy-Item (Join-Path $pkg $preset) (Join-Path $statePresetDir $preset) -Force
}

Step "Applying Cygnus Vibe runtime hardening..."
& $python (Join-Path $pkg "apply_vibe_upstream_artifact_handoff_fix.py")
if($LASTEXITCODE -ne 0){ throw "VIBE_UPSTREAM_ARTIFACT_HANDOFF_PATCH_FAILED" }
& $python (Join-Path $pkg "apply_vibe_canonical_grounding_isolation_fix.py")
if($LASTEXITCODE -ne 0){ throw "VIBE_CANONICAL_GROUNDING_PATCH_FAILED" }

& $python -m py_compile "$Root\tradingview_futures_guard.py" "$Root\asset_research.py" "$Root\canonical_market_data.py" "$Root\Vibe-Codex-DeviceAuth.py" "$Root\vibe_full_preflight.py"
if($LASTEXITCODE -ne 0){ throw "VIBE_V73_COMPILE_FAILED" }

$env:VIBE_TRADING_HOME = "$Root\state"
$env:LANGCHAIN_PROVIDER = "openai-codex"
$env:LANGCHAIN_MODEL_NAME = "openai-codex/gpt-5.6-terra"
$env:VIBE_TRADING_ENABLE_SHELL_TOOLS = "0"
$env:CYGNUS_RESEARCH_ONLY = "1"

Step "Checking Vibe OAuth..."
& $python "$Root\Vibe-Codex-DeviceAuth.py"
if($LASTEXITCODE -ne 0){ throw "VIBE_CODEX_DEVICE_AUTH_FAILED:$LASTEXITCODE" }

$tokenPath="$Root\state\auth\openai-codex.json"
if(-not (Test-Path $tokenPath -PathType Leaf)){ throw "VIBE_CODEX_TOKEN_NOT_CREATED:$tokenPath" }
Write-Host "OAUTH_TOKEN_PRESENT=true"

Step "Restarting Vibe services only..."
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$Root\Stop-VibeNative.ps1" | Out-Null
Start-Sleep -Seconds 2
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$Root\Start-VibeNative.ps1"

Step "Running full native Vibe health..."
& $python "$Root\vibe_full_preflight.py"
$rc=$LASTEXITCODE
if($rc -ne 0){ throw "VIBE_FULL_PREFLIGHT_FAILED:$rc" }

Write-Host ""
Write-Host "CYGNUS_VIBE_NATIVE_V73=PASS"
Write-Host "PROVIDER=openai-codex"
Write-Host "MODEL=openai-codex/gpt-5.6-terra"
Write-Host "OAUTH_READY=true"
Write-Host "PRESETS_DISCOVERABLE=true"
Write-Host "RESEARCH_ONLY=true"
Write-Host "LIVE=false"
Write-Host "SHELL_TOOLS=false"
Write-Host "SQX_TOUCHED=false"
Write-Host "GOLD_TOUCHED=false"
