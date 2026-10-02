# vapoursynth-rife-anime

Interpolación de anime 24→48/60 fps con RIFE + TensorRT sobre VapourSynth (RTX 4050 6 GB, Windows).

## Punto de entrada
- `Interpolar.bat` → `scripts/interpolar-app.ps1` (app WPF con cola). `run.bat` es la cola en consola.
- `Ver-en-vivo.bat` → `scripts/ver-en-vivo.bat`: reproduce en mpv interpolado en tiempo real.

## Módulos clave
- `config.bat`: ÚNICO lugar de parámetros (los presets de `presets/` lo pisan).
- `scripts/interpolate.vpy`: pipeline de render (cortes, RGBH, RIFE, CAS).
- `scripts/process-one.bat`: render + validación + mux de UN video (lo usan app, run.bat y Miku).
- `scripts/realtime.vpy`: pipeline dentro de mpv; config de mpv en `scripts/mpv/`.
- `tools/`: bench, cleanup, instaladores de plugins y mpv.
- `experimental/`: exploración (línea de tiempo anime, configs D*/X*, modelos PyTorch). `vpy/exp_core.py` es el núcleo.

## Probar
- No hay tests automáticos. Smoke test: `run.bat` con un clip corto en `videos/`, o
  `Python\Scripts\vspipe.exe -a SRC=<ruta absoluta> scripts\realtime.vpy --` para velocidad.
- Sin GPU/servicios no hay modo demo.

## Contratos que no se pueden romper
- `Python/interpolar_miku.bat` y `scripts/interpolar_miku.bat`: los invoca Miku con rutas completas;
  salida `<nombre>-2x.mkv` junto al original, exit 0 si todo salió, 1 si algo falló.
- Los `.bat` van en CRLF (con LF cmd pierde las etiquetas). `interpolar-app.ps1` va en UTF-8 con BOM.
- No sobrescribir TEMP/TMP en los .bat. En vspipe, pasar rutas absolutas (cambia de cwd).
- Solo GPU en `experimental/`: sin fallback a CPU.
- En heredocs del shell las `\` se pierden: escribir .bat/.md con rutas usando herramientas de archivo.

## Qué no leer
Python/, ffmpeg/, mpv/, videos/, output/, cache/, experimental/torch-env/{venv,python,repos,weights},
experimental/output y sim, *.engine, *.onnx, videos. Los README son largos: usar grep por sección.
