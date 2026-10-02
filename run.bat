@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul

:: pushd al directorio del script: funciona igual desde un acceso directo,
:: desde otra unidad o con doble clic, sin depender del CWD.
pushd "%~dp0"
call "%~dp0config.bat"

title RIFE %RIFE_MODEL% x%RIFE_MULTI% [%PRESET%] - cola selectiva

echo ==========================================================
echo   RIFE + CAS  ^|  preset: %PRESET%  ^|  modelo: %RIFE_MODEL%
echo   multi: x%RIFE_MULTI%   encoder: %ENCODER% cq%CQ% (%NV_PRESET%)
echo   entrada: %INPUT_DIR%
echo   salida : %OUTPUT_DIR%
echo ==========================================================
echo.

if not exist "%VSPIPE%"  ( echo [X] No existe vspipe:  %VSPIPE%  & goto :fin )
if not exist "%FFMPEG%"  ( echo [X] No existe ffmpeg:  %FFMPEG%  & goto :fin )
if not exist "%FFPROBE%" ( echo [X] No existe ffprobe: %FFPROBE% & goto :fin )
if not exist "%VPY%"     ( echo [X] No existe el script: %VPY%   & goto :fin )
if not exist "%PROC%"    ( echo [X] No existe: %PROC%            & goto :fin )

:: ------------------------------------------------------- listar entradas ---
set "count=0"
for %%F in ("%INPUT_DIR%\*.mkv" "%INPUT_DIR%\*.mp4" "%INPUT_DIR%\*.m2ts" "%INPUT_DIR%\*.avi" "%INPUT_DIR%\*.webm") do (
    set /a count+=1
    set "file_!count!=%%~fF"
    echo   !count! - %%~nxF
)

if "%count%"=="0" (
    echo [AVISO] No hay videos en "%INPUT_DIR%".
    goto :fin
)

echo.
echo Numeros separados por espacio, o ALL para todos.
set "sel="
set /p "sel=Seleccion: "
if not defined sel ( echo [AVISO] Sin seleccion. & goto :fin )

if /i "%sel%"=="all" (
    set "sel="
    for /l %%I in (1,1,%count%) do set "sel=!sel! %%I"
)

:: ------------------------------------------------------------ procesar -----
set /a OK_COUNT=0
set /a FAIL_COUNT=0

for %%N in (%sel%) do (
    set "TARGET=!file_%%N!"
    if defined TARGET (
        call "%PROC%" "!TARGET!" "%OUTPUT_DIR%"
        if errorlevel 1 ( set /a FAIL_COUNT+=1 ) else ( set /a OK_COUNT+=1 )
    ) else (
        echo [AVISO] "%%N" no corresponde a ningun video de la lista. Se omite.
    )
    set "TARGET="
)

echo.
echo ==========================================================
echo   COLA FINALIZADA  -  OK: %OK_COUNT%   fallidos: %FAIL_COUNT%
echo ==========================================================

:fin
popd
pause
exit /b 0
