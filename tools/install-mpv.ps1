<#
    install-mpv.ps1 - Descarga mpv en la carpeta mpv\ del entorno.

    Lo necesita "Ver en tiempo real". Se abre con tools\install-mpv.bat. Se puede
    volver a correr para actualizar: reemplaza el programa, y la configuracion
    no se toca porque vive aparte, en scripts\mpv.

    Usa la compilacion de shinchiro (la que enlaza mpv.io para Windows), version
    x86_64 comun y no la "v3": la v3 exige una CPU con AVX2 y la carpeta dejaria
    de funcionar al llevarla a una PC mas vieja.

    Descomprime con el tar que trae Windows, que abre .7z: no hace falta 7-Zip.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # con la barra, Invoke-WebRequest de PS 5.1 baja 10 veces mas lento
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Dest = Join-Path $Root 'mpv'
$Tmp  = Join-Path $Root 'cache\mpv-descarga.7z'
$Tar  = Join-Path $env:SystemRoot 'System32\tar.exe'

if (-not (Test-Path -LiteralPath $Tar)) { throw "No se encontro $Tar (hace falta Windows 10 1803 o posterior)." }

Write-Host 'Buscando la ultima version de mpv...'
$rel = Invoke-RestMethod 'https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/latest' -UseBasicParsing
$asset = $rel.assets | Where-Object { $_.name -match '^mpv-x86_64-\d{8}-git-[0-9a-f]+\.7z$' } | Select-Object -First 1
if (-not $asset) { throw "La version $($rel.tag_name) no trae el archivo de mpv x86_64 esperado." }

Write-Host ('Descargando {0} ({1:N0} MB)...' -f $asset.name, ($asset.size / 1MB))
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Tmp) | Out-Null
Invoke-WebRequest $asset.browser_download_url -OutFile $Tmp -UseBasicParsing

Write-Host 'Descomprimiendo...'
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
& $Tar -xf $Tmp -C $Dest
if ($LASTEXITCODE -ne 0) { throw "tar fallo con codigo $LASTEXITCODE" }
Remove-Item -LiteralPath $Tmp -Force

$ver = & (Join-Path $Dest 'mpv.com') --version | Select-Object -First 1
Write-Host ''
Write-Host "Listo: $ver"
