@echo off
:: D6_max_total_60
:: LA MAS FLUIDA a 60 fps: D5 (todo al maximo) + finales de toma interpolados.
::
::   MAX_GAP=99              ningun dibujo se deja quieto, dure lo que dure
::   DUP_MEAN / DUP_MAX      deteccion de repetidos agresiva, como D3 y D5
::   SMOOTH=3                suavizado de ritmo con ventana de 7 dibujos
::   TAIL=1                  el final de cada toma se interpola frame a frame
::
:: TAIL arregla el problema que tenian D3 y D5: con la deteccion agresiva, un
:: movimiento tenue al final de una toma (antes de un corte de escena) se
:: tomaba por repetido y el tramo entero quedaba congelado. En el clip de
:: prueba habia medio segundo quieto antes del ultimo corte. Con TAIL, los
:: frames que se repiten en el plan de D3 bajan de 44 a 12; esos 12 son el
:: piso, el ultimo frame de cada toma, que no se puede interpolar contra la
:: escena siguiente.
::
:: Maximo "efecto telenovela", y tambien la que mas artefactos puede traer.
::
:: De mas a menos agresivo:
::   D6 -> D5 -> D3 -> D3b -> D4 -> D2 -> X2
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
set "EXP_TAIL=1"
set "EXP_SC_THRESHOLD=0.20"
set "EXP_DUP_MEAN=0.0100"
set "EXP_DUP_MAX=0.25"
set "EXP_STREAMS=2"
set "EXP_CAS=0.35"
set "EXP_SUFFIX=-D6"
