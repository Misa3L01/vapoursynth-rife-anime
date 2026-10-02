@echo off
setlocal
:: UTF-8: los nombres de anime suelen traer caracteres que la pagina de codigos
:: vieja de la consola muestra como signos de pregunta.
chcp 65001 >nul
:: ============================================================================
::  ver-en-vivo.bat  [48|60]  video
::
::  Reproduce un video en mpv interpolado en tiempo real con RIFE. No genera
::  archivos. Lo usan Ver-en-vivo.bat (arrastrar y soltar) y la app (boton
::  "Ver en tiempo real"), asi la forma de abrir mpv esta en un solo lugar.
::
::  Los parametros salen de config.bat (seccion "ver en tiempo real"). Si el
::  primer argumento es 48 o 60, pisa RT_FPS.
::
::  VSAPP_NOPAUSE=1 saltea las pausas: la app lo lanza sin ventana, y una pausa
::  ahi la dejaria esperando para siempre.
:: ============================================================================
call "%~dp0..\config.bat"

set "ARG=%~1"
if "%ARG%"=="48" goto :fps
if "%ARG%"=="60" goto :fps
goto :video
:fps
set "RT_FPS=%ARG%"
shift

:video
if "%~1"=="" goto :usage
set "VIDEO=%~f1"
if not exist "%VIDEO%" (
    echo [X] No existe el video: "%VIDEO%"
    goto :fail
)
if not exist "%MPV%" (
    echo [X] Falta mpv en "%MPV%"
    echo     Corre tools\install-mpv.bat para descargarlo.
    goto :fail
)

:: mpv busca la libreria de VapourSynth en esta variable. Asi usa la de este
:: entorno portable sin registrar nada en Windows.
set "VSSCRIPT_PATH=%VS_ROOT%\Python\Lib\site-packages\vapoursynth\vsscript.dll"

echo.
echo   Tiempo real a %RT_FPS% fps: "%~nx1"
echo   La primera vez con una resolucion nueva, TensorRT tarda unos 2 minutos
echo   en prepararse. Despues arranca en segundos.
echo.

:: 8 frames pedidos en paralelo: con 4, a 60 fps la GPU quedaba esperando entre
:: frame y frame y se perdia uno de cada cinco. Con 8, a 48 fps cero perdidos;
:: a 60 fps (720p), en un episodio real, algun tropiezo aislado como mucho.
:: La configuracion de mpv (saltos, reanudar, Ctrl+I) esta en scripts\mpv y solo
:: se usa desde aca: mpv\ queda con el programa solo, y abrir mpv por otro lado
:: no la toma. Lo que mpv guarda (cache de shaders, por donde ibas) va a cache\mpv.
set "MPV_DATA=%CACHE_DIR%\mpv"
"%MPV%" "--config-dir=%VS_ROOT%\scripts\mpv" "--watch-later-dir=%MPV_DATA%\reanudar" ^
    "--gpu-shader-cache-dir=%MPV_DATA%" "--icc-cache-dir=%MPV_DATA%" ^
    "--vf=@rife:vapoursynth=[%RT_VPY%]:buffered-frames=16:concurrent-frames=8" ^
    --force-window=immediate --msg-level=all=warn,vapoursynth=info -- "%VIDEO%"
set "RC=%errorlevel%"
if not "%RC%"=="0" if not defined VSAPP_NOPAUSE pause
exit /b %RC%

:usage
echo.
echo   Arrastra un video sobre Ver-en-vivo.bat para verlo interpolado en
echo   tiempo real. Desde la consola:
echo.
echo     scripts\ver-en-vivo.bat [48^|60] "video.mkv"
echo.
:fail
if not defined VSAPP_NOPAUSE pause
exit /b 1
