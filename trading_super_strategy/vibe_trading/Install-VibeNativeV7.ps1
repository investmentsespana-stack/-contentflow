param([string]$Root = "C:\Cygnus\VibeTrading")
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Step([string]$Message){ Write-Host "[Cygnus Vibe Native V7] $Message" }

$pkg=$PSScriptRoot
$python="$Root\.venv\Scripts\python.exe"
if(-not (Test-Path $python -PathType Leaf)){ throw "VIBE_PYTHON_MISSING:$python" }

$required=@(
  "asset_research.py",
  "vibe_full_preflight.py",
  "cygnus_native_smoke.yaml",
  "cygnus_futures_strategy_lab.yaml",
  "cygnus_dxy_macro_lab.yaml",
  "Start-VibeNative.ps1",
  "Stop-VibeNative.ps1",
  "Vibe-Guardian.ps1",
  "Authorize-VibeCodex.ps1",
  "AUTHORIZE_VIBE_CODEX.cmd"
)
foreach($name in $required){
  if(-not (Test-Path (Join-Path $pkg $name) -PathType Leaf)){ throw "PACKAGE_FILE_MISSING:$name" }
}

Step "Verifying pinned Vibe release..."
$ver = & $python -c "import importlib.metadata as m; print(m.version('vibe-trading-ai'))"
if($LASTEXITCODE -ne 0 -or $ver.Trim() -ne "0.1.15"){ throw "VIBE_VERSION_MISMATCH:$ver" }

Step "Writing canonical provider/model configuration..."
$envDir = Join-Path $env:USERPROFILE ".vibe-trading"
$envFile = Join-Path $envDir ".env"
New-Item -ItemType Directory -Force -Path $envDir | Out-Null

function Set-DotEnvValue([string]$Path,[string]$Key,[string]$Value){
  $lines = @()
  if(Test-Path $Path){ $lines = @(Get-Content $Path) }
  $found=$false
  for($i=0;$i -lt $lines.Count;$i++){
    if($lines[$i] -match ("^\s*" + [regex]::Escape($Key) + "=")){
      $lines[$i]="$Key=$Value"; $found=$true
    }
  }
  if(-not $found){ $lines += "$Key=$Value" }
  $lines | Set-Content -Encoding UTF8 $Path
}

Set-DotEnvValue $envFile "LANGCHAIN_PROVIDER" "openai-codex"
Set-DotEnvValue $envFile "LANGCHAIN_MODEL_NAME" "openai-codex/gpt-5.6-terra"
Set-DotEnvValue $envFile "LANGCHAIN_TEMPERATURE" "0"
Set-DotEnvValue $envFile "TIMEOUT_SECONDS" "180"
Set-DotEnvValue $envFile "MAX_RETRIES" "3"
Set-DotEnvValue $envFile "VIBE_TRADING_ENABLE_SHELL_TOOLS" "0"
Set-DotEnvValue $envFile "VIBE_TRADING_API_URL" "http://127.0.0.1:8899"

# Vibe's dotenv lookup is ~/.vibe-trading/.env -> package agent/.env -> CWD/.env.
# Keep a non-secret mirror in the Vibe working directory so the boot guardian can
# run under SYSTEM after a VPS reboot while OAuth remains exclusively in
# $Root\state\auth via VIBE_TRADING_HOME.
$rootEnv = Join-Path $Root ".env"
@(
  "LANGCHAIN_PROVIDER=openai-codex",
  "LANGCHAIN_MODEL_NAME=openai-codex/gpt-5.6-terra",
  "LANGCHAIN_TEMPERATURE=0",
  "TIMEOUT_SECONDS=180",
  "MAX_RETRIES=3",
  "VIBE_TRADING_ENABLE_SHELL_TOOLS=0",
  "VIBE_TRADING_API_URL=http://127.0.0.1:8899"
) | Set-Content -Encoding UTF8 $rootEnv

Step "Canonicalizing the Vibe OAuth store..."
$canonicalAuth = Join-Path $Root "state\auth"
$canonicalToken = Join-Path $canonicalAuth "openai-codex.json"
$defaultToken = Join-Path $env:USERPROFILE ".vibe-trading\auth\openai-codex.json"
New-Item -ItemType Directory -Force -Path $canonicalAuth | Out-Null

if(-not (Test-Path $canonicalToken) -and (Test-Path $defaultToken)){
  Move-Item $defaultToken $canonicalToken -Force
  Write-Host "OAUTH_TOKEN_MIGRATED=true"
} elseif((Test-Path $canonicalToken) -and (Test-Path $defaultToken)){
  $disabled = "$defaultToken.disabled-" + (Get-Date -Format "yyyyMMddHHmmss")
  Move-Item $defaultToken $disabled -Force
  Write-Host "OAUTH_DUPLICATE_DISABLED=true"
}

Step "Installing native runner, presets and health tooling..."
New-Item -ItemType Directory -Force -Path "$Root\evidence","$Root\logs","$Root\data","$Root\state\swarm\presets" | Out-Null
Copy-Item (Join-Path $pkg "asset_research.py") "$Root\asset_research.py" -Force
Copy-Item (Join-Path $pkg "vibe_full_preflight.py") "$Root\vibe_full_preflight.py" -Force
foreach($preset in @("cygnus_native_smoke.yaml","cygnus_futures_strategy_lab.yaml","cygnus_dxy_macro_lab.yaml")){
  Copy-Item (Join-Path $pkg $preset) "$Root\state\swarm\presets\$preset" -Force
}
foreach($script in @("Start-VibeNative.ps1","Stop-VibeNative.ps1","Vibe-Guardian.ps1","Authorize-VibeCodex.ps1")){
  Copy-Item (Join-Path $pkg $script) "$Root\$script" -Force
}
Copy-Item (Join-Path $pkg "AUTHORIZE_VIBE_CODEX.cmd") "$Root\AUTHORIZE_VIBE_CODEX.cmd" -Force

& $python -m py_compile "$Root\asset_research.py" "$Root\vibe_full_preflight.py"
if($LASTEXITCODE -ne 0){ throw "VIBE_NATIVE_PY_COMPILE_FAILED" }

Step "Restarting Vibe API/MCP only so canonical config is loaded..."
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$Root\Stop-VibeNative.ps1" | Out-Null
Start-Sleep -Seconds 2
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$Root\Start-VibeNative.ps1"

Step "Registering Vibe guardian for VPS reboot recovery..."
$taskName = "CygnusVibeGuardian"
$taskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Root\Vibe-Guardian.ps1`""
$taskTrigger = New-ScheduledTaskTrigger -AtStartup
$taskPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null

Step "Starting a self-healing guardian for the current VPS session..."
Get-CimInstance Win32_Process | Where-Object {
  $_.CommandLine -match [regex]::Escape("$Root\Vibe-Guardian.ps1")
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoLogo","-NoProfile","-ExecutionPolicy","Bypass","-File","$Root\Vibe-Guardian.ps1") -WindowStyle Hidden | Out-Null

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
if($task.State -eq "Disabled"){ throw "VIBE_GUARDIAN_TASK_DISABLED" }
Write-Host "VIBE_BOOT_GUARDIAN=REGISTERED"

Step "Running full native Vibe preflight..."
& $python "$Root\vibe_full_preflight.py"
$rc=$LASTEXITCODE
if($rc -eq 0){
  Write-Host ""
  Write-Host "CYGNUS_VIBE_NATIVE_V7=PASS"
  Write-Host "NATIVE_AGENTS=true"
  Write-Host "PROVIDER=openai-codex"
  Write-Host "MODEL=openai-codex/gpt-5.6-terra"
  Write-Host "RESEARCH_ONLY=true"
  Write-Host "LIVE=false"
  Write-Host "SHELL_TOOLS=false"
  Write-Host "SQX_TOUCHED=false"
  Write-Host "GOLD_TOUCHED=false"
  exit 0
}

Write-Host ""
Write-Host "CYGNUS_VIBE_NATIVE_V7=NEEDS_OAUTH_OR_PREFLIGHT_REPAIR"
Write-Host "If OAUTH_READY=false, run $Root\AUTHORIZE_VIBE_CODEX.cmd once."
Write-Host "SQX_TOUCHED=false"
Write-Host "GOLD_TOUCHED=false"
exit $rc
