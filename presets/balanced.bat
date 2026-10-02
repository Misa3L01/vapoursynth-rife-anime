@echo off
:: ====================== PRESET: balanced (recomendado) ======================
::  Medido en esta PC (RTX 4050 Laptop) sobre quintis.mp4 1080p23.976:
::    pipeline VapourSynth solo .......... 64.67 fps  (x1.349 tiempo real)
::  Elegido asi:
::    - 4.16_lite gano el barrido de 7 modelos: mejor SSIM medio en 3 fuentes,
::      VMAF y PSNR medios a 0.4 y 0.05 dB del mejor, y 30% mas rapido.
::    - impl=2 usa los onnx de models\rife_v2: +5% y padding interno.
::    - umbral 0.20 de scene detect: pico de VMAF en el barrido (62.23).
set "RIFE_MODEL=4161"
set "RIFE_IMPL=2"
set "RIFE_ENSEMBLE=0"

set "TRT_STREAMS=2"
set "TRT_CUDA_GRAPH=1"
set "TRT_OPT_LEVEL=3"
set "TRT_OUTPUT_FORMAT=1"

set "SCENE_DETECT=1"
set "SCENE_THRESHOLD=0.20"

set "TO_RGB_KERNEL=Bicubic"
set "DITHER=error_diffusion"
set "CAS_SHARPNESS=0.35"
set "CAS_LUMA_ONLY=1"
set "DEBAND=0"

set "NV_PRESET=p7"
set "NV_MULTIPASS=disabled"
set "CQ=20"
set "NV_LOOKAHEAD=32"
