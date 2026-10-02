@echo off
:: E4_4161_1440p
:: Resolucion interna: 4.16 lite a 2560x1440.
:: Lo lee run-exp.bat (render) y tools/bench.py (medicion).
set "EXP_MODEL=4161"
set "EXP_IMPL=2"
set "EXP_PRECISION=fp16"
set "EXP_MULTI=2"
set "EXP_RES_SCALE=1.3333"
set "EXP_TTA=0"
set "EXP_TIMELINE=0"
set "EXP_DEDUP=0"
set "EXP_MAX_GAP=3"
set "EXP_SC_THRESHOLD=0.20"
set "EXP_STREAMS=2"
set "EXP_CAS=0.35"
set "EXP_SUFFIX=-E4"
