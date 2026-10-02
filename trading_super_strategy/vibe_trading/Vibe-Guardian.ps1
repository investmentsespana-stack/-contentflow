[Reading 24 lines from start (total: 24 lines, 0 remaining)]

param([string]$Root = "C:\Cygnus\VibeTrading")
$ErrorActionPreference = "SilentlyContinue"
$start = "$Root\Start-VibeNative.ps1"

function PortOpen([int]$Port){
  try {
    $c=New-Object System.Net.Sockets.TcpClient
    $a=$c.BeginConnect("127.0.0.1",$Port,$null,$null)
    if(-not $a.AsyncWaitHandle.WaitOne(1000)){ $c.Close(); return $false }
    $c.EndConnect($a); $c.Close(); return $true
  } catch { return $false }
}

while($true){
  $maintenance = "$Root\state\maintenance.stop"
  if(-not (Test-Path $maintenance)){
    if(-not (PortOpen 8899) -or -not (PortOpen 8900)){
      try {
        powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $start | Out-Null
      } catch {}
    }
  }
  Start-Sleep -Seconds 60
}

[executed on device: WIN-31RCI8K7JR2 (dfb74cc6-deae-45bc-8c9d-634f7d1202b2)]