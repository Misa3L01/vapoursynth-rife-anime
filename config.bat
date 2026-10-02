@echo off
:: ============================================================================
::  config.bat - Unico lugar donde se tocan parametros.
::  No se ejecuta solo: lo llama run.bat / tools\bench.bat.
:: ============================================================================

:: ---------------------------------------------------------------- rutas ----
set "VS_ROOT=%~dp0"
if "%VS_ROOT:~-1%"=="\" set "VS_ROOT=%VS_ROOT:~0,-1%"

set "VSPIPE=%VS_ROOT%\Python\Scripts\vspipe.exe"
set "FFMPEG=%VS_ROOT%\ffmpeg\bin\ffmpeg.exe"
set "FFPROBE=%VS_ROOT%\ffmpeg\bin\ffprobe.exe"
set "VPY=%VS_ROOT%\scripts\interpolate.vpy"
set "PROC=%VS_ROOT%\scripts\process-one.bat"

set "INPUT_DIR=%VS_ROOT%\videos"
set "OUTPUT_DIR=%VS_ROOT%\output"
set "CACHE_DIR=%VS_ROOT%\cache"
set "LWI_CACHE=%CACHE_DIR%\lwi"

:: Carpeta temporal REAL del sistema. Nunca sobrescribas TEMP/TMP: son
:: variables reservadas de Windows y las heredan ffmpeg, Python y TensorRT.
set "WORK_DIR=%CACHE_DIR%\work"

:: ------------------------------------------------------------- preset ------
::  speed | balanced | quality
if not defined PRESET set "PRESET=balanced"

:: ------------------------------------------- defaults (los pisa el preset) --
set "RIFE_MODEL=4161"
set "RIFE_MULTI=2"
set "RIFE_IMPL=2"
set "RIFE_ENSEMBLE=0"

set "TRT_STREAMS=2"
set "TRT_CUDA_GRAPH=1"
set "TRT_OPT_LEVEL=3"
set "TRT_OUTPUT_FORMAT=1"
set "TRT_DEVICE=0"

set "SCENE_DETECT=1"
set "SCENE_THRESHOLD=0.20"

set "TO_RGB_KERNEL=Bicubic"
set "DITHER=error_diffusion"

set "CAS_SHARPNESS=0.35"
set "CAS_LUMA_ONLY=1"
set "DEBAND=0"

set "VS_CACHE_MB=1200"
set "VS_THREADS=0"

:: --------------------------------------------------------- encoder ---------
::  hevc_nvenc (compatible) | av1_nvenc (mejor compresion, Ada+, menos players)
set "ENCODER=hevc_nvenc"
set "CQ=20"
set "NV_PRESET=p7"
set "NV_MULTIPASS=disabled"
set "NV_AQ_STRENGTH=8"
set "NV_GOP=240"
set "NV_LOOKAHEAD=32"

:: --------------------------------------------------------- audio / mux -----
::  copy = passthrough de TODAS las pistas (por defecto, sin perdida)
::  flac = re-encode sin perdida, arregla fuentes con audio "cortado"
::  aac  = re-encode con perdida (solo si necesitas compatibilidad)
set "AUDIO_MODE=copy"
set "AUDIO_BITRATE=320k"

set "OUT_SUFFIX=-2x"

:: --------------------------------------------------- ver en tiempo real -----
::  Ver anime interpolado en vivo con mpv, sin generar archivos. Se abre desde
::  la app (boton "Ver en tiempo real") o arrastrando un video sobre
::  Ver-en-vivo.bat. Medido en esta PC: 61 s de reproduccion sin perder frames.
::
::  RT_FPS    48 = x2, para monitores de 144 y 240 Hz (en 144 Hz cada frame
::                 dura justo 3 refrescos).
::            60 = x2.5, para monitores de 60 y 120 Hz. A 1080p esta GPU no
::                 llega: se interpola a 720p y mpv lo lleva a pantalla completa.
::  RT_MODEL  4161 = 4.16 lite: 62 fps de salida a 1080p x2, con margen.
::            4.26 no llega a tiempo real en esta GPU.
::  RT_RES    auto = 1080 a 48 fps y 720 a 60 fps. 0 = siempre la nativa.
::  RT_CAS    nitidez despues de interpolar (0 = sin CAS).
set "RT_FPS=48"
set "RT_MODEL=4161"
set "RT_RES=auto"
set "RT_CAS=0.35"
set "MPV=%VS_ROOT%\mpv\mpv.com"
set "RT_VPY=%VS_ROOT%\scripts\realtime.vpy"

:: ------------------------------------------------------- aplicar preset ----
if exist "%VS_ROOT%\presets\%PRESET%.bat" (
    call "%VS_ROOT%\presets\%PRESET%.bat"
) else (
    echo [AVISO] Preset "%PRESET%" no encontrado, se usan los defaults.
)

:: --------------------------------------------------- exportar a la vpy -----
:: interpolate.vpy lee estas variables del entorno.
set "VS_ROOT=%VS_ROOT%"

if not exist "%OUTPUT_DIR%" mkdir "%OUTPUT_DIR%" >nul 2>&1
if not exist "%LWI_CACHE%" mkdir "%LWI_CACHE%" >nul 2>&1
if not exist "%WORK_DIR%"  mkdir "%WORK_DIR%"  >nul 2>&1

exit /b 0
