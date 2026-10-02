@echo off
setlocal
:: ============================================================================
::  COMPARAR-FLUIDEZ-48.bat
::
::  Lo mismo que COMPARAR-FLUIDEZ.bat pero todo a 47.952 fps, para monitores
::  de 144 Hz (donde 48 divide exacto y 60 tironea).
::
::  Arrastra un video encima (mejor uno corto, 1 o 2 minutos). Sin arrastrar
::  nada, usa los videos de la carpeta videos\.
::
::  Salida en experimental\output\, un archivo por nivel:
::
::    -X1      calidad: la deteccion de repetidos mas prudente
::    -D2-48   fluidez: dedup "en dos y en tres" mas agresivo
::    -D4-48   D2 + suavizador de ritmo (lo mas parecido al D2 de SVFI)
::    -D3b-48  D2 sin limite de pausa: ningun dibujo se deja quieto
::    -D3-48   D3b + deteccion de repetidos todavia mas agresiva
::    -D5-48   todo al maximo: D3 + suavizador de ritmo fuerte
::    -D6-48   D5 + finales de toma interpolados: la mas fluida
::
::  Van de menos a mas agresivo: mas fluidez, mas artefactos.
:: ============================================================================
set "EXP_HOME=%~dp0"
if "%EXP_HOME:~-1%"=="\" set "EXP_HOME=%EXP_HOME:~0,-1%"
set "EXP_NOPAUSE=1"
set "EXP_FPS48=1"

for %%C in (X1_calidad_48 D2_fluidez_60 D4_ritmo_60 D3b_gap_max_60 D3_fluidez_max_60 D5_todo_max_60 D6_max_total_60) do (
    call "%EXP_HOME%\run-exp.bat" %%C %*
)

echo.
echo ==========================================================
echo   Listo. Abri los archivos de experimental\output\ y
echo   compara los sufijos -X1 -D2-48 -D4-48 -D3b-48 -D3-48
echo   -D5-48 -D6-48
echo ==========================================================
pause
exit /b 0
