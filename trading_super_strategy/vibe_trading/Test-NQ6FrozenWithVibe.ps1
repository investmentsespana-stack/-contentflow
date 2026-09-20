$ErrorActionPreference = 'Stop'
$Root = 'C:\Cygnus\VibeTrading'
$Python = Join-Path $Root '.venv\Scripts\python.exe'
$Script = Join-Path $Root 'nq6_frozen_vibe_smoke.py'
if (-not (Test-Path $Python)) { throw "Vibe Python not found: $Python" }

$api = Test-NetConnection 127.0.0.1 -Port 8899 -WarningAction SilentlyContinue
$mcp = Test-NetConnection 127.0.0.1 -Port 8900 -WarningAction SilentlyContinue
if (-not $api.TcpTestSucceeded) { throw 'VIBE_API_PORT_8899_NOT_LISTENING' }
if (-not $mcp.TcpTestSucceeded) { throw 'VIBE_MCP_PORT_8900_NOT_LISTENING' }

& $Python $Script --mcp-url 'http://127.0.0.1:8900/mcp'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
