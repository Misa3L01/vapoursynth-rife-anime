@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
pushd "%~dp0.."
call "%~dp0..\config.bat"

:: ============================================================================
::  bench.bat - mide fps del pipeline de VapourSynth, SIN encoder.
::
::  Antes de correrlo: cerra juegos, Wallpaper Engine y el navegador. Con la
::  GPU ocupada los numeros no sirven.
::
::  Ojo con los clips cortos: esta GPU esta limitada por POTENCIA (65 W), asi
::  que los primeros segundos corren en boost y dan numeros optimistas. Por eso
::  se miden 1000 frames y no 200.
:: ============================================================================

set "BENCH_SRC=%~1"
if "%BENCH_SRC%"=="" (
    for %%F in ("%INPUT_DIR%\*.mkv" "%INPUT_DIR%\*.mp4") do (
        if not defined BENCH_SRC set "BENCH_SRC=%%~fF"
    )
)
if not exist "%BENCH_SRC%" ( echo [X] No hay video de prueba en %INPUT_DIR%. & goto :fin )

set "FRAMES=%~2"
if "%FRAMES%"=="" set "FRAMES=999"

echo ==========================================================
echo   BENCH  ^|  %BENCH_SRC%
echo   %FRAMES% frames de salida. 47.952 fps = tiempo real.
echo ==========================================================
nvidia-smi --query-gpu=name,memory.free,utilization.gpu,power.draw --format=csv,noheader
echo.

call :bench "1. 4.16_lite v2  ns=2   (balanced)"  4161 2 2 1 0.20
call :bench "2. 4.16_lite v1  ns=2"               4161 0 2 1 0.20
call :bench "3. 4.16_lite v2  ns=1"               4161 2 1 1 0.20
call :bench "4. 4.16_lite v2  ns=3"               4161 2 3 1 0.20
call :bench "5. 4.16_lite v2  sin cuda_graph"     4161 2 2 0 0.20
call :bench "6. 4.16_lite v2  scd 0.10"           4161 2 2 1 0.10
call :bench "7. 4.16_lite v2  sin scd"            4161 2 2 1 0
call :bench "8. 4.26          ns=2   (quality)"   426  0 2 1 0.20

echo.
echo Para medir con encoder incluido: cronometra run.bat sobre un video entero.
echo Si ese numero es mucho peor que el de aca, el cuello esta en NVENC.

:fin
popd
pause
exit /b 0

:: :bench "etiqueta" MODELO IMPL STREAMS CUDAGRAPH UMBRAL_SCD (0 = apagado)
:bench
setlocal
set "RIFE_MODEL=%~2"
set "RIFE_IMPL=%~3"
set "TRT_STREAMS=%~4"
set "TRT_CUDA_GRAPH=%~5"
set "SCENE_THRESHOLD=%~6"
if "%~6"=="0" ( set "SCENE_DETECT=0" ) else ( set "SCENE_DETECT=1" )

echo.
echo --- %~1
:: pasada de calentamiento: compila el engine si hace falta
"%VSPIPE%" -a SRC="%BENCH_SRC%" -e 3 "%VPY%" -- >nul 2>&1
if errorlevel 1 (
    echo     [X] no corre ^(falta el modelo o no hay VRAM^)
    endlocal
    exit /b 1
)
"%VSPIPE%" -a SRC="%BENCH_SRC%" -e %FRAMES% "%VPY%" -- 2>&1 | findstr /c:"Output"
endlocal
exit /b 0
