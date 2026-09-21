param([string]$Root = "C:\Cygnus\VibeTrading")
$ErrorActionPreference = "SilentlyContinue"

if(Test-Path "$Root\runtime.json"){
  try {
    $r=Get-Content "$Root\runtime.json" -Raw | ConvertFrom-Json
    foreach($pidValue in @($r.api_pid,$r.mcp_pid)){
      if($pidValue){ Stop-Process -Id ([int]$pidValue) -Force -ErrorAction SilentlyContinue }
    }
  } catch {}
}

Get-CimInstance Win32_Process | Where-Object {
  $_.ExecutablePath -like "$Root\.venv\Scripts\*" -and
  ($_.CommandLine -match "vibe-trading" -or $_.CommandLine -match "mcp_server" -or $_.CommandLine -match "api_server")
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Remove-Item "$Root\runtime.json" -Force -ErrorAction SilentlyContinue
Write-Host "VIBE_NATIVE_SERVICES_STOPPED"
