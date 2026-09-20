param(
  [string]$BridgeInstallRoot = "C:\Cygnus\SQXBridge",
  [string]$VibeInstallRoot = "C:\Cygnus\VibeTrading"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Step([string]$Message) {
  Write-Host "[Cygnus Research V5] $Message"
}

$packageRoot = $PSScriptRoot
$bridgeSource = Join-Path $packageRoot "CygnusSQXBridge.exe"
$vibeInstaller = Join-Path $packageRoot "vibe\install_vibe_trading_research.ps1"
$configPath = Join-Path $env:APPDATA "CygnusSQXBridge\config.json"

if (-not (Test-Path $bridgeSource -PathType Leaf)) {
  throw "PACKAGE_INVALID: CygnusSQXBridge.exe missing"
}
if (-not (Test-Path $vibeInstaller -PathType Leaf)) {
  throw "PACKAGE_INVALID: Vibe installer missing"
}
if (-not (Test-Path $configPath -PathType Leaf)) {
  throw "EXISTING_PAIRING_CONFIG_MISSING: refusing to replace the active bridge"
}

Step "Installing/validating Vibe in RESEARCH_ONLY mode..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $vibeInstaller -InstallRoot $VibeInstallRoot
if ($LASTEXITCODE -ne 0) {
  throw "VIBE_INSTALL_FAILED:$LASTEXITCODE"
}

$stopVibe = Join-Path $VibeInstallRoot "Stop-VibeResearch.ps1"
$startVibe = Join-Path $VibeInstallRoot "Start-VibeResearch.ps1"
if (-not (Test-Path $stopVibe -PathType Leaf) -or -not (Test-Path $startVibe -PathType Leaf)) {
  throw "VIBE_LAUNCHERS_MISSING"
}

Step "Starting local Vibe API/MCP with shell tools disabled..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stopVibe | Out-Host
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startVibe | Out-Host
if ($LASTEXITCODE -ne 0) {
  throw "VIBE_START_FAILED:$LASTEXITCODE"
}

$mcpReady = $false
for ($i = 0; $i -lt 20; $i++) {
  try {
    $probe = Test-NetConnection 127.0.0.1 -Port 8900 -WarningAction SilentlyContinue
    if ($probe.TcpTestSucceeded) {
      $mcpReady = $true
      break
    }
  } catch {}
  Start-Sleep -Seconds 1
}
if (-not $mcpReady) {
  throw "VIBE_MCP_NOT_READY"
}

Step "Staging Bridge v5 while preserving the existing pairing..."
New-Item -ItemType Directory -Force -Path $BridgeInstallRoot | Out-Null
$bridgeTarget = Join-Path $BridgeInstallRoot "CygnusSQXBridge.exe"
Copy-Item $bridgeSource $bridgeTarget -Force

Step "Switching Bridge v4 -> v5..."
Get-Process -Name "CygnusSQXBridge" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
$proc = Start-Process -FilePath $bridgeTarget -WorkingDirectory $BridgeInstallRoot -PassThru
Start-Sleep -Seconds 5
if ($proc.HasExited) {
  throw "BRIDGE_V5_EXITED_EARLY:rc=$($proc.ExitCode)"
}

Step "Bridge v5 started. Existing pairing retained."
Step "The queued run_vibe_nq6_smoke command will be claimed only after v5 advertises that fixed capability."
Write-Host "RESEARCH_ONLY=true"
Write-Host "LIVE=false"
Write-Host "SHELL_TOOLS=false"
Write-Host "SQX_INVOKED_BY_SMOKE=false"
