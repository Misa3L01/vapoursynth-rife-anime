@echo off
:: D5_todo_max_60
:: TODO AL MAXIMO a 60 fps: D3 (deteccion agresiva y sin limite de pausa)
:: mas el suavizador de ritmo fuerte.
::
::   MAX_GAP=99              ningun dibujo se deja quieto, dure lo que dure
::   DUP_MEAN / DUP_MAX      deteccion de repetidos agresiva, como D3
::   SMOOTH=3                suavizado de ritmo con ventana de 7 dibujos
::
:: Es el extremo del "efecto telenovela". D3 solo midio peor que D2 en frames
:: congelados; aca se ve si el suavizado lo compensa. Mas artefactos que todas
:: las demas. Mira el resultado y juzga vos.
::
:: De mas a menos agresivo:
::   D5_todo_max_60 -> D3_fluidez_max_60 -> D4_ritmo_60 -> D2_fluidez_60 -> X2_calidad_60
::
:: Lo lee run-exp.bat (render) y tools/bench.py (medicion).
set "EXP_MODEL=426"
set "EXP_IMPL=0"
set "EXP_PRECISION=fp16"
set "EXP_MULTI=5/2"
set "EXP_RES_SCALE=1"
set "EXP_TTA=0"
set "EXP_TIMELINE=1"
set "EXP_DEDUP=1"
set "EXP_MAX_GAP=99"
set "EXP_SMOOTH=3"
set "EXP_SC_THRESHOLD=0.20"
set "EXP_DUP_MEAN=0.0100"
set "EXP_DUP_MAX=0.25"
set "EXP_STREAMS=2"
set "EXP_CAS=0.35"
set "EXP_SUFFIX=-D5"
