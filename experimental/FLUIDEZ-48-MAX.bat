@echo off
setlocal
:: ============================================================================
::  FLUIDEZ-48-MAX.bat
::
::  Doble clic: procesa todos los videos de la carpeta videos\
::  O arrastra uno o varios archivos encima de este .bat.
::
::  Salida: 47.952 fps con D6 (la config mas fluida medida), en
::  experimental\output\ con sufijo -D6-48.
::
::  Es la indicada para un monitor de 144 Hz: cada frame dura exactamente 3
::  refrescos. A 60 fps el reproductor tendria que alternar frames de 2 y 3
::  refrescos, y eso se ve como un tironeo periodico.
::
::  Para comparar todos los niveles a 48 fps: COMPARAR-FLUIDEZ-48.bat
:: ============================================================================
set "EXP_HOME=%~dp0"
if "%EXP_HOME:~-1%"=="\" set "EXP_HOME=%EXP_HOME:~0,-1%"

echo.
echo   Interpolando a 48 fps - fluidez maxima (D6)
echo.

call "%EXP_HOME%\run-exp.bat" D6_max_total_48 %*
exit /b %errorlevel%
