# Experimental — interpolación de máxima calidad

Exploración del techo de calidad para 48 y 60 fps en esta PC (RTX 4050 Laptop,
6 GB, limitada a ~65 W). Todo está aislado en esta carpeta: los scripts de
producción no se tocaron.

---

## Resumen

**Una sola palanca mejora de verdad: la línea de tiempo anime-aware.** En
animación "en dos" (cada dibujo se mantiene 2 frames, muy común en anime de TV),
la interpolación normal deja **54 % de los frames de salida congelados**: el
video es de 48 fps pero avanza a saltos. La línea de tiempo lo baja a **12 %**,
sube el VMAF de esos frames **+4 a +4.6** y **no cuesta velocidad**.

Todas las formas de gastar más GPU en el modelo dan prácticamente cero:

| Palanca | Δ VMAF | Costo |
|---|---|---|
| Precisión fp32 (en vez de fp16) | +0.10 | 40 % más lento |
| Flujo a 1440p y vuelta a 1080p | −0.07 a +0.05 | 44 % más lento |
| TTA (promediar con el cuadro espejado) | −0.23 | 49 % más lento |
| Modelo 4.26 en vez de 4.16 lite | +0.62 VMAF, −0.03 dB PSNR | 27 % más lento |

RIFE ya rinde al máximo en fp16 y a resolución nativa.

**Los modelos "más potentes" tampoco cambian el panorama.** Se montó un entorno
PyTorch aislado ([`torch-env\`](torch-env/README.md)) para poder probar los que
antes no corrían. Resultado: GMFSS —el especialista en anime— es el mejor
medido, pero le saca **+1.0 VMAF a RIFE 4.26 tardando 34 veces más** (12 horas
por episodio contra 25 minutos). AMT, EMA-VFI y GIMM-VFI quedaron por debajo
de RIFE. Ver [Modelos PyTorch](#modelos-pytorch-gmfss-amt-ema-vfi).

**Para máxima fluidez hay otra familia de configs, D2 a D6**, que empujan la
línea de tiempo al extremo: el "efecto telenovela", con más artefactos. D6
es la más fluida medida. Con monitor de 144 Hz, usar las versiones a 48 fps:
`FLUIDEZ-48-MAX.bat` y `COMPARAR-FLUIDEZ-48.bat`. Ver
[Máxima fluidez](#máxima-fluidez-d2-a-d6).

**La interpolación clásica por vectores de movimiento tampoco.** MVTools —la
familia de SVP y del suavizado de movimiento de los televisores— se estanca
en **23.84 contra los 26.09 de RIFE 4.26**, y sin ganar velocidad. Nueve
variantes entran en una franja de 0.8 VMAF: el techo es del método, no del
ajuste. Ver [Interpolación clásica](#interpolación-clásica-mvtools-svp-y-el-trumotion-de-los-televisores).

---

## Cómo usarlo

### Renderizar con una configuración

```bat
experimental\run-exp.bat X1_calidad_48
experimental\run-exp.bat X2_calidad_60 "D:\anime\ep01.mkv" "D:\anime\ep02.mkv"
```

Sin videos, procesa todos los de `videos\`. La salida va a `experimental\output\`
con el sufijo de la config (`ep01-X1.mkv`). Usa el mismo `process-one.bat` de
producción, sin modificarlo: misma validación de duración, mismo mux de audio,
subtítulos y fuentes, mismo NVENC. Solo cambia el script de VapourSynth.

La primera vez con una configuración nueva compila el engine de TensorRT:
~3 s para 4.16 lite y ~150 s para 4.26. Después queda cacheado.

### Medir

```bat
Python\python.exe experimental\tools\bench.py videos\salida.mp4                 :: todas las configs
Python\python.exe experimental\tools\bench.py videos\salida.mp4 X1_calidad_48   :: una sola
Python\python.exe experimental\tools\smoothness.py videos\salida.mp4 --twos B1_base_426 X1_calidad_48
Python\python.exe experimental\tools\analyze_dupes.py "D:\anime\ep01.mkv"       :: cuánto de un episodio está "en dos"
```

`bench.py` agrega una fila por corrida a `results\bench.csv`. Antes de medir,
**cerrá juegos y apps que usen la GPU**.

---

## Configuraciones

### Recomendadas

| Config | Qué es | Velocidad sostenida | 10 s de video | Episodio de 24 min | VRAM |
|---|---|---|---|---|---|
| **X1_calidad_48** | 4.26 + línea de tiempo, 48 fps | ×0.98 | ~10 s | ~25 min | 1.4 GB |
| **X2_calidad_60** | 4.26 + línea de tiempo, 59.94 fps | ×0.50 | ~20 s | ~49 min | 1.4 GB |
| **X3_rapido_anime** | 4.16 lite + línea de tiempo, 48 fps | ×1.33 | ~8 s | ~18 min | 1.1 GB |
| X4_extremo_48 | 4.26 fp32 + línea de tiempo, 48 fps | ×0.59 | ~17 s | ~41 min | 2.0 GB |

Velocidad sostenida: el clip en bucle 10 veces (61 s de video), ya con la
placa en su tope de potencia, **sin encoder**. El render completo con NVENC y mux
suma aproximadamente 10–15 % (en producción, 64.7 fps del pipeline solo dieron
×1.17 de punta a punta). VRAM: lo que agrega el pipeline sobre el escritorio
(~950 MB). Todas quedan muy lejos de los 6 GB.

X1 y X3 son exactamente E8 y E7 de la tabla siguiente, con nombre de uso.

- **X1** — la recomendada. Mejor calidad medida a un precio razonable.
  - A favor: el modelo de mejor VMAF en esta prueba (26.09 contra 25.47 de 4.16
    lite; el PSNR queda igual); la línea de tiempo elimina el tironeo del anime
    "en dos"; tiempo real aproximado.
  - En contra: 27 % más lenta que X3 por una diferencia de calidad pequeña.
- **X2** — lo mismo a 60 fps. Solo 2 de cada 5 frames son originales, así que
  cada frame es algo peor que en ×2. Conviene si mirás en un monitor de 60 Hz
  fijo, donde 48 fps no divide parejo y aparece judder.
- **X3** — casi la misma fluidez que X1, un tercio más rápida.
- **X4** — el techo absoluto medible. +0.11 VMAF sobre X1 por un 40 % más de
  tiempo: está para quien quiera exprimir la última décima. No se nota a simple vista.

### Todas las medidas

`recon`: se tira un frame de cada dos y RIFE los reconstruye (calidad pura de
interpolación). `en dos`: animación en dos simulada; se evalúan los frames que
caen donde estaban los originales borrados.

| Config | Modelo | Precisión | Extra | recon VMAF | recon PSNR | "en dos" VMAF | fps | ×t.real | VRAM |
|---|---|---|---|---|---|---|---|---|---|
| B0_base_4161 | 4.16 lite v2 | fp16 | — (= producción balanced) | 25.47 | 18.07 | 21.36 | 62.9 | 1.31 | 1208 |
| B1_base_426 | 4.26 | fp16 | — (= producción quality) | 26.09 | 18.04 | 21.36 | 46.1 | 0.96 | 1414 |
| E1_426_fp32 | 4.26 | fp32 | | **26.18** | 18.04 | 21.37 | 27.8 | 0.58 | 2040 |
| E2_4161_fp32 | 4.16 lite v2 | fp32 | | 25.57 | 18.07 | 21.37 | 35.1 | 0.73 | 1725 |
| E3_426_1440p | 4.26 | fp16 | flujo a 2560×1440 | 26.02 | 18.10 | 21.30 | 25.6 | 0.53 | 2514 |
| E4_4161_1440p | 4.16 lite v2 | fp16 | flujo a 2560×1440 | 25.51 | 18.11 | 21.30 | 35.5 | 0.74 | 1957 |
| E5_426_tta | 4.26 | fp16 | TTA espejado | 25.86 | 18.09 | 21.36 | 23.5 | 0.49 | 2713 |
| E6_4161_tta | 4.16 lite v2 | fp16 | TTA espejado | 25.25 | **18.12** | 21.36 | 32.2 | 0.67 | 2248 |
| E7_4161_timeline | 4.16 lite v2 | fp16 | línea de tiempo | 25.27 | 18.07 | 25.31 | **63.9** | **1.33** | 1143 |
| E8_426_timeline | 4.26 | fp16 | línea de tiempo | 25.92 | 18.04 | 25.95 | 47.0 | 0.98 | 1376 |
| F1_4161_60 | 4.16 lite v2 | fp16 | 60 fps | = B0 | | 21.36 | 40.4 | 0.68 | 1148 |
| F2_4161_60_timeline | 4.16 lite v2 | fp16 | 60 fps + línea | = E7 | | 25.31 | 40.2 | 0.67 | 1229 |
| X2_calidad_60 | 4.26 | fp16 | 60 fps + línea | = E8 | | 25.95 | 29.7 | 0.50 | 1380 |
| X4_extremo_48 | 4.26 | fp32 | línea de tiempo | | | **26.06** | 28.4 | 0.59 | 1999 |

Los VMAF absolutos son bajos (~25) porque el clip de prueba es difícil a
propósito: movimiento fuerte y 6 cortes en 6 s, reconstruido desde 12 fps. Lo
que vale es la comparación entre filas, todas medidas igual. Las pruebas `recon`
y `en dos` corren siempre a ×2, así que las configs de 60 fps comparten calidad
por frame con su equivalente de 48.

Fluidez sobre la salida completa (`results\fluidez.txt`):

| | Clip real (casi todo "en unos") | Simulado "en dos" |
|---|---|---|
| | congelados / tirones | congelados / tirones |
| Normal 48 fps | 7.3 % / 0.443 | **54.4 %** / 1.037 |
| Línea de tiempo 48 fps | 8.0 % / 0.442 | **11.8 %** / 0.123 |
| Normal 60 fps | 10.0 % / 0.387 | 46.7 % / 0.809 |
| Línea de tiempo 60 fps | 10.0 % / 0.387 | 12.8 % / 0.123 |

---

## Ranking de calidad (dentro de tiempos razonables)

"Razonable" = al menos ×0.25 tiempo real (10 s de video en 40 s como máximo; un
episodio en menos de 1 h 40 min). Todas las configs medidas pasan ese corte: la
más lenta va a ×0.49.

1. **X4_extremo_48** — la calidad más alta medida, por una décima. ×0.59.
2. **X1_calidad_48** — prácticamente igual a X4 y 40 % más rápida. ×0.98. **La que recomiendo.**
3. **X2_calidad_60** — la mejor a 60 fps. ×0.50.
4. **X3_rapido_anime** — la mejor relación calidad/tiempo. ×1.33.

Descartadas por no mejorar lo que cuestan: E1–E6 (fp32 sin línea de tiempo,
1440p, TTA).

---

## Qué es la línea de tiempo anime-aware

La interpolación normal trata cada par de frames consecutivos por separado.
Con animación "en dos" (A A B B C C), entre dos frames iguales no hay nada que
interpolar, y todo el movimiento de A a B cae en un solo intervalo. La salida de
48 fps queda A A A ½ B B B ½ C…: tres frames quietos y un salto.

La línea de tiempo:

1. Recorre el video una vez y marca qué frames repiten el dibujo anterior. El
   análisis se cachea en `experimental\cache\`.
2. Para cada frame de salida calcula su tiempo real y busca entre qué dos
   *dibujos* cae, no entre qué dos frames.
3. Interpola con `vsmlrt.RIFEMerge` usando la proporción real: A, ¼, ½, ¾, B…
   El movimiento queda repartido parejo.

Reglas de seguridad, las tres medidas:

- **Nunca interpola a través de un corte de escena.**
- **Pausas de más de 3 frames se interpolan frame a frame**, como el método
  normal. Puede ser un plano quieto de verdad, o un movimiento tan tenue que
  pasa por repetido. En el clip de prueba hay una gota clara cayendo sobre un
  fondo claro que numéricamente parece frames repetidos; una primera versión la
  congelaba 5 frames.
- En contenido animado "en unos" es neutra: sobre el render real de `salida.mp4`
  cambia **3 de 294** frames (`tools\plan_diff.py`).

### La limitación

En movimientos muy rápidos (un latigazo de cabeza), repartir el movimiento sobre
2 frames le pide a RIFE un salto más grande del que resuelve bien, y en lugar de
una copia congelada nítida aparece un **fantasma**. Mirá
`results\comparacion_en_dos_75.png` (latigazo, pierde) y
`results\comparacion_en_dos_121.png` (movimiento moderado, gana claramente).

Probé un guardia que desactiva la línea de tiempo cuando el salto entre dibujos
es grande (`tools\calibrate_motion.py`, resultado en
`results\calibracion_movimiento.txt`). No sirve: las pérdidas no se separan por
magnitud de movimiento. En el mismo rango hay frames que pierden 24 puntos y
otros que ganan 53, y cualquier umbral baja el promedio (sin guardia 25.07; con
umbral 0.10, 23.55). Por eso no está activado. En promedio gana en 45 de 67
frames.

El compromiso es este: la interpolación normal muestra saltos y frames
congelados todo el tiempo; la línea de tiempo muestra movimiento parejo y, de vez
en cuando, un fantasma de 21 ms en un movimiento brusco.

---

## Máxima fluidez: D2 a D6

Las configs `D*` apuntan a otra cosa que las `X*`: no a la mejor calidad por
frame, sino a la **máxima sensación de fluidez**, el "efecto telenovela", aunque
traiga más artefactos. Todas salen a 59.94 fps con RIFE 4.26.

El punto de partida es **D2**, que equivale a lo que SVFI llama *Dedup shots
on twos/threes*: la línea de tiempo anime-aware con la detección de repetidos
más agresiva que X2. Sobre eso hay cuatro palancas:

| Palanca | Qué hace |
|---|---|
| `MAX_GAP` | Hasta cuántos frames puede durar un dibujo y seguir repartiendo su movimiento. Con 99, ningún dibujo se deja quieto. |
| `DUP_MEAN` / `DUP_MAX` | Qué tan distinto tiene que ser un frame para no contar como repetido. Más alto = detección más agresiva. |
| `SMOOTH` | **Suavizador de ritmo**, lo que SVFI llama TruMotion. Si los dibujos duran 2, 3, 2, 3 frames, la velocidad salta en cada dibujo; esto corre cada dibujo una fracción de frame para que queden equiespaciados. |
| `TAIL` | Interpola frame a frame el final de cada toma, antes de un corte. Sin esto, un movimiento tenue al final de una toma que se toma por "repetido" queda congelado entero. |

| Config | MAX_GAP | Detección | SMOOTH | TAIL |
|---|---|---|---|---|
| X2_calidad_60 | 3 | normal | — | — |
| D2_fluidez_60 | 5 | agresiva | — | — |
| D4_ritmo_60 | 5 | agresiva | 2 | — |
| D3b_gap_max_60 | 99 | agresiva | — | — |
| D3_fluidez_max_60 | 99 | muy agresiva | — | — |
| D5_todo_max_60 | 99 | muy agresiva | 3 | — |
| **D6_max_total_60** | 99 | muy agresiva | 3 | sí |

### Cómo verlas

```bat
experimental\FLUIDEZ-60.bat          :: D2, doble clic o arrastrar videos
experimental\FLUIDEZ-60-MAX.bat      :: D6, la más fluida
experimental\COMPARAR-FLUIDEZ.bat    :: arrastrar UN video: lo renderiza con las 7

:: lo mismo a 48 fps, para monitores de 144 Hz (ver abajo)
experimental\FLUIDEZ-48-MAX.bat
experimental\COMPARAR-FLUIDEZ-48.bat
```

`COMPARAR-FLUIDEZ.bat` deja un archivo por nivel en `output\` (`-X2`, `-D2`,
`-D4`, `-D3b`, `-D3`, `-D5`, `-D6`). Tarda 7 veces un render normal: usar un
fragmento de 1 o 2 minutos, **de un anime que esté "en dos"**. El clip de prueba
de `videos\` está animado casi todo "en unos" (12 repetidos en 147 frames), así
que ahí las siete versiones se ven casi iguales.

Para ver el efecto sin buscar un clip, `sim\sim-en-dos-y-tres.mkv` es el clip de
prueba convertido a dibujos equiespaciados que duran 2, 3, 2, 3 frames: el caso
que ataca el suavizador. Ya están renderizadas sus siete versiones, y además hay
dos grillas en `output\` que muestran D2, D4, D5 y D6 a la vez, sincronizadas:
`COMPARACION-sim-en-dos-y-tres-2x2.mkv` y `COMPARACION-salida-2x2.mkv`.

Cualquier modelo de PyTorch se puede combinar con cualquiera de estos métodos,
como en SVFI se elige el modelo y el modo de dedup por separado:

```bat
experimental\run-torch.bat gmfss_u D6_max_total_60 "D:\anime\clip.mkv"
```

### 48 o 60 fps: lo decide el monitor

Con la línea de tiempo, la ventaja de un ×2 "exacto" casi desaparece: un dibujo
que dura 2 o 3 frames se reparte en posiciones fraccionarias igual, y el
suavizador corre cada dibujo una fracción de frame. A 48 o a 60, casi ningún
frame de salida coincide con un original.

Lo que sí importa es que cada frame del video dure un número entero de
refrescos de la pantalla. Si no, el reproductor repite algunos frames y aparece
un tironeo periódico, que arruina justo la fluidez que buscan estas configs:

| Refresco | 48 fps | 60 fps |
|---|---|---|
| 60 Hz | tironea (cadencia 1‑1‑1‑2) | perfecto |
| 120 Hz | tironea (2.5 refrescos por frame) | perfecto |
| **144 Hz** | **perfecto** (3 refrescos por frame) | tironea (2.4) |
| 165 Hz | tironea | tironea |
| 240 Hz | perfecto | perfecto |
| G‑Sync / FreeSync activo en el reproductor | bien | bien |

**En la PC de este proyecto el monitor es de 144 Hz**, así que lo que conviene
es 48: `FLUIDEZ-48-MAX.bat` (D6 a 48) y `COMPARAR-FLUIDEZ-48.bat` (todos los
niveles a 48). Todas las versiones a 60 fps se ven con tironeo en esa pantalla,
y eso puede confundir la comparación a ojo.

Cualquier config se puede forzar a 48 con `set EXP_FPS48=1` antes de
`run-exp.bat`: pasa a ×2 y agrega `-48` al sufijo. Es lo que hace
`COMPARAR-FLUIDEZ-48.bat`. Las que ya salen a 48 (como X1) no cambian.

### Qué midió cada una

Tres escenarios: el clip real, una simulación donde cada dibujo trae tanto
movimiento como tiempo dura (el animador ya compensó el ritmo), y otra con
dibujos equiespaciados que duran 2, 3, 2, 3 (el ritmo queda desparejo).

**Copias exactas** (frames de salida idénticos al anterior; menos es más fluido):

| Config | Clip real | Proporcional | Equiespaciado |
|---|---|---|---|
| X2 | 3.3 % | 9.4 % | 7.7 % |
| D2 | 5.6 % | 9.4 % | 9.2 % |
| D4 | 5.6 % | 9.4 % | 9.2 % |
| D3b | 5.6 % | 9.4 % | 9.2 % |
| D3 | 12.2 % | 15.2 % | 14.7 % |
| D5 | 12.2 % | 15.2 % | 14.7 % |
| **D6** | **3.3 %** | **2.5 %** | **2.2 %** |

**Irregularidad de la velocidad** (cuánto varía la velocidad real de un frame al
siguiente; menos es más parejo):

| Config | Clip real | Proporcional | Equiespaciado |
|---|---|---|---|
| X2 | 0.598 | 0.301 | 0.324 |
| D2 | 0.598 | 0.299 | 0.323 |
| D4 | 0.597 | 0.306 | 0.296 |
| D3b | 0.599 | 0.299 | 0.322 |
| D3 | 0.595 | 0.308 | 0.321 |
| D5 | 0.594 | 0.284 | **0.278** |
| **D6** | **0.593** | **0.281** | 0.285 |

Lo que dicen:

- **D6 es la más fluida medida**: la que menos frames quietos deja, por lejos,
  y de las más parejas en velocidad.
- **D3 y D5 congelaban el final de las tomas.** Con la detección muy agresiva,
  un movimiento tenue antes de un corte pasaba por repetido, y como nunca se
  interpola a través de un corte, el tramo entero quedaba quieto: en el clip de
  prueba, medio segundo antes del último corte. `TAIL` lo arregla (en el plan
  de D3, los frames repetidos bajan de 44 a 12; esos 12 son el piso, el último
  frame de cada toma).
- **D3b no congela, va lento.** La métrica vieja le daba 11.7 % de frames
  "congelados", pero copias exactas tiene las mismas que D2. Lo que contaba como
  congelado era movimiento muy lento y continuo.
- **El suavizador de ritmo solo ayuda cuando el ritmo es desparejo.** Con
  dibujos equiespaciados, D4 baja la irregularidad de 0.323 a 0.296, casi al
  nivel que tendría un ritmo parejo. Cuando el animador ya había compensado, la
  empeora un poco (0.299 a 0.306). El anime real mezcla los dos casos, así que
  el ojo decide.
- Queda algo sin explicar: D5 y D6 salen más parejas que D2 también en el caso
  proporcional, donde el suavizado solo (D4) empeora. Es la combinación de
  detección agresiva y suavizado fuerte; los números son estos, pero no tengo
  la explicación completa.

### Una métrica que engañaba

La columna "tirones" de `smoothness.py` mide cuánto varía la **diferencia de
píxeles** entre frames consecutivos. Con el suavizador subía siempre, incluso
en el escenario para el que está pensado. El motivo: un frame interpolado a
mitad de camino sale más blando que uno cerca de un dibujo real, y al suavizar
los puntos intermedios caen en lugares más variados. La nitidez fluctúa más y la
métrica lo cuenta como tirón, aunque el movimiento sea más parejo.

Por eso se agregó "vel. irreg", que mide la velocidad real con vectores de
movimiento (MVTools, solo para medir). Antes de usarla se validó con una
predicción conocida: con dibujos equiespaciados el suavizador tiene que mejorar,
y con avance proporcional tiene que empeorar. Dio eso en las dos direcciones.

```bat
Python\python.exe experimental\tools\smoothness.py videos\salida.mp4 --mix-even D2_fluidez_60 D4_ritmo_60
```

Opciones: sin nada mide el video tal cual; `--twos` simula anime "en dos";
`--mix` en dos y en tres con avance proporcional; `--mix-even` en dos y en tres
con dibujos equiespaciados.

---

## Modelos PyTorch: GMFSS, AMT, EMA-VFI

GMFSS, AMT y EMA-VFI no podían probarse porque son código PyTorch y el Python
del VapourSynth (3.13, embebido) no sirve para eso. Se resolvió con un entorno
aislado en [`torch-env\`](torch-env/README.md): su propio Python 3.12 y su
propio PyTorch 2.11 + CUDA 12.8, sin tocar producción.

Los modelos no reemplazan al pipeline, se enchufan en el medio: VapourSynth
prepara los frames con la misma conversión de color que usa RIFE, PyTorch
ejecuta el modelo siguiendo el **mismo plan** (cortes y línea de tiempo), y
ffmpeg vuelve a YUV con la misma librería. Así lo único que cambia entre
mediciones es el modelo.

El puente se validó con un control que solo repite el frame anterior: da
**21.37** donde RIFE por el camino de TensorRT da **21.36**. Los números de los
dos mundos son directamente comparables.

### Resultados

Mismo clip, mismo protocolo, mismo plan con línea de tiempo:

| Modelo | "en dos" VMAF | recon VMAF | PSNR recon | fps salida | 10 s de video | VRAM | Episodio 24 min |
|---|---|---|---|---|---|---|---|
| **GMFSS union anime**, flujo completo | **26.98** | **27.05** | 17.96 | 1.4 | 343 s | 3.4 GB | ~12 h |
| GMFSS union anime, flujo a ½ | 26.07 | 26.18 | 17.98 | 2.2 | 220 s | 3.6 GB | ~7 h |
| RIFE 4.26 + línea de tiempo (X1) | 25.95 | 26.09 | 18.04 | **47.0** | **10 s** | 1.4 GB | **~25 min** |
| AMT-G | 25.54 | 25.58 | 18.13 | 1.7 | 291 s | 2.6 GB | ~10 h |
| AMT-L | 25.39 | 25.47 | 18.16 | 2.7 | 180 s | 2.2 GB | ~5 h |
| RIFE 4.16 lite + línea de tiempo (X3) | 25.31 | 25.47 | 18.07 | 63.9 | 8 s | 1.1 GB | ~18 min |
| GIMM-VFI (flujo a ½, su techo acá) | 24.39 | 24.47 | 18.14 | 0.7 | 695 s | 4.6 GB | ~24 h |
| EMA-VFI small | 23.10 | 23.14 | 18.29 | 1.6 | 300 s | 3.4 GB | ~10 h |
| *control: copia congelada* | 21.37 | 21.76 | 17.79 | — | — | — | — |
| *control: promedio simple* | 18.03 | 18.27 | 18.78 | — | — | — | — |

Los tiempos por episodio salen de renders completos reales, con encoder y mux
incluidos: GMFSS midió ×0.034 tiempo real y AMT-L ×0.083.

### Qué significa

**GMFSS, el modelo específico para anime, es el mejor medido: +1.0 VMAF sobre
RIFE 4.26.** Es la diferencia más grande que produjo un cambio de modelo en toda
la exploración (entre modelos RIFE el rango completo fue de 0.6). Pero cuesta
**34 veces más tiempo**: 12 horas por episodio contra 25 minutos.

Un punto de VMAF es una diferencia chica. En
[`results\gmfss_vs_rife.png`](results/gmfss_vs_rife.png) están el mismo frame
con los dos modelos y el original: GMFSS se ve apenas más limpio en los bordes
del pelo, y nada más.

Lo demás no compite: **AMT-G y AMT-L quedan por debajo de RIFE 4.26** (25.54 y
25.39 contra 25.95) siendo 20 veces más lentos, y **EMA-VFI queda muy atrás**
(23.10); su versión grande ni siquiera entra en 6 GB de VRAM a 1080p.

Detalle interesante: GMFSS gana casi todo su margen al calcular el flujo óptico
a resolución completa (26.98 contra 26.07 a media escala). Su propio script
recomienda media escala para 1080p, justamente lo que no conviene acá.

### GIMM-VFI: modelar el movimiento no alcanza

GIMM-VFI (NeurIPS 2024) es el único de la lista que no supone que el movimiento
entre dos dibujos es una línea recta a velocidad constante: aprende una función
continua del movimiento y la evalúa en el instante que se le pida. Sobre el
papel es justo lo que le falta a RIFE.

En la práctica queda en **24.47, por debajo de RIFE 4.26 (26.09), y 68 veces más
lento**. Son unas 24 horas por episodio.

Hay que aclarar que corre a media escala del flujo. A escala completa se queda
sin memoria, y a 0.75 también; 0.65 ni siquiera arranca porque RAFT necesita que
la escala divida limpio. **Media escala es su techo en 6 GB.** GMFSS ganó +0.9
VMAF al pasar de media a escala completa, así que es razonable suponer que GIMM
también ganaría algo — pero necesitaría +1.6 para empatar con RIFE, casi el
doble de lo que ganó GMFSS, y en esta GPU no hay forma de comprobarlo.

Para que corriera hubo que arreglar tres cosas del repo, que quedaron
documentadas en `torch-env\README.md`: sus dataclasses usan defaults mutables
que Python 3.11 ya no acepta, su kernel de softsplat llama a una función de CuPy
que se eliminó en la versión 13, y su paquete interno se llama `models`, igual
que el archivo de adaptadores de este entorno.

### Cuándo usarlo

```bat
experimental\run-torch.bat gmfss_u "D:\anime\opening.mkv"
```

Tiene sentido para un fragmento corto que valga la pena: un opening, una escena
puntual. Para una serie completa no: son 12 horas por episodio para una mejora
que casi no se ve. Renderiza con el mismo encoder y el mismo mux de audio,
subtítulos, tipografías y capítulos que producción.

---

## Interpolación clásica: MVTools, SVP y el "TruMotion" de los televisores

Antes de las redes neuronales, interpolar se hacía con **vectores de
movimiento**: partir la imagen en bloques, buscar cada bloque en el frame
siguiente y mover los píxeles por el camino encontrado. Es lo que hacen SVP, el
plugin MVTools, y el suavizado de movimiento de los televisores (TruMotion en
LG, Auto Motion Plus en Samsung).

MVTools ya estaba instalado en este entorno, así que lo medí con el mismo clip,
la misma referencia y el mismo protocolo que todo lo demás. El banco está en
`vpy\exp_mv.vpy` y `tools\bench_mv.py`.

**Corre en CPU.** Está acá como punto de comparación medido, no como candidato
para producción.

| Variante | recon VMAF | fps | Qué cambia |
|---|---|---|---|
| **flow16_pel4** | **23.84** | 28.3 | bloques de 16, precisión de cuarto de píxel |
| flow16_nomask | 23.74 | 69.6 | sin enmascarado de artefactos |
| block16 | 23.63 | 54.5 | mueve bloques enteros (la TV barata) |
| flow16 | 23.61 | 48.4 | deforma píxel a píxel (lo que hace SVP) |
| block8 | 23.57 | 40.2 | bloques de 8 |
| flow8 | 23.49 | 31.9 | bloques de 8 |
| flow16_norefine | 23.27 | 94.6 | sin segunda pasada de refinamiento |
| flow32 | 23.00 | 77.2 | bloques de 32 |
| flow16_delta2 | 17.43 | 41.6 | vectores al frame de dos lugares |
| *control: copia congelada* | 21.78 | — | |
| **RIFE 4.26**, para comparar | **26.09** | 46.1 | |

### Qué dicen estos números

**El método clásico se estanca alrededor de 23.8, y RIFE saca 26.09.** No es
falta de ajuste: probé bloques de 8, 16 y 32, medio y cuarto de píxel, con y
sin enmascarado, con y sin refinamiento. Nueve variantes caben en una franja de
0.8 VMAF. El techo es del método, no de la configuración.

Lo llamativo es que **no es cuestión de velocidad**: MVTools corre a 48–95 fps
en CPU, al mismo ritmo o más rápido que RIFE en la GPU. No se gana nada
usándolo.

En `results\mvtools_vs_rife.png` está el mismo frame reconstruido por los dos
métodos, en dos situaciones. Con movimiento leve MVTools queda aceptable pero
deja fantasmas: se ve el dibujo anterior encima del nuevo, sobre todo en el pelo
y en las manos. Con movimiento rápido se rompe: el pelo se desgarra y la cara
queda partida. RIFE, en los dos casos, es casi indistinguible del original.

La diferencia visual es mucho mayor de lo que sugieren 2.3 puntos de VMAF. Es un
buen recordatorio de que estas métricas comprimen mucho.

**Los bloques grandes pierden y los chicos no ganan.** flow32 es el peor (23.00)
porque un bloque de 32 píxeles no distingue el movimiento de un mechón de pelo
del del fondo. Pero bajar a 8 tampoco ayuda (23.49): con menos píxeles adentro,
la búsqueda se engancha con cualquier textura parecida. El óptimo queda en 16,
que es justo lo que traen de fábrica SVP y los televisores.

### Mirar dos frames adelante no funciona acá

`flow16_delta2` calcula los vectores contra el frame de **dos** lugares más
adelante en vez del de al lado. Da **17.43: peor que no interpolar nada**
(21.78). No es un error de configuración, es lo que tiene que pasar: el vector
describe el movimiento de dos intervalos, y al usarlo para generar un frame que
está a medio intervalo, todo se pasa de largo al doble de distancia.

Vale la pena aclararlo porque el parámetro existe y suena prometedor. En MVTools
sirve para otra cosa: para **quitar ruido** (`Degrain2`, `Degrain3`), donde
juntar información de varios frames vecinos sí ayuda. Para *generar* un frame
nuevo, no.

### Dónde sí sirve mirar más lejos

La idea de mirar más allá del frame de al lado es correcta, pero el lugar donde
paga no es el cálculo de vectores: es **la línea de tiempo**.

En anime "en dos", el frame de al lado es un duplicado exacto. Da igual qué
método se use —MVTools, RIFE, GMFSS—: entre dos dibujos idénticos no hay
movimiento que encontrar, y todos devuelven una copia congelada. Por eso en la
columna "en dos" de todas las tablas, cualquier método sin línea de tiempo da
exactamente **21.37**.

Hay que mirar más lejos para encontrar el dibujo siguiente de verdad. Eso es
justo lo que hace la línea de tiempo anime-aware: detecta cuántos frames dura
cada dibujo y reparte el movimiento sobre todo ese tiempo. El salto es de
**21.37 a 25.95 VMAF**, más grande que cualquier cambio de modelo que haya
medido. Está explicado en detalle más arriba, en "Qué es la línea de tiempo
anime-aware".

---

## Investigación

- **RIFE**: 4.26 (septiembre 2024) sigue siendo la última versión de
  [Practical-RIFE](https://github.com/hzwer/Practical-RIFE). Su README
  recomienda 4.25 para anime; en las mediciones de la sesión anterior (3 fuentes)
  4.25 quedó por debajo de 4.26 y 4.16 lite. **4.25 y 4.25_heavy son el mismo
  archivo** (MD5 idéntico).
- **vs-mlrt** v15.16 (marzo 2025, TensorRT 10.16) es la última
  ([releases](https://github.com/AmusementClub/vs-mlrt/releases)) y ya está
  instalada. Sus versiones recientes solo agregaron modelos de escalado
  (ArtCNN), ningún modelo de interpolación nuevo. RIFE es el único interpolador
  que trae.
- **GMFSS Fortuna** (el interpolador específico para anime más citado): el
  plugin [vs-gmfss_fortuna](https://github.com/HolyWu/vs-gmfss_fortuna) está
  abandonado (2023, PyTorch 1.13.1, CUDA 11.7, CuPy viejo) y no sirve para el
  VapourSynth R75 de esta PC, que corre sobre Python 3.13. La solución fue usar
  el [código original](https://github.com/98mxr/GMFSS_Fortuna) con PyTorch
  moderno, en el entorno aislado de `torch-env\`. **Se probó y se midió**: ver
  la sección de arriba. Se usó su modelo *union* afinado con flujo óptico de
  anime, que es el mejor de los tres juegos de pesos que publica.
- **AMT y EMA-VFI**: también probados en `torch-env\`. Los dos quedaron por
  debajo de RIFE 4.26 y son 20 veces más lentos.
- **GIMM-VFI** (NeurIPS 2024): probado, 24.47. Ver la sección de arriba.
- **BiM-VFI** (CVPR 2025) quedó clonado en `torch-env\repos\` pero sin
  adaptador. Sus pesos están en Google Drive y su licencia es solo para
  investigación y educación. Después de que AMT, EMA-VFI y GIMM-VFI —los tres
  de la familia de “SOTA generales”— quedaran por debajo de RIFE 4.26 en anime,
  no parecía que fuera a cambiar el panorama. Si querés seguir, el adaptador
  va en `torch-env\vfi\models.py`: son unas 20 líneas.
- **MVTools** (interpolación clásica por vectores): probado, ver su sección.
  Es la familia de SVP y del suavizado de los televisores. Techo en 23.84.

---

## Solo GPU

Toda la inferencia de red neuronal corre en TensorRT, en la GPU:

- `exp_core.py` fuerza `vsmlrt.fallback_backend = None`: si TensorRT falla, el
  render falla. Nunca prueba otro backend.
- `make_backend()` solo devuelve `Backend.TRT` y lo verifica con un `assert`.
- Los backends de CPU (`vsort`, `vsov`, `vsncnn`) ya no están instalados: un
  fallback a CPU sería imposible aunque se pidiera.

Lo que sí corre en CPU son los filtros clásicos de VapourSynth: decodificar,
convertir color, redimensionar y la estadística de cortes y duplicados. Es igual
en producción, y en este entorno no existe versión GPU de esas operaciones.
Ninguna es el modelo.

---

## Metodología y límites

- Todo se midió sobre `videos\salida.mp4`: 6.1 s de anime (147 frames, 1080p
  23.976) con movimiento fuerte y 6 cortes. Es un único clip; la sesión
  anterior comparó modelos sobre tres fuentes y llegó a la misma conclusión (las
  diferencias entre modelos están dentro del ruido).
- Ese clip está animado casi todo "en unos" (6.8 % de frames repetidos,
  `results\duplicados.txt`). La animación "en dos" se **simuló** repitiendo
  cada frame par, lo que da una verdad exacta para comparar. Antes de usar la
  línea de tiempo en tus episodios, corré `tools\analyze_dupes.py` sobre uno:
  cuanto mayor sea el porcentaje de repetidos, más se nota la mejora.
- La velocidad se midió con el clip en bucle hasta 61 s porque la GPU está
  limitada por potencia y los primeros segundos corren en boost.

---

## Estructura

```
experimental\
├─ README.md                  este documento
├─ run-exp.bat                render con una config (usa process-one.bat de producción)
├─ FLUIDEZ-60.bat             D2 a 60 fps: doble clic o arrastrar videos
├─ FLUIDEZ-60-MAX.bat         D6 a 60 fps, la más fluida
├─ COMPARAR-FLUIDEZ.bat       un video con las 7 configs de fluidez
├─ FLUIDEZ-48-MAX.bat         D6 a 48 fps, para monitores de 144 Hz
├─ COMPARAR-FLUIDEZ-48.bat    las 7 configs de fluidez a 48 fps
├─ configs\                   una config por archivo: B* base, E* experimentos, F* 60 fps, X* recomendadas
├─ vpy\
│  ├─ exp_core.py             núcleo: backends, precisión, 1440p, TTA, línea de tiempo
│  ├─ exp_render.vpy          render (mismo contrato que scripts\interpolate.vpy)
│  ├─ exp_bench.vpy           grafos de medición: ref, recon, twos, speed, full
│  └─ exp_mv.vpy              interpolación clásica por vectores (MVTools/SVP), en CPU
├─ tools\
│  ├─ bench.py                calidad + velocidad sostenida + VRAM → results\bench.csv
│  ├─ smoothness.py           % de frames congelados e irregularidad del movimiento
│  ├─ analyze_dupes.py        cuánto de un video está "en dos"
│  ├─ calibrate_dupes.py      umbrales de detección de repetidos
│  ├─ calibrate_motion.py     prueba del guardia de movimiento (descartado)
│  ├─ plan_diff.py            qué frames cambia la línea de tiempo en un video real
│  ├─ compare.vpy             imagen comparativa verdad / normal / línea de tiempo
│  ├─ make_plan.py            genera el plan de interpolación que consume PyTorch
│  ├─ bench_torch.py          mide los modelos PyTorch con el mismo protocolo
│  ├─ bench_mv.py             mide MVTools con el mismo protocolo → results\bench_mv.csv
│  └─ render_torch.py         render completo con un modelo PyTorch
├─ run-torch.bat              render con los modelos PyTorch (GMFSS, AMT, EMA-VFI, GIMM-VFI)
├─ torch-env\                 entorno PyTorch aislado (ver su README)
│  ├─ setup.bat               lo instala todo, idempotente
│  ├─ vfi\                    runner.py y los adaptadores de cada modelo
│  ├─ repos\ weights\         código y pesos de los modelos
│  └─ venv\ python\ bin\      Python 3.12 + PyTorch, solo para esto
├─ sim\                       clip de prueba simulado "en dos y en tres"
├─ results\                   mediciones crudas y comparaciones visuales
├─ cache\                     análisis de duplicados y planes por video
└─ output\                    renders experimentales
```
