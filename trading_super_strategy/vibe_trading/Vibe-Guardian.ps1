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
  if(-not (PortOpen 8899) -or -not (PortOpen 8900)){
    try {
      powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $start | Out-Null
    } catch {}
  }
  Start-Sleep -Seconds 60
}
