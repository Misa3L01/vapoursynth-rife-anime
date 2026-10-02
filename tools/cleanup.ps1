<#
    cleanup.ps1 - Mantenimiento del entorno.

    La poda grande ya esta hecha (el entorno paso de 7.7 GB a ~2.6 GB). Esto
    sirve para lo que SI se vuelve a ensuciar con el uso:

      * engines de TensorRT de 0 bytes, que quedan cuando un build se queda sin
        VRAM. Se borra tambien su .engine.cache: ese archivo guarda el timing
        cache del intento fallido y, si se reutiliza, el engine siguiente
        hereda tacticas elegidas sin memoria y sale mas lento.
      * engines huerfanos, de modelos que ya no estan.
      * indices .lwi y temporales de render.

    Uso:
        powershell -ExecutionPolicy Bypass -File tools\cleanup.ps1           # informe
        powershell -ExecutionPolicy Bypass -File tools\cleanup.ps1 -Apply    # limpiar
        powershell -ExecutionPolicy Bypass -File tools\cleanup.ps1 -Apply -Engines
              tambien borra TODOS los engines: se reconstruyen en segundos
              (4.16_lite ~3s, 4.26 ~150s) y conviene hacerlo si cambiaste de
              driver NVIDIA o si sospechas que alguno se compilo con la GPU
              ocupada.
#>

param(
    [switch]$Apply,
    [switch]$Engines
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$ModelDirs = @(
    (Join-Path $Root 'Python\plugins64\models\rife'),
    (Join-Path $Root 'Python\plugins64\models\rife_v2')
)

function Show-Size($label, $path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $b = (Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue |
          Measure-Object Length -Sum).Sum
    Write-Host ("  {0,-28} {1,8:N1} MB" -f $label, ($b / 1MB))
}

Write-Host ''
Write-Host ("Modo: {0}" -f $(if ($Apply) { 'LIMPIAR' } else { 'INFORME' }))
Write-Host ('-' * 62)
Write-Host 'Ocupacion actual:'
Show-Size 'Python\ (runtime)'    (Join-Path $Root 'Python')
Show-Size '  modelos RIFE'       (Join-Path $Root 'Python\plugins64\models')
Show-Size '  vsmlrt-cuda'        (Join-Path $Root 'Python\plugins64\vsmlrt-cuda')
Show-Size 'cache\'               (Join-Path $Root 'cache')
Show-Size 'ffmpeg\'              (Join-Path $Root 'ffmpeg')
Write-Host ('-' * 62)

$freed = 0

# --- engines rotos y huerfanos ---------------------------------------------
foreach ($dir in $ModelDirs) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $hasOnnx = (Get-ChildItem -LiteralPath $dir -Filter '*.onnx' -File).Count -gt 0

    foreach ($e in Get-ChildItem -LiteralPath $dir -Filter '*.engine' -File) {
        $reason = $null
        if ($e.Length -eq 0)      { $reason = 'engine de 0 bytes: build que se quedo sin VRAM' }
        elseif (-not $hasOnnx)    { $reason = 'huerfano: no queda ningun .onnx en la carpeta' }
        elseif ($Engines)         { $reason = 'borrado a pedido (-Engines)' }
        if (-not $reason) { continue }

        $cache = "$($e.FullName).cache"
        $size = $e.Length + $(if (Test-Path -LiteralPath $cache) { (Get-Item -LiteralPath $cache).Length } else { 0 })
        $freed += $size
        Write-Host ("  {0,8:N1} MB  {1}" -f ($size / 1MB), $e.Name)
        Write-Host ("             -> {0}" -f $reason)
        if ($Apply) {
            Remove-Item -LiteralPath $e.FullName -Force
            if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Force }
        }
    }
}

# --- cache de trabajo -------------------------------------------------------
foreach ($sub in @('lwi', 'work')) {
    $d = Join-Path $Root "cache\$sub"
    if (-not (Test-Path -LiteralPath $d)) { continue }
    $files = Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue
    if ($files.Count -eq 0) { continue }
    $size = ($files | Measure-Object Length -Sum).Sum
    $freed += $size
    Write-Host ("  {0,8:N1} MB  cache\{1}\  ({2} archivos)" -f ($size / 1MB), $sub, $files.Count)
    Write-Host ("             -> {0}" -f $(if ($sub -eq 'lwi') { 'indices de LSMASHSource, se regeneran solos' } else { 'temporales de render' }))
    if ($Apply) { $files | Remove-Item -Force }
}

Write-Host ('-' * 62)
if ($freed -eq 0) {
    Write-Host 'Nada para limpiar.'
} else {
    Write-Host ("TOTAL: {0:N1} MB" -f ($freed / 1MB))
    if (-not $Apply) { Write-Host 'Informe solamente. Agrega -Apply para borrar.' }
}

# --- nota sobre el unico recorte grande que queda --------------------------
$builders = Get-ChildItem -LiteralPath (Join-Path $Root 'Python\plugins64\vsmlrt-cuda') `
            -Filter 'nvinfer_builder_resource_*' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch 'sm89' }
if ($builders) {
    $b = ($builders | Measure-Object Length -Sum).Sum
    Write-Host ''
    Write-Host ("Aparte: {0:N0} MB en builder resources de otras arquitecturas" -f ($b / 1MB))
    Write-Host '  (esta GPU es sm89 / Ada). Se pueden borrar, PERO entonces el setup'
    Write-Host '  deja de poder compilar engines en una PC con otra placa. Los engines'
    Write-Host '  ya compilados siguen funcionando. No se borran solos a proposito.'
}
