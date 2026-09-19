param([string]$InstallRoot = "C:\Cygnus\VibeTrading")
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$policyPath = Join-Path $InstallRoot "cygnus-vibe-policy.json"
$runtimePath = Join-Path $InstallRoot "runtime.json"

if (-not (Test-Path $policyPath)) { throw "POLICY_MISSING" }
$policy = Get-Content $policyPath -Raw | ConvertFrom-Json
if ($policy.mode -ne "RESEARCH_ONLY") { throw "MODE_NOT_RESEARCH_ONLY" }
if ($policy.live_money -ne $false) { throw "LIVE_MUST_BE_FALSE" }
if ($policy.shell_tools_enabled -ne $false) { throw "SHELL_TOOLS_MUST_BE_FALSE" }
if ($policy.bind_host -ne "127.0.0.1") { throw "BIND_NOT_LOOPBACK" }

if (Test-Path $runtimePath) {
  $runtime = Get-Content $runtimePath -Raw | ConvertFrom-Json
  if ($runtime.research_only -ne $true) { throw "RUNTIME_NOT_RESEARCH_ONLY" }
  $api = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8899/openapi.json" -TimeoutSec 10
  if ($api.StatusCode -ne 200) { throw "API_HEALTH_FAIL" }
  Write-Host "VIBE_RUNTIME_PASS"
} else {
  Write-Host "VIBE_INSTALLED_NOT_STARTED"
}

Write-Host "MODE=RESEARCH_ONLY"
Write-Host "LIVE=false"
Write-Host "BIND=127.0.0.1"
