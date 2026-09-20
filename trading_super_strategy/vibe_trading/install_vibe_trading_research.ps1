param(
  [string]$InstallRoot = "C:\Cygnus\VibeTrading",
  [string]$PackageVersion = "0.1.15"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step([string]$Message) {
  Write-Host "[Cygnus/Vibe] $Message"
}

function Resolve-Python311 {
  $candidates = @(
    @{ Cmd = "py"; Args = @("-3.11") },
    @{ Cmd = "python"; Args = @() }
  )

  foreach ($c in $candidates) {
    try {
      $out = & $c.Cmd @($c.Args) -c "import sys; print(sys.executable); print('.'.join(map(str,sys.version_info[:3])))" 2>$null
      if ($LASTEXITCODE -eq 0 -and $out.Count -ge 2) {
        $ver = [version]$out[-1]
        if ($ver.Major -eq 3 -and $ver.Minor -ge 11) {
          return @{ Cmd = $c.Cmd; Args = $c.Args; Exe = $out[-2]; Version = $ver.ToString() }
        }
      }
    } catch {}
  }

  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Step "Python 3.11 no encontrado; instalando Python.Python.3.11 para el usuario actual..."
    & winget install --id Python.Python.3.11 --exact --scope user --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0) { throw "winget no pudo instalar Python 3.11 (rc=$LASTEXITCODE)" }
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","User") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","Machine")
    return Resolve-Python311
  }

  $officialUrl = "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe"
  $installer = Join-Path $env:TEMP "python-3.11.9-amd64.exe"
  Write-Step "winget no esta disponible; descargando Python 3.11.9 oficial desde python.org..."
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -UseBasicParsing -Uri $officialUrl -OutFile $installer

  $sig = Get-AuthenticodeSignature $installer
  if ($sig.Status -ne "Valid" -or $sig.SignerCertificate.Subject -notmatch "Python Software Foundation") {
    Remove-Item $installer -Force -ErrorAction SilentlyContinue
    throw "La firma Authenticode del instalador de Python no es valida o no pertenece a Python Software Foundation."
  }

  Write-Step "Firma oficial de Python verificada. Instalando Python 3.11.9 para el usuario actual..."
  $proc = Start-Process -FilePath $installer -ArgumentList @(
    "/quiet",
    "InstallAllUsers=0",
    "PrependPath=1",
    "Include_launcher=1",
    "Include_test=0"
  ) -Wait -PassThru
  if ($proc.ExitCode -ne 0) { throw "Instalador oficial de Python fallo (rc=$($proc.ExitCode))" }

  $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","User") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","Machine")
  $directPython = Join-Path $env:LocalAppData "Programs\Python\Python311\python.exe"
  if (Test-Path $directPython) {
    $ver = & $directPython -c "import sys; print('.'.join(map(str,sys.version_info[:3])))"
    return @{ Cmd = $directPython; Args = @(); Exe = $directPython; Version = ([version]$ver).ToString() }
  }

  return Resolve-Python311
}

Write-Step "Preparando instalacion aislada en $InstallRoot"
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
New-Item -ItemType Directory -Force -Path "$InstallRoot\state","$InstallRoot\data","$InstallRoot\logs" | Out-Null

Write-Step "Instalando prueba NQ6 congelada de solo investigacion..."
$requiredSidecars = @(
  "nq6_frozen_vibe_smoke.py",
  "Test-NQ6FrozenWithVibe.ps1",
  "nq6_frozen_inventory.json"
)
foreach ($name in $requiredSidecars) {
  $src = Join-Path $PSScriptRoot $name
  if (-not (Test-Path $src -PathType Leaf)) { throw "Paquete incompleto: falta $name" }
  Copy-Item $src (Join-Path $InstallRoot $name) -Force
}
$manifestSource = Join-Path $PSScriptRoot "data\nq6_frozen_manifest.json"
if (-not (Test-Path $manifestSource -PathType Leaf)) { throw "Paquete incompleto: falta data\nq6_frozen_manifest.json" }
Copy-Item $manifestSource (Join-Path $InstallRoot "data\nq6_frozen_manifest.json") -Force

$py = Resolve-Python311
Write-Step "Python detectado: $($py.Exe) ($($py.Version))"

$venv = Join-Path $InstallRoot ".venv"
if (-not (Test-Path "$venv\Scripts\python.exe")) {
  Write-Step "Creando entorno virtual..."
  & $py.Cmd @($py.Args) -m venv $venv
}
$venvPython = "$venv\Scripts\python.exe"
$venvPip = "$venv\Scripts\pip.exe"

Write-Step "Actualizando pip..."
& $venvPython -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw "pip upgrade fallo" }

Write-Step "Instalando vibe-trading-ai==$PackageVersion..."
& $venvPython -m pip install "vibe-trading-ai==$PackageVersion"
if ($LASTEXITCODE -ne 0) { throw "Instalacion de vibe-trading-ai fallo" }

$policy = @{
  mode = "RESEARCH_ONLY"
  live_money = $false
  broker_credentials_allowed = $false
  shell_tools_enabled = $false
  bind_host = "127.0.0.1"
  api_port = 8899
  mcp_port = 8900
  data_policy = "local_or_explicit_source_only_for_certification"
  notes = "Cygnus policy wrapper. Vibe-Trading itself is started without shell tools and without broker credentials."
}
$policy | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 "$InstallRoot\cygnus-vibe-policy.json"

$launcher = @'
$ErrorActionPreference = "Stop"
$Root = "C:\Cygnus\VibeTrading"
$env:VIBE_TRADING_HOME = "$Root\state"
$env:VIBE_TRADING_ALLOWED_FILE_ROOTS = "$Root\data"
$env:VIBE_TRADING_ENABLE_SHELL_TOOLS = "0"
$api = "$Root\.venv\Scripts\vibe-trading.exe"
$mcp = "$Root\.venv\Scripts\vibe-trading-mcp.exe"
if (-not (Test-Path $api)) { throw "vibe-trading.exe no encontrado" }
if (-not (Test-Path $mcp)) { throw "vibe-trading-mcp.exe no encontrado" }

$apiProc = Start-Process -FilePath $api -ArgumentList @("serve","--host","127.0.0.1","--port","8899") -WorkingDirectory $Root -WindowStyle Hidden -PassThru -RedirectStandardOutput "$Root\logs\api.out.log" -RedirectStandardError "$Root\logs\api.err.log"
$mcpProc = Start-Process -FilePath $mcp -ArgumentList @("--transport","http","--host","127.0.0.1","--port","8900") -WorkingDirectory $Root -WindowStyle Hidden -PassThru -RedirectStandardOutput "$Root\logs\mcp.out.log" -RedirectStandardError "$Root\logs\mcp.err.log"

@{
  api_pid = $apiProc.Id
  mcp_pid = $mcpProc.Id
  api = "http://127.0.0.1:8899"
  mcp = "http://127.0.0.1:8900/mcp"
  started_at = (Get-Date).ToString("o")
  research_only = $true
} | ConvertTo-Json | Set-Content -Encoding UTF8 "$Root\runtime.json"

Start-Sleep -Seconds 8
try {
  $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8899/openapi.json" -TimeoutSec 10
  if ($resp.StatusCode -ne 200) { throw "API status $($resp.StatusCode)" }
  Write-Host "VIBE_API_PASS"
} catch {
  Write-Host "VIBE_API_FAIL: $($_.Exception.Message)"
  exit 2
}
Write-Host "VIBE_MCP=http://127.0.0.1:8900/mcp"
Write-Host "RESEARCH_ONLY=true"
'@
$launcher | Set-Content -Encoding UTF8 "$InstallRoot\Start-VibeResearch.ps1"

$stopper = @'
$Root = "C:\Cygnus\VibeTrading"
$runtime = "$Root\runtime.json"
if (Test-Path $runtime) {
  $r = Get-Content $runtime -Raw | ConvertFrom-Json
  foreach ($pidValue in @($r.api_pid,$r.mcp_pid)) {
    if ($pidValue) {
      Stop-Process -Id ([int]$pidValue) -Force -ErrorAction SilentlyContinue
    }
  }
}
Get-CimInstance Win32_Process | Where-Object {
  $_.ExecutablePath -like "$Root\.venv\Scripts\*" -and
  ($_.CommandLine -match "vibe-trading")
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-Item $runtime -Force -ErrorAction SilentlyContinue
Write-Host "VIBE_STOPPED"
'@
$stopper | Set-Content -Encoding UTF8 "$InstallRoot\Stop-VibeResearch.ps1"

$verify = @'
$ErrorActionPreference = "Stop"
$Root = "C:\Cygnus\VibeTrading"
$py = "$Root\.venv\Scripts\python.exe"
$vibe = "$Root\.venv\Scripts\vibe-trading.exe"
$mcp = "$Root\.venv\Scripts\vibe-trading-mcp.exe"

if (-not (Test-Path $py)) { throw "VENV_MISSING" }
if (-not (Test-Path $vibe)) { throw "VIBE_CLI_MISSING" }
if (-not (Test-Path $mcp)) { throw "VIBE_MCP_MISSING" }
foreach ($required in @(
  "nq6_frozen_vibe_smoke.py",
  "Test-NQ6FrozenWithVibe.ps1",
  "nq6_frozen_inventory.json",
  "data\nq6_frozen_manifest.json"
)) {
  if (-not (Test-Path (Join-Path $Root $required) -PathType Leaf)) {
    throw "NQ6_SMOKE_ASSET_MISSING:$required"
  }
}

& $vibe --version
& $vibe serve --help | Out-Null
& $mcp --help | Out-Null

$policy = Get-Content "$Root\cygnus-vibe-policy.json" -Raw | ConvertFrom-Json
if ($policy.mode -ne "RESEARCH_ONLY" -or $policy.live_money -ne $false -or $policy.shell_tools_enabled -ne $false) {
  throw "POLICY_FAIL"
}

Write-Host "VIBE_INSTALL_PASS"
Write-Host "MODE=RESEARCH_ONLY"
Write-Host "LIVE=false"
Write-Host "SHELL_TOOLS=false"
'@
$verify | Set-Content -Encoding UTF8 "$InstallRoot\Verify-VibeResearch.ps1"

Write-Step "Validando instalacion..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$InstallRoot\Verify-VibeResearch.ps1"
if ($LASTEXITCODE -ne 0) { throw "Validacion local fallo" }

Write-Step "Instalacion preparada. No se conecto ningun broker y no se habilito LIVE."
Write-Step "Para arrancar API+MCP: powershell -NoProfile -ExecutionPolicy Bypass -File $InstallRoot\Start-VibeResearch.ps1"
