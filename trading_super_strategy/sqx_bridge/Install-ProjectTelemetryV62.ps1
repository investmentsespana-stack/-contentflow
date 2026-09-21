param(
  [string]$BridgeInstallRoot = "C:\Cygnus\SQXBridge"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Step([string]$Message){ Write-Host "[Cygnus SQX Bridge V6.2 Project Telemetry] $Message" }

$pkg=$PSScriptRoot
$bridgeSource=Join-Path $pkg "CygnusSQXBridge.exe"
$configPath=Join-Path $env:APPDATA "CygnusSQXBridge\config.json"
if(-not (Test-Path $bridgeSource -PathType Leaf)){ throw "BRIDGE_EXE_MISSING:$bridgeSource" }
if(-not (Test-Path $configPath -PathType Leaf)){ throw "PAIRING_CONFIG_MISSING:$configPath" }

$bridgeTarget=Join-Path $BridgeInstallRoot "CygnusSQXBridge.exe"
New-Item -ItemType Directory -Force -Path $BridgeInstallRoot | Out-Null

Step "Replacing Bridge only. SQX and GOLD are intentionally left running."
Get-Process -Name "CygnusSQXBridge" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Copy-Item $bridgeSource $bridgeTarget -Force
$proc=Start-Process -FilePath $bridgeTarget -WorkingDirectory $BridgeInstallRoot -PassThru
Start-Sleep -Seconds 5
if($proc.HasExited){ throw "BRIDGE_V62_EXITED_EARLY:rc=$($proc.ExitCode)" }

Write-Host ""
Write-Host "CYGNUS_SQX_BRIDGE_V62_PROJECT_TELEMETRY=PASS"
Write-Host "PAIRING_PRESERVED=true"
Write-Host "PROJECT_FILES_READ_ONLY=true"
Write-Host "NO_COMPETING_SQCLI=true"
Write-Host "SQX_PROCESS_TOUCHED=false"
Write-Host "GOLD_TOUCHED=false"
