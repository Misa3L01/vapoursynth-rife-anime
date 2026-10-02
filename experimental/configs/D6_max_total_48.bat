@echo off
:: D6_max_total_48
:: D6 (la mas fluida) a 47.952 fps, para monitores de 144 Hz.
::
:: En 144 Hz cada frame de 48 fps dura exactamente 3 refrescos. A 60 fps no
:: divide (2.4 refrescos por frame): el reproductor alterna frames de 2 y 3
:: refrescos y aparece un tironeo periodico, justo lo contrario de lo que
:: busca esta config.
::
:: Todo lo demas es identico a D6_max_total_60:
::   MAX_GAP=99, deteccion de repetidos muy agresiva, SMOOTH=3, TAIL=1.
::
:: Tambien renderiza mas rapido: interpola menos frames que a 60.
::
:: Lo lee run-exp.bat (render) y tools/bench.py (medicion).
set "EXP_MODEL=426"
set "EXP_IMPL=0"
set "EXP_PRECISION=fp16"
set "EXP_MULTI=2"
set "EXP_RES_SCALE=1"
set "EXP_TTA=0"
set "EXP_TIMELINE=1"
set "EXP_DEDUP=1"
set "EXP_MAX_GAP=99"
set "EXP_SMOOTH=3"
set "EXP_TAIL=1"
set "EXP_SC_THRESHOLD=0.20"
set "EXP_DUP_MEAN=0.0100"
set "EXP_DUP_MAX=0.25"
set "EXP_STREAMS=2"
set "EXP_CAS=0.35"
set "EXP_SUFFIX=-D6-48"
