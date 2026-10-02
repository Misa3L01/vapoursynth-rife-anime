@echo off
:: X2_calidad_60
:: RECOMENDADA 60 fps: 4.26 + linea de tiempo anime-aware, x2.5 (59.94 fps).
:: Lo lee run-exp.bat (render) y tools/bench.py (medicion).
set "EXP_MODEL=426"
set "EXP_IMPL=0"
set "EXP_PRECISION=fp16"
set "EXP_MULTI=5/2"
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
set "EXP_SUFFIX=-X2"
