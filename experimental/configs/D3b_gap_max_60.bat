@echo off
:: D3b_gap_max_60
:: Variante intermedia entre D2 y D3: solo sube MAX_GAP al maximo y deja la
:: deteccion de repetidos como en D2.
::
::   MAX_GAP 5 -> 99   todo dibujo, dure lo que dure, reparte su movimiento
::                     sobre todo su tiempo en pantalla.
::   DUP_MEAN / DUP_MAX iguales a D2 (0.0060 / 0.15).
::
:: MEDIDO: 11.7 % de frames congelados contra 9.7 % de D2. Sirve para ver por
:: separado que hace cada palanca: si D3 se ve distinto que D3b, la diferencia
:: es la deteccion agresiva; si D3b se ve distinto que D2, es el MAX_GAP.
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
set "EXP_SC_THRESHOLD=0.20"
set "EXP_DUP_MEAN=0.0060"
set "EXP_DUP_MAX=0.15"
set "EXP_STREAMS=2"
set "EXP_CAS=0.35"
set "EXP_SUFFIX=-D3b"
