@echo off
:: X3_rapido_anime
:: Rapida: 4.16 lite + linea de tiempo. Casi la misma fluidez que X1, 35 % mas rapida.
:: Lo lee run-exp.bat (render) y tools/bench.py (medicion).
set "EXP_MODEL=4161"
set "EXP_IMPL=2"
set "EXP_PRECISION=fp16"
set "EXP_MULTI=2"
set "EXP_RES_SCALE=1"
set "EXP_TTA=0"
set "EXP_TIMELINE=1"
set "EXP_DEDUP=1"
set "EXP_MAX_GAP=3"
set "EXP_SC_THRESHOLD=0.20"
set "EXP_DUP_MEAN=0.0035"
set "EXP_DUP_MAX=0.10"
set "EXP_STREAMS=2"
set "EXP_CAS=0.35"
set "EXP_SUFFIX=-X3"
