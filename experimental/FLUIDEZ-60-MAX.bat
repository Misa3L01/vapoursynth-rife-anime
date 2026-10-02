@echo off
setlocal
:: ============================================================================
::  FLUIDEZ-60-MAX.bat
::
::  Doble clic: procesa todos los videos de la carpeta videos\
::  O arrastra uno o varios archivos encima de este .bat.
::
::  Salida: 59.94 fps con la config D6_max_total_60, la mas fluida medida.
::  Va a experimental\output\ con sufijo -D6.
::
::  Es D2 con todo al extremo: deteccion de repetidos agresiva, ningun dibujo
::  quieto, suavizador de ritmo fuerte y finales de toma interpolados. Maximo
::  "efecto telenovela", y tambien la que mas artefactos puede traer.
::
::  Para comparar con las demas sobre un mismo video: COMPARAR-FLUIDEZ.bat
::  La version mas moderada (D2): FLUIDEZ-60.bat
:: ============================================================================
set "EXP_HOME=%~dp0"
if "%EXP_HOME:~-1%"=="\" set "EXP_HOME=%EXP_HOME:~0,-1%"

echo.
echo   Interpolando a 60 fps - fluidez maxima (D6)
echo.

call "%EXP_HOME%\run-exp.bat" D6_max_total_60 %*
exit /b %errorlevel%
