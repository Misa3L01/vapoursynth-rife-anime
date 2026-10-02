@echo off
setlocal enabledelayedexpansion
:: ============================================================================
::  setup.bat - Arma el entorno PyTorch aislado para probar modelos de
::  interpolacion que no pueden correr en el VapourSynth de produccion.
::
::  Por que hace falta: GMFSS, AMT y EMA-VFI son codigo PyTorch, y el Python
::  del VapourSynth (3.13, embebido) no sirve para eso. Este entorno tiene su
::  propio Python 3.12 y su propio PyTorch, y no toca nada de produccion.
::
::  Todo queda dentro de esta carpeta, incluidos los cache de descarga: el
::  disco C: no se usa.
::
::  Es idempotente: se puede volver a correr y solo hace lo que falta.
::  Ocupa unos 7 GB.
:: ============================================================================

set "ENV=%~dp0"
if "%ENV:~-1%"=="\" set "ENV=%ENV:~0,-1%"
set "UV=%ENV%\bin\uv.exe"
set "VENV=%ENV%\venv"
set "PY=%VENV%\Scripts\python.exe"

:: cache y Python administrado, todo adentro de la carpeta
set "UV_CACHE_DIR=%ENV%\.uv-cache"
set "UV_PYTHON_INSTALL_DIR=%ENV%\python"
set "UV_PYTHON_PREFERENCE=only-managed"
set "UV_LINK_MODE=copy"

echo ==========================================================
echo   Entorno PyTorch experimental
echo   destino: %ENV%
echo ==========================================================

:: ---------------------------------------------------------------- uv ------
if not exist "%UV%" (
    echo [1/5] Bajando uv...
    mkdir "%ENV%\bin" 2>nul
    curl -L -s -o "%ENV%\bin\uv.zip" https://github.com/astral-sh/uv/releases/download/0.12.17/uv-x86_64-pc-windows-msvc.zip || goto :fail
    tar -xf "%ENV%\bin\uv.zip" -C "%ENV%\bin" || goto :fail
    del "%ENV%\bin\uv.zip"
) else ( echo [1/5] uv ya esta )

:: ------------------------------------------------------------- python -----
if not exist "%PY%" (
    echo [2/5] Creando entorno con Python 3.12...
    "%UV%" venv --python 3.12 "%VENV%" || goto :fail
) else ( echo [2/5] entorno ya creado )

:: -------------------------------------------------------------- torch -----
echo [3/5] Instalando PyTorch (CUDA 12.8) y dependencias... ^(descarga grande^)
:: CUDA 12.8 y CuPy para CUDA 12: misma version mayor de CUDA en los dos. Con
:: torch para CUDA 13 habria dos runtimes distintos en el mismo proceso.
"%UV%" pip install --python "%PY%" torch==2.11.0 torchvision --index-url https://download.pytorch.org/whl/cu128 || goto :fail
:: cupy: lo usa el kernel de softsplat de GMFSS. numpy: puente con el runner.
:: timm: lo pide EMA-VFI. gdown: los pesos de GMFSS y EMA-VFI estan en Drive.
"%UV%" pip install --python "%PY%" numpy "cupy-cuda12x[ctk]" timm gdown || goto :fail
:: GIMM-VFI: omegaconf/easydict/einops/yacs son su maquinaria de configuracion,
:: scipy y opencv los pide RAFT.
"%UV%" pip install --python "%PY%" omegaconf easydict einops yacs scipy opencv-python-headless || goto :fail

:: --------------------------------------------------------------- repos ----
echo [4/5] Clonando el codigo de los modelos...
if not exist "%ENV%\repos" mkdir "%ENV%\repos"
call :clone 98mxr/GMFSS_Fortuna  GMFSS_Fortuna
call :clone MCG-NKU/AMT          AMT
call :clone MCG-NJU/EMA-VFI      EMA-VFI
call :clone GSeanCDAT/GIMM-VFI  GIMM-VFI
call :clone HolyWu/vs-rife       vs-rife

:: --------------------------------------------------------------- pesos ----
echo [5/5] Bajando pesos...
if not exist "%ENV%\weights" mkdir "%ENV%\weights"

if not exist "%ENV%\weights\gmfss_union_anime\flownet.pkl" (
    echo     GMFSS union ^(afinado con anime^)...
    "%PY%" -c "import gdown, os; os.chdir(r'%ENV%\weights'); gdown.download(id='1_03uH6IvetezZIaYZzacxuXu-R4TklVc', output='g.zip', quiet=True)" || goto :fail
    tar -xf "%ENV%\weights\g.zip" -C "%ENV%\weights" || goto :fail
    move "%ENV%\weights\train_log" "%ENV%\weights\gmfss_union_anime" >nul
    del "%ENV%\weights\g.zip"
)

for %%M in (amt-s amt-l amt-g) do (
    if not exist "%ENV%\weights\%%M.pth" (
        echo     %%M...
        curl -L -s -o "%ENV%\weights\%%M.pth" "https://huggingface.co/lalala125/AMT/resolve/main/%%M.pth" || goto :fail
    )
)

if not exist "%ENV%\weights\ema\ckpt\ours_t.pkl" (
    echo     EMA-VFI...
    "%PY%" -c "import gdown, os; os.makedirs(r'%ENV%\weights\ema', exist_ok=True); os.chdir(r'%ENV%\weights\ema'); gdown.download_folder(id='16jUa3HkQ85Z5lb5gce1yoaWkP-rdCd0o', quiet=True, use_cookies=False)" || goto :fail
)

if not exist "%ENV%\weights\gimm\gimmvfi_r_arb.pt" (
    echo     GIMM-VFI ^(pesos + RAFT^)...
    if not exist "%ENV%\weights\gimm" mkdir "%ENV%\weights\gimm"
    for %%W in (gimmvfi_r_arb.pt raft-things.pth) do (
        curl -L -s -o "%ENV%\weights\gimm\%%W" "https://huggingface.co/GSean/GIMM-VFI/resolve/main/%%W" || goto :fail
    )
)

:: El repo de GIMM-VFI es de la epoca de Python 3.10 y CuPy 12: hay que
:: adaptarlo. El script es idempotente.
"%PY%" "%ENV%\vfi\patch_gimm.py" || goto :fail

echo.
echo Verificando...
"%PY%" -c "import torch, cupy; print('  torch', torch.__version__, '| CUDA', torch.cuda.is_available(), '|', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'sin GPU'); print('  cupy', cupy.__version__)" || goto :fail

echo.
echo Listo. Para medir:
echo   Python\python.exe experimental\tools\bench_torch.py videos\salida.mp4 gmfss_u
echo.
echo El cache de descarga ^(%ENV%\.uv-cache^) se puede borrar para liberar espacio.
exit /b 0

:clone
if not exist "%ENV%\repos\%~2" (
    echo     %~2
    git clone -q --depth 1 "https://github.com/%~1.git" "%ENV%\repos\%~2" || exit /b 1
)
exit /b 0

:fail
echo.
echo [X] Fallo la instalacion.
exit /b 1
