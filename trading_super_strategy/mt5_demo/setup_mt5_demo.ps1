param(
    [string]$Source = "",
    [int]$Copies = 3,
    [string]$Root = "C:\Trading"
)

$ErrorActionPreference = "Stop"

function Find-MT5Source {
    $candidates = @(
        "C:\Program Files\MetaTrader 5",
        "C:\Program Files (x86)\MetaTrader 5"
    )
    foreach ($p in $candidates) {
        if (Test-Path (Join-Path $p "terminal64.exe")) { return $p }
    }

    $roots = @("C:\Program Files", "C:\Program Files (x86)") | Where-Object { Test-Path $_ }
    foreach ($r in $roots) {
        $hit = Get-ChildItem -Path $r -Filter terminal64.exe -File -Recurse -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.Directory.FullName }
    }
    return ""
}

if (Get-Process terminal64 -ErrorAction SilentlyContinue) {
    Write-Host "Cierra MetaTrader 5 antes de crear las copias y vuelve a ejecutar este archivo." -ForegroundColor Yellow
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Source)) {
    $Source = Find-MT5Source
}

if ([string]::IsNullOrWhiteSpace($Source) -or -not (Test-Path (Join-Path $Source "terminal64.exe"))) {
    Write-Host "No encontre MetaTrader 5 automaticamente." -ForegroundColor Yellow
    $Source = Read-Host "Escribe la carpeta donde esta terminal64.exe"
}

if (-not (Test-Path (Join-Path $Source "terminal64.exe"))) {
    throw "No existe terminal64.exe en: $Source"
}

New-Item -ItemType Directory -Force -Path $Root | Out-Null

$desktop = [Environment]::GetFolderPath("Desktop")
$ws = New-Object -ComObject WScript.Shell
$launcher = @("@echo off")

for ($i = 1; $i -le $Copies; $i++) {
    $name = "MT5-DEMO-{0:D2}" -f $i
    $dest = Join-Path $Root $name

    if (-not (Test-Path $dest)) {
        Write-Host "Creando $name ..."
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Copy-Item -Path (Join-Path $Source "*") -Destination $dest -Recurse -Force
    } else {
        Write-Host "$name ya existe; no se sobrescribe."
    }

    $terminal = Join-Path $dest "terminal64.exe"
    if (-not (Test-Path $terminal)) {
        throw "Falta terminal64.exe en $dest"
    }

    "DEMO ONLY - No usar cuentas reales en esta instancia." |
        Set-Content -Path (Join-Path $dest "DEMO_ONLY.txt") -Encoding UTF8

    $shortcutPath = Join-Path $desktop ("$name.lnk")
    $shortcut = $ws.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $terminal
    $shortcut.Arguments = "/portable"
    $shortcut.WorkingDirectory = $dest
    $shortcut.Description = "$name - MetaTrader 5 DEMO"
    $shortcut.Save()

    $launcher += 'start "" "' + $terminal + '" /portable'
}

$launcherPath = Join-Path $Root "ABRIR-TODOS-DEMO.cmd"
$launcher | Set-Content -Path $launcherPath -Encoding ASCII

Write-Host ""
Write-Host "LISTO" -ForegroundColor Green
Write-Host "Instancias creadas en: $Root"
Write-Host "Accesos directos creados en el Escritorio."
Write-Host "Lanzador de todas: $launcherPath"
Write-Host ""
Write-Host "Siguiente paso: abre cada MT5, inicia una cuenta DEMO distinta y coloca el robot correspondiente."
