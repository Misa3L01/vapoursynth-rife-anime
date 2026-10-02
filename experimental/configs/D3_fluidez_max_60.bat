@echo off
:: D3_fluidez_max_60
:: FLUIDEZ AL MAXIMO a 60 fps. Todas las palancas al extremo.
::
:: Que cambia respecto de D2_fluidez_60:
::   MAX_GAP 5 -> 99             no se rinde nunca: todo dibujo, dure lo que
::                               dure, reparte su movimiento sobre todo su
::                               tiempo en pantalla.
::   DUP_MEAN 0.0060 -> 0.0100   detecta como repetido casi cualquier dibujo
::   DUP_MAX  0.15   -> 0.25     que apenas cambie (grano, bandeo, sombras).
::
:: MEDIDO: da 12.2 % de frames congelados contra 9.7 % de D2, o sea que por
:: esa metrica sale peor. La razon es que la deteccion agresiva confunde
:: dibujos distintos con repetidos, y que repartir un dibujo largo sobre
:: muchisimos frames hace que los consecutivos salgan casi identicos.
::
:: Pero la metrica no es el ojo: mira el resultado y juzga vos. El efecto
:: "telenovela" es mas marcado aca, con mas artefactos.
::
:: De mas a menos agresivo:
::   D3_fluidez_max_60  ->  D2_fluidez_60  ->  X2_calidad_60
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
set "EXP_DUP_MEAN=0.0100"
set "EXP_DUP_MAX=0.25"
set "EXP_STREAMS=2"
set "EXP_CAS=0.35"
set "EXP_SUFFIX=-D3"
