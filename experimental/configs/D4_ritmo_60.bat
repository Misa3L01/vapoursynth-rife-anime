@echo off
:: D4_ritmo_60
:: D2 + SUAVIZADOR DE RITMO a 60 fps. Es lo mas parecido al "D2" de SVFI:
:: su dedup "en dos" viene acompanado de TruMotion, que empareja la velocidad.
::
:: El problema que ataca: si los dibujos duran 2, 3, 2, 3 frames, la
:: velocidad salta de 1/2 a 1/3 en cada dibujo. Nada queda congelado, pero el
:: movimiento acelera y frena a cada rato y se siente menos fluido.
::
::   SMOOTH=2   corre levemente el instante de cada dibujo (a lo sumo un
::              tercio de frame, unos 14 ms) para que queden equiespaciados.
::              En la prueba sintetica la irregularidad de la velocidad baja de
::              19 % a 4 %.
::
:: Todo lo demas igual que D2_fluidez_60.
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
set "EXP_SMOOTH=2"
set "EXP_SC_THRESHOLD=0.20"
set "EXP_DUP_MEAN=0.0060"
set "EXP_DUP_MAX=0.15"
set "EXP_STREAMS=2"
set "EXP_CAS=0.35"
set "EXP_SUFFIX=-D4"
