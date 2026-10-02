@echo off
setlocal
:: ============================================================================
::  FLUIDEZ-60.bat
::
::  Doble clic: procesa todos los videos de la carpeta videos\
::  O arrastra uno o varios archivos encima de este .bat.
::
::  Salida: 59.94 fps, maxima fluidez, en experimental\output\ con sufijo -D2
::
::  Si te gusta pero querias menos artefactos, corre en su lugar:
::      experimental\run-exp.bat X2_calidad_60
::  que es lo mismo con la deteccion de repetidos menos agresiva.
:: ============================================================================
set "EXP_HOME=%~dp0"
if "%EXP_HOME:~-1%"=="\" set "EXP_HOME=%EXP_HOME:~0,-1%"

echo.
echo   Interpolando a 60 fps - maxima fluidez (D2)
echo.

call "%EXP_HOME%\run-exp.bat" D2_fluidez_60 %*
exit /b %errorlevel%
