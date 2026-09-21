param([string]$Root = "C:\Cygnus\VibeTrading")
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Step([string]$Message){ Write-Host "[Cygnus Vibe Native V7.2] $Message" }

$pkg=$PSScriptRoot
$python="$Root\.venv\Scripts\python.exe"
if(-not (Test-Path $python -PathType Leaf)){ throw "VIBE_PYTHON_MISSING:$python" }

foreach($name in @(
  "asset_research.py",
  "Start-VibeNative.ps1",
  "Authorize-VibeCodex.ps1",
  "Vibe-Codex-DeviceAuth.py",
  "vibe_full_preflight.py"
)){
  if(-not (Test-Path (Join-Path $pkg $name) -PathType Leaf)){ throw "PACKAGE_FILE_MISSING:$name" }
}

Step "Installing V7.2 native device-auth repair..."
Copy-Item (Join-Path $pkg "asset_research.py") "$Root\asset_research.py" -Force
Copy-Item (Join-Path $pkg "Start-VibeNative.ps1") "$Root\Start-VibeNative.ps1" -Force
Copy-Item (Join-Path $pkg "Authorize-VibeCodex.ps1") "$Root\Authorize-VibeCodex.ps1" -Force
Copy-Item (Join-Path $pkg "Vibe-Codex-DeviceAuth.py") "$Root\Vibe-Codex-DeviceAuth.py" -Force
Copy-Item (Join-Path $pkg "vibe_full_preflight.py") "$Root\vibe_full_preflight.py" -Force

& $python -m py_compile "$Root\asset_research.py" "$Root\Vibe-Codex-DeviceAuth.py" "$Root\vibe_full_preflight.py"
if($LASTEXITCODE -ne 0){ throw "VIBE_V72_COMPILE_FAILED" }

$env:VIBE_TRADING_HOME = "$Root\state"
$env:LANGCHAIN_PROVIDER = "openai-codex"
$env:LANGCHAIN_MODEL_NAME = "openai-codex/gpt-5.4"
$env:VIBE_TRADING_ENABLE_SHELL_TOOLS = "0"
$env:CYGNUS_RESEARCH_ONLY = "1"

Step "Authorizing Vibe with OpenAI device code..."
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
Write-Host "CYGNUS_VIBE_NATIVE_V72=PASS"
Write-Host "PROVIDER=openai-codex"
Write-Host "MODEL=openai-codex/gpt-5.4"
Write-Host "OAUTH_READY=true"
Write-Host "RESEARCH_ONLY=true"
Write-Host "LIVE=false"
Write-Host "SHELL_TOOLS=false"
Write-Host "SQX_TOUCHED=false"
Write-Host "GOLD_TOUCHED=false"
