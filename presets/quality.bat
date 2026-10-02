@echo off
:: ====================== PRESET: quality =====================================
::  4.26 en vez de 4.16_lite. Honestamente: la diferencia medida es minima
::  (VMAF 62.56 vs 62.23, PSNR 18.90 vs 18.84, y SSIM levemente PEOR) a cambio
::  de ser 38% mas lento -> 46.88 fps (x0.978 tiempo real).
::  Lo que si aporta de verdad en este preset es el encoder y el post.
::  4.26 no tiene onnx en rife_v2, asi que va con la implementacion v1.
::
::  Descartados con datos:
::    ensemble      -> VMAF identico (62.229 vs 62.233) y 37% mas lento
::    4.26_heavy    -> VMAF identico a 4.26 y 37% mas lento
::    opt_level=5   -> +1.6% de velocidad por ~10 min de compilacion
set "RIFE_MODEL=426"
set "RIFE_IMPL=0"
set "RIFE_ENSEMBLE=0"

set "TRT_STREAMS=2"
set "TRT_CUDA_GRAPH=1"
set "TRT_OPT_LEVEL=3"
set "TRT_OUTPUT_FORMAT=1"

set "SCENE_DETECT=1"
set "SCENE_THRESHOLD=0.20"

set "TO_RGB_KERNEL=Spline36"
set "DITHER=error_diffusion"
set "CAS_SHARPNESS=0.40"
set "CAS_LUMA_ONLY=1"
set "DEBAND=1"
set "DEBAND_THRESHOLD=3.0"
set "DEBAND_RADIUS=16.0"
set "DEBAND_GRAIN=0.0"

set "NV_PRESET=p7"
set "NV_MULTIPASS=disabled"
set "CQ=18"
set "NV_LOOKAHEAD=32"
set "NV_AQ_STRENGTH=10"
