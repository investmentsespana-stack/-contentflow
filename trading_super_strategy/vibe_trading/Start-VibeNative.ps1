param(
  [string]$Root = "C:\Cygnus\VibeTrading"
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$env:VIBE_TRADING_HOME = "$Root\state"
$env:LANGCHAIN_PROVIDER = "openai-codex"
$env:LANGCHAIN_MODEL_NAME = "openai-codex/gpt-5.4"
$env:VIBE_TRADING_ALLOWED_FILE_ROOTS = "$Root\data;$Root\evidence;$Root\state"
$env:VIBE_TRADING_ALLOWED_RUN_ROOTS = "$Root\state\runs;$Root\data"
$env:VIBE_TRADING_ENABLE_SHELL_TOOLS = "0"
$env:CYGNUS_RESEARCH_ONLY = "1"
$env:VIBE_TRADING_API_URL = "http://127.0.0.1:8899"

$api = "$Root\.venv\Scripts\vibe-trading.exe"
$mcp = "$Root\.venv\Scripts\vibe-trading-mcp.exe"
if(-not (Test-Path $api -PathType Leaf)){ throw "VIBE_API_EXE_MISSING:$api" }
if(-not (Test-Path $mcp -PathType Leaf)){ throw "VIBE_MCP_EXE_MISSING:$mcp" }

New-Item -ItemType Directory -Force -Path "$Root\logs","$Root\state","$Root\evidence","$Root\data" | Out-Null

function PortOpen([int]$Port){
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $a = $c.BeginConnect("127.0.0.1",$Port,$null,$null)
    if(-not $a.AsyncWaitHandle.WaitOne(1000)){ $c.Close(); return $false }
    $c.EndConnect($a); $c.Close(); return $true
  } catch { return $false }
}

if(-not (PortOpen 8899)){
  $apiProc = Start-Process -FilePath $api -ArgumentList @("serve","--host","127.0.0.1","--port","8899") -WorkingDirectory $Root -WindowStyle Hidden -PassThru -RedirectStandardOutput "$Root\logs\api.out.log" -RedirectStandardError "$Root\logs\api.err.log"
} else { $apiProc = $null }

if(-not (PortOpen 8900)){
  $mcpProc = Start-Process -FilePath $mcp -ArgumentList @("--transport","http","--host","127.0.0.1","--port","8900") -WorkingDirectory $Root -WindowStyle Hidden -PassThru -RedirectStandardOutput "$Root\logs\mcp.out.log" -RedirectStandardError "$Root\logs\mcp.err.log"
} else { $mcpProc = $null }

for($i=0;$i -lt 60;$i++){
  if((PortOpen 8899) -and (PortOpen 8900)){ break }
  Start-Sleep -Seconds 1
}
if(-not (PortOpen 8899)){ throw "VIBE_API_NOT_READY" }
if(-not (PortOpen 8900)){ throw "VIBE_MCP_NOT_READY" }

@{
  api_pid = if($apiProc){$apiProc.Id}else{$null}
  mcp_pid = if($mcpProc){$mcpProc.Id}else{$null}
  api = "http://127.0.0.1:8899"
  mcp = "http://127.0.0.1:8900/mcp"
  started_at = (Get-Date).ToString("o")
  research_only = $true
  shell_tools = $false
} | ConvertTo-Json | Set-Content -Encoding UTF8 "$Root\runtime.json"

Write-Host "VIBE_NATIVE_SERVICES=PASS"
Write-Host "API=http://127.0.0.1:8899"
Write-Host "MCP=http://127.0.0.1:8900/mcp"
Write-Host "RESEARCH_ONLY=true"
Write-Host "LIVE=false"
Write-Host "SHELL_TOOLS=false"
