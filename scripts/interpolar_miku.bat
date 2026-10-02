@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
title === RIFE (MODO MIKU AUTONOMO) ===

rem ==========================================================================
rem  interpolar_miku.bat  -  cola automatica, sin interaccion.
rem
rem  CONTRATO (no cambiar, lo usa Miku):
rem    - cada argumento es la RUTA COMPLETA a un video
rem    - la salida se escribe AL LADO del original como "<nombre>-2x.mkv"
rem    - exit 0 = todos los videos se generaron;  exit 1 = al menos uno fallo
rem    - un fallo no corta la cola: sigue con el siguiente
rem
rem  Toda la logica de render vive en scripts\process-one.bat, compartida con
rem  run.bat. Aca solo se arma la cola. Para cambiar modelo, CQ o preset,
rem  edita config.bat (o define PRESET antes de llamar a este script).
rem ==========================================================================

set "VS_ROOT=%~dp0.."
pushd "%VS_ROOT%"
set "VS_ROOT=%CD%"

call "%VS_ROOT%\config.bat"

if not exist "%PROC%" (
    echo [X] Falta %PROC%
    popd
    exit /b 1
)

if "%~1"=="" (
    echo [X] Sin argumentos. Uso: interpolar_miku.bat "video1.mkv" "video2.mkv" ...
    popd
    exit /b 1
)

echo Cola automatica: preset=%PRESET% modelo=%RIFE_MODEL% x%RIFE_MULTI% cq=%CQ%

set /a FALLOS=0
set /a HECHOS=0

for %%V in (%*) do (
    rem La salida va a la MISMA carpeta del video de entrada, que es lo que
    rem Miku espera encontrar despues.
    call "%PROC%" "%%~fV" "%%~dpV"
    if errorlevel 1 ( set /a FALLOS+=1 ) else ( set /a HECHOS+=1 )
)

echo.
echo Cola terminada. OK: !HECHOS!  fallidos: !FALLOS!

popd
if !FALLOS! GTR 0 exit /b 1
exit /b 0
