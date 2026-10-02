# torch-env — entorno PyTorch aislado

Sirve para probar los modelos de interpolación que **no pueden correr en el
VapourSynth de producción**: GMFSS, AMT, EMA-VFI y GIMM-VFI son código PyTorch,
y el Python del VapourSynth (3.13, embebido) no sirve para eso.

No toca nada de producción. Tiene su propio Python 3.12 y su propio PyTorch, y
todo —incluidos los cachés de descarga— queda dentro de esta carpeta.

---

## Instalación

```bat
experimental\torch-env\setup.bat
```

Es idempotente: se puede volver a correr y solo hace lo que falta. Baja unos
3 GB y ocupa 7.8 GB instalado. Al terminar se puede borrar `.uv-cache\`.

Qué instala y por qué:

| Componente | Versión | Para qué |
|---|---|---|
| uv | 0.12.17 | Un solo ejecutable que instala Python y paquetes, sin tocar el sistema |
| Python | 3.12 | PyTorch no tiene versión para el 3.13 embebido de VapourSynth |
| PyTorch | 2.11.0 + CUDA 12.8 | El motor de los modelos |
| CuPy | 14.2 (CUDA 12) | El kernel CUDA de *softsplat* que usa GMFSS |
| timm | 1.0.29 | Lo pide EMA-VFI |
| gdown | 6.4 | Los pesos de GMFSS y EMA-VFI están en Google Drive |

**CUDA 12.8 y no 13:** hay PyTorch con CUDA 13, pero CuPy para CUDA 13 metería
dos runtimes distintos en el mismo proceso. Los dos en CUDA 12 evita el riesgo.

---

## Cómo está conectado con VapourSynth

Los modelos no reemplazan al pipeline: se enchufan en el medio.

```
vspipe (VapourSynth de producción)  ->  runner.py (PyTorch/CUDA)  ->  ffmpeg
frames RGB fp16, la misma                ejecuta el modelo según      a YUV con zimg,
conversión de color que usa RIFE         el plan                      la misma librería
```

El **plan** (`tools\make_plan.py`) es una lista de decisiones, una por frame de
salida: copiar un frame, o interpolar entre dos con cierta proporción. Lo calcula
el mismo código que usa RIFE, así que todos los modelos reciben las mismas
decisiones de corte de escena y la misma línea de tiempo anime-aware. Sin eso,
comparar modelos mezclaría diferencias de modelo con diferencias de lógica.

**Validación del puente:** el modelo `hold` repite el frame anterior. En la
prueba "en dos" con plan normal, RIFE también produce copias, así que los dos
tienen que dar el mismo número. Dan **21.37 y 21.36**: el puente no altera nada,
y por eso los resultados de PyTorch se pueden comparar directamente con los de
TensorRT.

---

## Uso

```bat
:: renderizar un video completo (con audio, subtítulos y capítulos)
experimental\run-torch.bat gmfss_u "D:\anime\ep01.mkv"

:: el mismo modelo con un método de fluidez: toma los fps de salida y la línea
:: de tiempo de una config de experimental\configs (D2, D4, D6...)
experimental\run-torch.bat gmfss_u D6_max_total_60 "D:\anime\clip.mkv"

:: medir calidad y velocidad
Python\python.exe experimental\tools\bench_torch.py videos\salida.mp4 gmfss_u amt_g
Python\python.exe experimental\tools\bench_torch.py videos\salida.mp4 gmfss_u --scale 1.0 --tests twos
```

Modelos disponibles: `gmfss_u`, `amt_g`, `amt_l`, `ema_small`, `ema`, `gimm`,
`gimm_lpips`, y los controles `hold` (copia) y `blend` (promedio).

El parámetro `--scale` es la resolución a la que se calcula el flujo óptico.
Cada modelo tiene su valor por defecto medido en esta GPU: GMFSS entra a escala
completa y ahí rinde bastante mejor; AMT y EMA-VFI se quedan sin memoria y van a
media escala.

---

## Solo GPU

`runner.py` aborta si no hay CUDA: no hay camino por CPU ni fallback. Los
modelos corren en la GPU con precisión mixta (autocast fp16).

---

## Cosas que costaron y conviene no repetir

- **vspipe escribe los planos RGB en orden G, B, R**, aunque VapourSynth los
  tenga como R, G, B en memoria. Sin reordenarlos salen los rojos y azules
  cambiados, y el VMAF da cualquier cosa.
- **`.half()` rompe estos modelos**: adentro generan tensores en fp32 (grillas de
  coordenadas para `grid_sample`) que chocan con los pesos en fp16. La forma que
  funciona es `torch.autocast`.
- **Sin `torch.set_grad_enabled(False)`**, PyTorch guarda el grafo para
  retropropagación y GMFSS no entra en 6 GB ni a 896x512. Con gradientes
  desactivados entra a 1080p con 2.9 GB.
- **ffmpeg alinea dos videos por marca de tiempo, no por número de frame.** En la
  prueba de reconstrucción el clip diezmado corre a la mitad de fps, así que
  comparaba cada frame contra otro que no le correspondía y daba resultados
  imposibles (una copia "ganándole" a GMFSS). Los archivos de medición se
  escriben todos a 24 fps fijos.

- **GIMM-VFI necesitó tres arreglos** para correr acá, todos por la edad del
  repo. Sus dataclasses de configuración usan defaults mutables, que Python
  3.11 dejó de aceptar. Su kernel de *softsplat* llama a
  `cupy.cuda.compile_with_cache`, que se eliminó en CuPy 13; el reemplazo es
  `cupy.RawModule`. Y su paquete interno se llama `models`, igual que
  `vfi\models.py`: el adaptador saca el nuestro de `sys.modules` mientras
  importa el suyo y lo devuelve después.
- **La escala del flujo de GIMM-VFI no es libre.** A 1080p, escala completa y
  0.75 se quedan sin memoria en 6 GB, y 0.65 falla porque RAFT necesita que la
  escala divida limpio las dimensiones. Media escala es el techo.

---

## Desinstalar

Borrar la carpeta `torch-env\` completa (7.8 GB). No deja nada afuera: ni
variables de entorno, ni paquetes en el Python de producción, ni archivos en C:.
