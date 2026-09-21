param(
  [string]$VibeInstallRoot = "C:\Cygnus\VibeTrading"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Step([string]$Message) { Write-Host "[Cygnus V6.2] $Message" }

$runner = Join-Path $PSScriptRoot "asset_research.py"
$python = Join-Path $VibeInstallRoot ".venv\Scripts\python.exe"
if(-not (Test-Path $runner -PathType Leaf)){ throw "RUNNER_MISSING:$runner" }
if(-not (Test-Path $python -PathType Leaf)){ throw "VIBE_PYTHON_MISSING:$python" }

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

Step "Installing deterministic no-LLM asset runner..."
Copy-Item $runner (Join-Path $VibeInstallRoot "asset_research.py") -Force
& $python -m py_compile (Join-Path $VibeInstallRoot "asset_research.py")
if($LASTEXITCODE -ne 0){ throw "ASSET_RESEARCH_COMPILE_FAILED" }

Write-Host ""
Write-Host "CYGNUS_VIBE_V62_PATCH=PASS"
Write-Host "MODE=VIBE_DATA_DETERMINISTIC_SCREEN"
Write-Host "LLM_REQUIRED=false"
Write-Host "BRIDGE_RESTARTED=false"
Write-Host "SQX_TOUCHED=false"
Write-Host "GOLD_TOUCHED=false"
Write-Host "MCP_RESTARTED=false"
Write-Host "RESEARCH_ONLY=true"
Write-Host "LIVE=false"
Write-Host "SHELL_TOOLS=false"
