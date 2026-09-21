param([string]$Root = "C:\Cygnus\VibeTrading")
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$env:VIBE_TRADING_HOME = "$Root\state"
$env:LANGCHAIN_PROVIDER = "openai-codex"
$env:LANGCHAIN_MODEL_NAME = "openai-codex/gpt-5.6-terra"
$env:VIBE_TRADING_ENABLE_SHELL_TOOLS = "0"
$env:CYGNUS_RESEARCH_ONLY = "1"

$python="$Root\.venv\Scripts\python.exe"
if(-not (Test-Path $python -PathType Leaf)){ throw "VIBE_PYTHON_MISSING:$python" }

$deviceAuth="$Root\Vibe-Codex-DeviceAuth.py"
if(-not (Test-Path $deviceAuth -PathType Leaf)){ throw "VIBE_DEVICE_AUTH_HELPER_MISSING:$deviceAuth" }

Write-Host "Starting Vibe-owned OpenAI Codex device-code login..."
& $python $deviceAuth
if($LASTEXITCODE -ne 0){ throw "VIBE_CODEX_DEVICE_AUTH_FAILED:$LASTEXITCODE" }

Write-Host "OAuth stored in the canonical Vibe runtime. Restarting Vibe services only..."
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$Root\Stop-VibeNative.ps1" | Out-Null
Start-Sleep -Seconds 2
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$Root\Start-VibeNative.ps1"

Write-Host "Running full native operability preflight..."
& "$Root\.venv\Scripts\python.exe" "$Root\vibe_full_preflight.py"
exit $LASTEXITCODE
