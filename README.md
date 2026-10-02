# VapourSynth-Env — Interpolación RIFE + TensorRT para anime

Convierte 24 fps → 48 fps con RIFE sobre TensorRT. Todo lo que dice este
documento está medido en esta PC (RTX 4050 Laptop, 6 GB), no estimado.

---

## Uso

Doble clic en **`Interpolar.lnk`** (o en `Interpolar.bat`, que es la versión
portable del mismo acceso). Se abre la app:

1. Elegí un preset. Carga los valores medidos; después podés ajustar cualquier
   control a mano y el preset pasa a decir "personalizado".
2. Tildá los videos de la lista. Salen de `videos\`; si agregás archivos con la
   app abierta, apretá **Refrescar**.
3. **Iniciar cola.** La barra de arriba muestra el video actual con su
   velocidad en vivo (fps y × tiempo real) y el tiempo restante; la de abajo,
   la cola completa.

El botón de arriba a la derecha cambia entre tema **claro y oscuro**. La
primera vez arranca con el tema de Windows; después recuerda tu elección
(queda en `cache\app-settings.json`, que `cleanup.ps1` no toca).

La app avisa si la GPU está ocupada antes de empezar, evita que la laptop se
suspenda mientras hay una cola corriendo, y **Cancelar** mata vspipe y ffmpeg
juntos y borra los temporales. Cada video terminado queda marcado en la lista
con su tiempo y su velocidad punta a punta.

La velocidad que muestra durante el render es la de los últimos 5 segundos,
así que baja cuando la placa toca su tope de potencia. La que queda en la
columna Estado al terminar incluye la carga del engine y el mux: es la que
sirve para calcular cuánto va a tardar una cola.

`run.bat` sigue existiendo como versión de consola, con los mismos presets.

Para mirar un video interpolado en vivo, sin renderizar nada, ver
[Ver en tiempo real](#ver-en-tiempo-real).

Miku sigue llamando a `Python\interpolar_miku.bat` con rutas completas como
siempre. Esa ruta es un reenvío al script real en `scripts\`, y el contrato no
cambió: salida junto al original como `<nombre>-2x.mkv`, exit 0 si salió todo,
exit 1 si algo falló.

## Ver en tiempo real

Mira un video interpolado en vivo en mpv, **sin generar ningún archivo**. Hay
tres formas de abrirlo:

- **En la app**, arriba a la derecha. **Ver en tiempo real** abre el video
  marcado en la lista (clic sobre su nombre); si no hay ninguno marcado, usa el
  primero tildado, y si tampoco hay, te deja elegir. **Abrir…** abre cualquier
  video del disco.
- **Arrastrando un video** sobre `Ver-en-vivo.bat`.
- **Desde la consola:** `scripts\ver-en-vivo.bat 60 "D:\anime\ep01.mkv"`.

El selector de al lado elige los fps. Lo que conviene depende del monitor:

| | Para monitores de | Cómo lo logra esta GPU |
|---|---|---|
| **48 fps (×2)** | 144 y 240 Hz | 1080p completo: 62 fps de salida sostenidos, con margen |
| **60 fps (×2.5)** | 60 y 120 Hz | interpola a 720p y mpv lo lleva a pantalla completa |

Cada frame del video tiene que durar un número entero de refrescos de la
pantalla. Si no, el reproductor repite algunos y aparece un tironeo periódico.
En 144 Hz, 48 fps da 3 refrescos justos por frame; 60 fps da 2.4. A 1080p la
RTX 4050 no llega a 60 fps (hace 38): a 720p hace 92, y mpv escala a pantalla
completa con sus escaladores de GPU. Los subtítulos no pierden definición,
porque mpv los dibuja a la resolución de la pantalla.

**En mpv:**

- **Ctrl+I** prende y apaga la interpolación, para comparar con el original.
- **Shift+I** deja a la vista el panel de estadísticas: fps y frames perdidos.
- **Flechas:** saltos rápidos, retoman en menos de 1 segundo. Caen en el
  fotograma clave anterior, así que a veces un poco antes del punto pedido.
- **Shift+flechas:** salto exacto. Más lento, porque RIFE tiene que procesar
  todo lo que hay desde el fotograma clave anterior.
- Al cerrar, recuerda por dónde ibas y la próxima vez sigue desde ahí.

**Medido reproduciendo 61 s en mpv:** a 48 fps, cero frames perdidos. A 60 fps,
en un episodio real, cero en un tramo y un tropiezo breve (11 frames) en otro.

Detalles:

- Usa **RIFE 4.16 lite** (`RT_MODEL` en `config.bat`); 4.26 no llega a tiempo
  real en esta GPU. Los ajustes están en `config.bat`, sección "ver en tiempo
  real".
- **La primera vez con una resolución nueva, la pantalla queda en negro unos
  2 minutos** mientras TensorRT compila el motor. Después arranca en segundos.
  Ya están compilados 1080p (48 fps) y 720p (60 fps, y videos 720p).
- Si la interpolación falla, mpv sigue mostrando el original. Para que no pase
  inadvertido aparece un cartel en pantalla, y si lo abriste desde la app,
  también un aviso con el error (log en `cache\work\en-vivo.log`).
- Se desactiva mientras corre una cola: los dos pelearían por la GPU.
- mpv está en `mpv\`, y `tools\install-mpv.bat` lo descarga o actualiza. Su
  configuración está aparte, en `scripts\mpv\`, y solo se usa al ver en tiempo
  real: un mpv que tengas instalado no se entera. Lo que mpv guarda (caché de
  shaders, por dónde ibas) va a `cache\mpv\`.

## Estructura

```
VapourSynth-Env\
├─ Interpolar.lnk            Abre la app
├─ Interpolar.bat            Lo mismo, portable (no depende de la ruta)
├─ Ver-en-vivo.bat           Arrastrar un video: lo muestra interpolado en vivo
├─ run.bat                   Cola en consola
├─ config.bat                TODOS los parámetros. Es lo único que se toca.
│
├─ scripts\
│  ├─ interpolar-app.ps1     La app (PowerShell + WPF, sin dependencias)
│  ├─ interpolate.vpy        El pipeline de VapourSynth
│  ├─ process-one.bat        Render + validación + mux de UN video
│  ├─ realtime.vpy           El pipeline en tiempo real (dentro de mpv)
│  ├─ ver-en-vivo.bat        Abre mpv con realtime.vpy (lo usan la app y Ver-en-vivo)
│  ├─ mpv\                   Configuración de mpv para ver en tiempo real
│  └─ interpolar_miku.bat    Cola automática (la usa Miku)
│
├─ presets\                  speed.bat · balanced.bat · quality.bat
├─ tools\                    bench.bat · cleanup.ps1 · install-plugins.bat · install-mpv.bat
│
├─ videos\                   Entrada
├─ output\                   Salida
├─ cache\{lwi,work,mpv}      Índices, temporales, y lo que guarda mpv
│
├─ Python\                   Runtime (VapourSynth + plugins + TensorRT)
│  └─ interpolar_miku.bat    Reenvío, para no romper la config de Miku
├─ ffmpeg\bin\
└─ mpv\                      Reproductor para ver en tiempo real
```

---

## Presets

Medido sobre `quintis.mp4` (1080p 23.976, 91.05 s), engines ya compilados,
tiempo de punta a punta incluyendo el mux:

| | speed | **balanced** | quality |
|---|---|---|---|
| Tiempo | **72 s (×1.265)** | **78 s (×1.167)** | 106 s (×0.859) |
| Salida | 133.4 MB | 135.9 MB | 153.0 MB |
| Modelo | 4.16_lite (v2) | 4.16_lite (v2) | 4.26 |
| Umbral de cortes | 0.10 | **0.20** | 0.20 |
| Chroma → RGB | Bicubic | Bicubic | Spline36 |
| CAS (luma) | 0.35 | 0.35 | 0.40 |
| Deband | no | no | sí |
| NVENC | p7, CQ 20 | p7, CQ 20 | p7, CQ 18 |

Contra la configuración anterior (4.25 sin detección de cortes), medida en las
mismas condiciones: **100 s, ×0.910, 143.0 MB**. O sea balanced es 28 % más
rápido, genera un archivo 5 % más chico y tiene mejor calidad medida.

Los tres presets usan **NVENC p7 sin multipass**. No es un descuido: en esta GPU
p1 y p7 tardan lo mismo (18.9 s contra 18.4 s sobre un clip de 20 s) y p7
produce el archivo más chico (26.7 contra 30.5 MB). Usar un preset de encoder
más rápido solo empeora la compresión sin ganar tiempo.

Lo único que diferencia a `speed` de `balanced` es el umbral de detección de
cortes. Bajarlo a 0.10 marca más frames como corte, RIFE no los infiere y el
pipeline gana un 8 % punta a punta — pero duplica frames que habría interpolado
bien, y eso cuesta VMAF (60.46 contra 62.23). Para archivar, usá `balanced`.

## Qué se midió y por qué quedó así

### Modelo: 4.16_lite

Se compararon 7 modelos con un protocolo objetivo: diezmar el clip a la mitad,
reconstruirlo con RIFE, y medir **solo los frames inventados** contra los
originales. Tres fuentes distintas (anime de diálogo, anime de acción, y un
baile de movimiento rápido).

| Modelo | VMAF medio | PSNR medio | SSIM medio | fps |
|---|---|---|---|---|
| **4.16_lite** | 58.14 | 23.03 | **0.9301** | **70.1** |
| 4.20 | **58.57** | 22.71 | 0.9263 | 52.1 |
| 4.25 | 57.97 | 23.05 | 0.9264 | 55.7 |
| 4.26 | 58.12 | **23.08** | 0.9277 | 53.8 |
| 4.26_heavy | ≈4.26 | ≈4.26 | ≈4.26 | 33.8 |

Las diferencias de calidad entre modelos modernos están dentro del ruido: el
rango completo es de 1.4 puntos de VMAF y 0.4 dB de PSNR, y el orden **cambia
según el clip**. Con la calidad empatada, decide la velocidad, y ahí 4.16_lite
gana por 30 %. Además tiene el mejor SSIM en las tres fuentes, incluida la de
movimiento rápido, que es donde se supone que un modelo *lite* debería romperse.

Descartados con datos:

- **4.26_heavy**: VMAF idéntico a 4.26 y 37 % más lento.
- **ensemble**: VMAF 62.229 contra 62.233 sin ensemble — o sea nada — y 37 % más lento.
- **4.25 vs 4.25_heavy**: son **el mismo archivo** (MD5 idéntico). Lo único que cambia es el múltiplo de padding que exige vsmlrt.

### Detección de cortes: umbral 0.20, y acelera

Sin detección de cortes RIFE funde los dos planos en cada corte y deja un frame
fantasma. Lo contraintuitivo es que **activarla no cuesta velocidad: la gana**.
En un corte, vsmlrt copia el frame anterior y nunca pide la inferencia, así que
esos frames salen gratis.

Medido alternando pasadas: 74.9 fps con detección contra 61.3 sin ella. Son 90
cortes en 500 frames (18 %), y 74.9 / 61.3 = 1.2205, que es exactamente
1 / (1 − 0.18).

El umbral se eligió por barrido:

| umbral | 0.05 | 0.10 | 0.15 | **0.20** | 0.30 | OFF |
|---|---|---|---|---|---|---|
| VMAF | 57.20 | 60.46 | 61.82 | **62.23** | 61.24 | 60.72 |

El valor que suele recomendarse, 0.10, resultó **peor que apagar la detección**:
sobre-detecta y duplica frames que RIFE habría interpolado bien. En esa tabla
PSNR y SSIM suben hacia OFF mientras VMAF baja — penalizan el frame duplicado
por distancia de píxel, cuando perceptualmente duplicar en un corte es lo
correcto. Acá hay que creerle a VMAF.

### Otros parámetros

| Cambio | Efecto medido |
|---|---|
| `_implementation=2` (modelos `rife_v2`) | **+5.2 %**, y hace su propio padding |
| `output_format=1` (fp16 a la salida) | **+3.8 %** |
| `use_cuda_graph=True` | +1.1 % |
| `num_streams` 2 → 4 | +0.3 % — **satura en 2** |
| `num_streams` 1 → 2 | +16 % |
| `builder_optimization_level=5` | +1.6 %, pero ~10 min de compilación |
| CAS, dither error_diffusion | dentro del ruido (<1 %) |

---

## El techo real de esta laptop

Durante un render sostenido:

```
temperatura  71-73 °C   (fresca, no es problema térmico)
potencia     65-68 W    (clavada en el tope)
clock SM     2610-2640 MHz de 3105 máx  (84 %)
throttle     0x4 = SwPowerCap
utilización  94-96 %
```

La GPU está **limitada por potencia, no por temperatura**. Eso significa dos
cosas prácticas:

1. Mejorar la refrigeración no va a servir de nada. Lo que sí puede servir es
   subir el TGP: revisá si tu laptop tiene un modo de rendimiento en su app del
   fabricante, y que Dynamic Boost esté activo en la NVIDIA App.
2. **Las mediciones cortas mienten.** Los primeros segundos corren en boost
   antes de tocar el tope de potencia, así que un benchmark de 20 s da números
   optimistas comparado con un episodio de 24 minutos. Los números de este
   documento son sobre clips de 91 s, ya en régimen.

---

## Problemas conocidos

**`trtexec execution fails` / engine de 0 bytes**
Faltó VRAM durante la compilación. Cerrá todo y reintentá. Importante: hay que
borrar el `.engine` de 0 bytes **y su `.engine.cache`** — ese cache guarda las
tácticas descartadas por falta de memoria y hace que el engine siguiente salga
lento aunque compile bien. `tools\cleanup.ps1 -Apply` los detecta solo.

**`Failed to allocate memory for plane. Out of memory.`**
Es RAM del sistema, no VRAM. Bajá `VS_CACHE_MB` en `config.bat`.

**El primer render con un preset nuevo tarda de más**
Está compilando el engine de TensorRT. 4.16_lite tarda ~3 s, 4.26 unos 150 s.
Después queda cacheado. Cambiar de resolución de entrada obliga a recompilar.

**Ver en tiempo real: la pantalla queda en negro al abrir**
Es TensorRT compilando el motor para una resolución que no había visto
(unos 2 minutos, solo la primera vez). La app lo avisa.

**Ver en tiempo real: salto exacto que muestra otro momento del video**
Con los saltos exactos, mpv descarta frames antes de RIFE para ir más rápido
y, como RIFE agrega frames, termina mostrando otro momento (medido: saltar
al segundo 3 mostraba el 4.2). `scripts\mpv\mpv.conf` lo evita con
`hr-seek-framedrop=no`; si se toca esa línea, vuelve.

**Fuentes AV1**
Se decodifican por CPU y pueden frenar el pipeline más que el propio RIFE.

---

## Llevarlo a otra PC

Se copia la carpeta entera; las rutas se resuelven desde `%~dp0`, así que
funciona en cualquier letra de unidad. `Interpolar.lnk` guarda la ruta
absoluta y hay que rehacerlo; `Interpolar.bat` funciona tal cual. **Excepción:** borrá los `.engine` de
`Python\plugins64\models\` — están compilados para esta GPU y este driver. Se
regeneran solos.

Hay que instalar aparte: driver NVIDIA ≥ 550, VapourSynth R70+, y los plugins
(`tools\install-plugins.bat`). No hace falta CUDA Toolkit ni TensorRT: ya están
dentro de `Python\plugins64\vsmlrt-cuda\`.

mpv viaja dentro de la carpeta. Si falta, `tools\install-mpv.bat` lo descarga
(no hace falta 7-Zip: usa el `tar` que trae Windows).

---

## Qué se sacó del entorno

De 7.7 GB a 2.6 GB. Se eliminaron: la copia duplicada de modelos en
`site-packages` (986 MB), 68 modelos ONNX que no se usan, las familias dpir /
cugan / waifu2x / RealESRGAN, los backends ONNX Runtime / OpenVINO / NCNN /
TensorRT-RTX, y cuDNN + cuBLAS + cuFFT — que TensorRT tiene explícitamente
deshabilitados, como se ve en su propia línea de compilación:

```
--tacticSources=-CUBLAS,-CUBLAS_LT,-CUDNN
```

Queda un recorte posible de ~1.6 GB más: los *builder resources* de otras
arquitecturas de GPU (esta es sm89). No se tocaron a propósito, porque sin
ellos el setup deja de poder compilar engines en una PC con otra placa.
`tools\cleanup.ps1` te lo recuerda al final de cada informe.
