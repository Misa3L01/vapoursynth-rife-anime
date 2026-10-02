@echo off
:: ====================== PRESET: speed =======================================
::  ATENCION: bajar el preset de NVENC o el dithering NO acelera nada en esta
::  GPU. Medido: speed y balanced con NVENC p4 vs p7 tardan lo mismo (77s), y
::  p1 vs p7 sobre un clip de 20s dan 18.9s vs 18.4s. El cuello es la
::  inferencia de RIFE, limitada por el techo de potencia de la placa.
::
::  El UNICO acelerador real medido es bajar el umbral de deteccion de cortes:
::  con 0.10 se marcan mas frames como corte, RIFE no los infiere (los copia)
::  y el pipeline sube de 64.7 a 74.9 fps, un 16%.
::  El precio esta medido: VMAF 60.46 contra 62.23 con umbral 0.20, porque
::  duplica frames que RIFE habria interpolado bien. Se nota como micro-judder.
::  Usalo si necesitas terminar rapido; para archivar, usa balanced.
set "RIFE_MODEL=4161"
set "RIFE_IMPL=2"
set "RIFE_ENSEMBLE=0"

set "TRT_STREAMS=2"
set "TRT_CUDA_GRAPH=1"
set "TRT_OPT_LEVEL=3"
set "TRT_OUTPUT_FORMAT=1"

set "SCENE_DETECT=1"
set "SCENE_THRESHOLD=0.10"

set "TO_RGB_KERNEL=Bicubic"
set "DITHER=error_diffusion"
set "CAS_SHARPNESS=0.35"
set "CAS_LUMA_ONLY=1"
set "DEBAND=0"

set "NV_PRESET=p7"
set "NV_MULTIPASS=disabled"
set "CQ=20"
set "NV_LOOKAHEAD=32"
