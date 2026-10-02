@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
:: ============================================================================
::  run-exp.bat  <config>  [video1 video2 ...]
::
::  Renderiza con una configuracion experimental. Sin videos, procesa todos
::  los de videos\. La salida va a experimental\output\ con el sufijo de la
::  config (ej: episodio-E7.mkv).
::
::  Reusa scripts\process-one.bat de produccion SIN modificarlo: solo cambia
::  VPY (el script de VapourSynth) y la carpeta de salida. Asi el render
::  experimental tiene la misma validacion de duracion, el mismo mux de audio,
::  subtitulos y fuentes, y el mismo encoder que produccion.
::
::  Ejemplos:
::    run-exp.bat E7_4161_timeline
::    run-exp.bat X2_calidad_60 "D:\anime\ep01.mkv" "D:\anime\ep02.mkv"
:: ============================================================================

set "EXP_HOME=%~dp0"
if "%EXP_HOME:~-1%"=="\" set "EXP_HOME=%EXP_HOME:~0,-1%"
pushd "%EXP_HOME%\.."
call "%CD%\config.bat"

set "CFG=%~1"
if not defined CFG goto :usage
if not exist "%EXP_HOME%\configs\%CFG%.bat" (
    echo [X] No existe la config "%CFG%".
    goto :usage
)
call "%EXP_HOME%\configs\%CFG%.bat"
:: EXP_FPS48=1 fuerza x2 (47.952 fps) sobre cualquier config que salga a otra
:: tasa, y agrega "-48" al sufijo. Es para monitores de 144 Hz, donde 48 divide
:: exacto (3 refrescos por frame) y 60 no. Lo usa COMPARAR-FLUIDEZ-48.bat.
if "%EXP_FPS48%"=="1" if not "%EXP_MULTI%"=="2" (
    set "EXP_MULTI=2"
    set "EXP_SUFFIX=%EXP_SUFFIX%-48"
)

set "VPY=%EXP_HOME%\vpy\exp_render.vpy"
set "OUTPUT_DIR=%EXP_HOME%\output"
set "OUT_SUFFIX=%EXP_SUFFIX%"
if not exist "%OUTPUT_DIR%" mkdir "%OUTPUT_DIR%" >nul 2>&1

title Experimental %CFG%
echo ==========================================================
echo   EXPERIMENTAL  ^|  %CFG%
echo   modelo %EXP_MODEL%  %EXP_PRECISION%  multi %EXP_MULTI%  res x%EXP_RES_SCALE%
if not defined EXP_SMOOTH set "EXP_SMOOTH=0"
echo   tta %EXP_TTA%  linea de tiempo %EXP_TIMELINE%  ritmo %EXP_SMOOTH%
echo   salida: %OUTPUT_DIR%
echo ==========================================================

set /a OK=0
set /a FAIL=0
shift
if "%~1"=="" goto :all_videos

:args
if "%~1"=="" goto :done
call "%PROC%" "%~f1" "%OUTPUT_DIR%"
if errorlevel 1 ( set /a FAIL+=1 ) else ( set /a OK+=1 )
shift
goto :args

:all_videos
for %%F in ("%INPUT_DIR%\*.mkv" "%INPUT_DIR%\*.mp4" "%INPUT_DIR%\*.m2ts") do (
    call "%PROC%" "%%~fF" "%OUTPUT_DIR%"
    if errorlevel 1 ( set /a FAIL+=1 ) else ( set /a OK+=1 )
)

:done
echo.
echo ==========================================================
echo   %CFG%  -  OK: %OK%   fallidos: %FAIL%
echo ==========================================================
popd
:: EXP_NOPAUSE=1 la saltea: lo usa COMPARAR-FLUIDEZ.bat, que encadena varias
:: configs y pausa una sola vez al final.
if %FAIL% GTR 0 (
    if not defined EXP_NOPAUSE pause
    exit /b 1
)
if not defined EXP_NOPAUSE pause
exit /b 0

:usage
echo.
echo Uso: run-exp.bat ^<config^> [videos...]
echo.
echo Configs disponibles:
for %%C in ("%EXP_HOME%\configs\*.bat") do echo   %%~nC
popd
pause
exit /b 1
