@echo off
:: D2_fluidez_60
:: MAXIMA FLUIDEZ a 60 fps. Es el equivalente a lo que en SVFI se llama
:: "Dedup shots on twos/threes" (lo que vos viste etiquetado como D2), pero
:: con la deteccion de duplicados mas agresiva que la config X2.
::
:: Que cambia respecto de X2_calidad_60:
::   MAX_GAP 3 -> 5     un dibujo que se mantiene hasta 5 frames igual se
::                      interpola en vez de quedarse quieto. Mas movimiento
::                      continuo, mas riesgo de que invente algo raro.
::   DUP_MEAN mas alto  toma como repetidos dibujos que difieren un poco
::                      (granito de film, bandeo). Detecta mas, dedupea mas.
::   DUP_MAX mas alto   idem para el pixel que mas cambia.
::
:: Da el "efecto telenovela": todo se mueve parejo y continuo, como video de
:: camara en vez de dibujo. Trae mas artefactos que X2. Es a proposito.
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
set "EXP_MAX_GAP=5"
set "EXP_SC_THRESHOLD=0.20"
set "EXP_DUP_MEAN=0.0060"
set "EXP_DUP_MAX=0.15"
set "EXP_STREAMS=2"
set "EXP_CAS=0.35"
set "EXP_SUFFIX=-D2"
