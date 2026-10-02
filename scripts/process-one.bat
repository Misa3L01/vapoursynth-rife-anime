@echo off
:: ============================================================================
::  process-one.bat  "<video origen>"  "<carpeta salida>"
::
::  Procesa UN video: interpola, codifica, valida y muxea.
::  Devuelve 0 si la salida quedo bien, 1 si fallo.
::
::  Lo usan run.bat (cola interactiva) y interpolar_miku.bat (cola automatica).
::  Espera que config.bat ya se haya ejecutado en el entorno actual.
::
::  Delayed expansion APAGADA a proposito: los nombres de los releases suelen
::  traer caracteres raros y con "!" habilitado cmd se los come.
:: ============================================================================
setlocal disabledelayedexpansion

set "SRC=%~f1"
set "DEST_DIR=%~2"
if not defined DEST_DIR set "DEST_DIR=%OUTPUT_DIR%"
:: La carpeta de destino puede venir con barra final (Miku pasa la carpeta
:: del video con el modificador de ruta del for). Sin esto quedaria doble.
:: OJO: no escribas modificadores de parametro tipo porcentaje-tilde-dp en
:: un comentario, cmd los expande igual y aborta el script.
if "%DEST_DIR:~-1%"=="\" set "DEST_DIR=%DEST_DIR:~0,-1%"

if not exist "%SRC%" (
    echo [X] No existe: %SRC%
    exit /b 1
)

set "NAME=%~n1"
set "OUT=%DEST_DIR%\%NAME%%OUT_SUFFIX%.mkv"
set "TMPVID=%WORK_DIR%\%NAME%%OUT_SUFFIX%.video.mkv"
set "TMPAUD=%WORK_DIR%\%NAME%.audio.mka"
set "PROBE=%WORK_DIR%\%NAME%.probe.txt"

if not exist "%DEST_DIR%" mkdir "%DEST_DIR%" >nul 2>&1

echo.
echo ----------------------------------------------------------
echo  ^> %NAME%
echo    salida: %OUT%
echo ----------------------------------------------------------

:: --- 1. espacio de color real de la fuente ---------------------------------
:: y4m no transporta matriz ni rango, hay que re-etiquetar la salida a mano.
::
:: ffprobe escribe a un archivo y despues se lee con for /f. Parece un rodeo,
:: pero con el comando entre backticks cmd /c se come las comillas exteriores
:: y parte la ruta del .exe: la variable queda vacia y nada avisa.
set "CSP=bt709"
set "PRIM=bt709"
set "TRC=bt709"
set "RNG=tv"
"%FFPROBE%" -v error -select_streams v:0 -show_entries stream=color_space,color_primaries,color_transfer,color_range -of default=nw=1 "%SRC%" > "%PROBE%" 2>nul
for /f "usebackq tokens=1,2 delims==" %%A in ("%PROBE%") do (
    if /i "%%A"=="color_space"     if not "%%B"=="unknown" set "CSP=%%B"
    if /i "%%A"=="color_primaries" if not "%%B"=="unknown" set "PRIM=%%B"
    if /i "%%A"=="color_transfer"  if not "%%B"=="unknown" set "TRC=%%B"
    if /i "%%A"=="color_range"     if not "%%B"=="unknown" set "RNG=%%B"
)
echo    color: %CSP% / %PRIM% / %TRC% / %RNG%

set "SRC_DUR=0"
"%FFPROBE%" -v error -show_entries format=duration -of default=nw=1:nk=1 "%SRC%" > "%PROBE%" 2>nul
for /f "usebackq delims=." %%D in ("%PROBE%") do set "SRC_DUR=%%D"
set /a SRC_DUR=SRC_DUR+0 2>nul || set "SRC_DUR=0"

:: --- 2. interpolar + codificar ---------------------------------------------
echo [1/3] Interpolando y codificando...
if exist "%TMPVID%" del "%TMPVID%" >nul 2>&1

"%VSPIPE%" -c y4m -a SRC="%SRC%" "%VPY%" - | "%FFMPEG%" -hide_banner -loglevel warning -stats -y ^
 -f yuv4mpegpipe -i pipe:0 ^
 -c:v %ENCODER% -preset %NV_PRESET% -tune hq ^
 -rc vbr -cq %CQ% -b:v 0 -multipass %NV_MULTIPASS% ^
 -spatial-aq 1 -aq-strength %NV_AQ_STRENGTH% -temporal-aq 1 ^
 -rc-lookahead %NV_LOOKAHEAD% -bf 4 -b_ref_mode middle -g %NV_GOP% ^
 -pix_fmt p010le ^
 -colorspace %CSP% -color_primaries %PRIM% -color_trc %TRC% -color_range %RNG% ^
 -fps_mode passthrough ^
 "%TMPVID%"

if not exist "%TMPVID%" (
    echo [X] El render no genero archivo.
    goto :fail
)

:: --- 3. validar que no se corto a la mitad ---------------------------------
:: En cmd, "A ^| B" devuelve el errorlevel de B. Si vspipe muere a mitad de
:: camino, ffmpeg cierra limpio con 0 y deja un video truncado. Por eso se
:: compara la duracion en vez de confiar en el codigo de salida.
set "OUT_DUR=0"
"%FFPROBE%" -v error -show_entries format=duration -of default=nw=1:nk=1 "%TMPVID%" > "%PROBE%" 2>nul
for /f "usebackq delims=." %%D in ("%PROBE%") do set "OUT_DUR=%%D"
set /a OUT_DUR=OUT_DUR+0 2>nul || set "OUT_DUR=0"
del "%PROBE%" >nul 2>&1

if %SRC_DUR% LEQ 0 (
    echo [X] No se pudo leer la duracion de la fuente, no hay con que validar.
    goto :fail
)
set /a DUR_DIFF=%SRC_DUR%-%OUT_DUR%
if %DUR_DIFF% LSS 0 set /a DUR_DIFF=-%DUR_DIFF%
if %DUR_DIFF% GTR 2 (
    echo [X] Render truncado: fuente %SRC_DUR%s vs salida %OUT_DUR%s.
    goto :fail
)

:: --- 4. audio ---------------------------------------------------------------
:: Orden de entradas del mux: 0 = video interpolado, 1 = fuente original,
:: 2 = audio re-encodeado (solo en modo flac). Los -map dependen de esto.
set "AUDIO_INPUT="
set "AUDIO_MAP=-map 1:a?"
set "AUDIO_CODEC=-c:a copy"

if /i "%AUDIO_MODE%"=="flac" (
    echo [2/3] Re-encodeando audio a FLAC ^(sin perdida^)...
    "%FFMPEG%" -hide_banner -loglevel warning -y -i "%SRC%" -vn -sn -dn -map 0:a -c:a flac "%TMPAUD%"
    if not exist "%TMPAUD%" ( echo [X] Fallo la extraccion de audio. & goto :fail )
    set "AUDIO_INPUT=-i "%TMPAUD%""
    set "AUDIO_MAP=-map 2:a?"
    set "AUDIO_CODEC=-c:a copy"
)
if /i "%AUDIO_MODE%"=="aac" set "AUDIO_CODEC=-c:a aac -b:a %AUDIO_BITRATE%"
if /i "%AUDIO_MODE%"=="copy" echo [2/3] Audio: copia directa de todas las pistas.

:: --- 5. mux -----------------------------------------------------------------
:: -map 1:t?  copia los ATTACHMENTS (las tipografias de los subtitulos ASS).
:: Sin esto los subs se renderizan con otra fuente.
echo [3/3] Muxeando...
if exist "%OUT%" del "%OUT%" >nul 2>&1

"%FFMPEG%" -hide_banner -loglevel warning -stats -y ^
 -i "%TMPVID%" -i "%SRC%" %AUDIO_INPUT% ^
 -map 0:v:0 %AUDIO_MAP% -map 1:s? -map 1:t? ^
 -map_chapters 1 -map_metadata 1 ^
 -c:v copy %AUDIO_CODEC% -c:s copy ^
 -colorspace %CSP% -color_primaries %PRIM% -color_trc %TRC% -color_range %RNG% ^
 -max_interleave_delta 0 ^
 "%OUT%"

if not exist "%OUT%" ( echo [X] Fallo el muxing. & goto :fail )
for %%A in ("%OUT%") do if %%~zA LSS 1024 (
    echo [X] La salida quedo vacia.
    del "%OUT%" >nul 2>&1
    goto :fail
)

del "%TMPVID%" >nul 2>&1
if exist "%TMPAUD%" del "%TMPAUD%" >nul 2>&1
echo [OK] %NAME%%OUT_SUFFIX%.mkv
endlocal
exit /b 0

:fail
del "%TMPVID%" >nul 2>&1
if exist "%TMPAUD%" del "%TMPAUD%" >nul 2>&1
if exist "%PROBE%" del "%PROBE%" >nul 2>&1
echo [FALLO] %NAME%
endlocal
exit /b 1
