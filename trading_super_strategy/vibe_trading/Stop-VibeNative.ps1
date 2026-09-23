[Reading 24 lines from start (total: 24 lines, 0 remaining)]

param([string]$Root = "C:\Cygnus\VibeTrading")
$ErrorActionPreference = "SilentlyContinue"

$maintenance = "$Root\state\maintenance.stop"
New-Item -ItemType Directory -Force -Path "$Root\state" | Out-Null
Set-Content -LiteralPath $maintenance -Value ((Get-Date).ToString("o")) -Encoding ASCII

if(Test-Path "$Root\runtime.json"){
  try {
    $r=Get-Content "$Root\runtime.json" -Raw | ConvertFrom-Json
    foreach($pidValue in @($r.api_pid,$r.mcp_pid)){
      if($pidValue){ Stop-Process -Id ([int]$pidValue) -Force -ErrorAction SilentlyContinue }
    }
  } catch {}
}

Get-CimInstance Win32_Process | Where-Object {
  $_.CommandLine -and
  $_.CommandLine -like "*$Root*" -and
  ($_.CommandLine -match "vibe-trading\.exe" -or $_.CommandLine -match "vibe-trading-mcp\.exe" -or $_.CommandLine -match "mcp_server" -or $_.CommandLine -match "api_server")
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Remove-Item "$Root\runtime.json" -Force -ErrorAction SilentlyContinue
Write-Host "VIBE_NATIVE_SERVICES_STOPPED"

[executed on device: WIN-31RCI8K7JR2 (dfb74cc6-deae-45bc-8c9d-634f7d1202b2)]