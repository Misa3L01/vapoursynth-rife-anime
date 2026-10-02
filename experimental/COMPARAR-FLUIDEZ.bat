@echo off
setlocal
:: ============================================================================
::  COMPARAR-FLUIDEZ.bat
::
::  Arrastra un video encima (mejor uno corto, 1 o 2 minutos) y lo renderiza
::  a 60 fps con cada nivel de fluidez, para que los compares a ojo.
::  Sin arrastrar nada, usa los videos de la carpeta videos\.
::
::  Salida en experimental\output\, un archivo por nivel:
::
::    -X2   calidad: la deteccion de repetidos mas prudente
::    -D2   fluidez: dedup "en dos y en tres" mas agresivo
::    -D4   D2 + suavizador de ritmo (lo mas parecido al D2 de SVFI)
::    -D3b  D2 sin limite de pausa: ningun dibujo se deja quieto
::    -D3   D3b + deteccion de repetidos todavia mas agresiva
::    -D5   todo al maximo: D3 + suavizador de ritmo fuerte
::    -D6   D5 + finales de toma interpolados: la mas fluida
::
::  Van de menos a mas agresivo: mas fluidez, mas artefactos.
::
::  Tarda 7 veces lo que un render normal. Con un episodio entero son horas:
::  usa un fragmento.
:: ============================================================================
set "EXP_HOME=%~dp0"
if "%EXP_HOME:~-1%"=="\" set "EXP_HOME=%EXP_HOME:~0,-1%"
set "EXP_NOPAUSE=1"

for %%C in (X2_calidad_60 D2_fluidez_60 D4_ritmo_60 D3b_gap_max_60 D3_fluidez_max_60 D5_todo_max_60 D6_max_total_60) do (
    call "%EXP_HOME%\run-exp.bat" %%C %*
)

echo.
echo ==========================================================
echo   Listo. Abri los archivos de experimental\output\ y
echo   compara los sufijos -X2 -D2 -D4 -D3b -D3 -D5 -D6
echo ==========================================================
pause
exit /b 0
