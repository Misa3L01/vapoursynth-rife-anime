@echo off
:: E3_426_1440p
:: Resolucion interna: 4.26 calcula el flujo a 2560x1440 y vuelve a 1080p.
:: Lo lee run-exp.bat (render) y tools/bench.py (medicion).
set "EXP_MODEL=426"
set "EXP_IMPL=0"
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
set "EXP_SUFFIX=-E3"
