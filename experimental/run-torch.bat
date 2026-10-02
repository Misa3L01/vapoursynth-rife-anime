@echo off
setlocal
:: ============================================================================
::  run-torch.bat  [modelo] [metodo] [videos...]
::
::  Renderiza con los modelos del entorno PyTorch (GMFSS, AMT, EMA-VFI).
::  Sin videos, procesa los de videos\. La salida va a experimental\output\.
::
::  Modelos: gmfss_u (el mejor medido), amt_g, amt_l, ema_small, blend, hold.
::
::  OJO con los tiempos: GMFSS a escala completa corre a x0.034 tiempo real,
::  o sea unas 5 horas por cada 10 minutos de video. Es para archivar, no
::  para una cola.
::
::  Ejemplos:
::    run-torch.bat gmfss_u
::    run-torch.bat gmfss_u "D:\anime\ep01.mkv"
::    run-torch.bat amt_l
::    run-torch.bat gmfss_u D4_ritmo_60 "D:\anime\clip.mkv"
::
::  El metodo es el nombre de una config de configs\ (D2_fluidez_60,
::  D4_ritmo_60...): toma de ahi los fps de salida y la linea de tiempo, asi
::  se puede combinar cualquier modelo con cualquier metodo, como en SVFI.
:: ============================================================================
set "EXP=%~dp0"
if "%EXP:~-1%"=="\" set "EXP=%EXP:~0,-1%"

if not exist "%EXP%\torch-env\venv\Scripts\python.exe" (
    echo [X] Falta el entorno PyTorch. Corre primero:
    echo     experimental\torch-env\setup.bat
    pause
    exit /b 1
)

set "MODEL=%~1"
if not defined MODEL set "MODEL=gmfss_u"
shift

set "CONFIG_ARG="
if not "%~1"=="" if exist "%EXP%\configs\%~1.bat" (
    set "CONFIG_ARG=--config %~1"
    shift
)

set "VIDEOS="
:args
if "%~1"=="" goto :go
set VIDEOS=%VIDEOS% "%~f1"
shift
goto :args

:go
"%EXP%\..\Python\python.exe" "%EXP%\tools\render_torch.py" %VIDEOS% --model %MODEL% %CONFIG_ARG%
pause
exit /b %errorlevel%
