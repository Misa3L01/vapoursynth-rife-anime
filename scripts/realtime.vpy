r"""
realtime.vpy - Interpolacion RIFE en tiempo real, para ver anime en mpv.

No genera archivos: mpv decodifica el video, se lo pasa a este script frame a
frame (la variable video_in) y muestra lo que devuelve. Lo lanza
scripts\ver-en-vivo.bat, que tambien usa la app (boton "Ver en tiempo real").

Es el mismo pipeline que interpolate.vpy (deteccion de cortes, RGB fp16, RIFE
con TensorRT, CAS), con las diferencias que impone el tiempo real:

  - El video llega sin fps fijo y con largo "infinito" (es un flujo en vivo).
    La fps se toma de container_fps, que manda mpv.
  - Para x2.5 (60 fps) se usa el modo video_player de vsmlrt, que calcula cada
    frame al vuelo. El modo normal arma una lista de indices del largo del
    video, que aca seria de cientos de millones.
  - El color se lee frame a frame (ver mas abajo por que).
  - La vuelta a YUV usa dithering ordenado: el de difusion de error de
    produccion es mejor, pero cuesta CPU que aca no sobra.

Parametros (variables de entorno, las setea ver-en-vivo.bat desde config.bat):
  RT_FPS         48 (x2) | 60 (x2.5)
  RT_MODEL       modelo RIFE (4161 = 4.16 lite)
  RT_RES         altura a la que se interpola: auto | 0 (nativa) | 1080 | 810 | 720
  RT_CAS         nitidez despues de interpolar (0 = sin CAS)
  RT_SCALE       resolucion del flujo optico: auto | 1.0 | 0.5 (solo modelos 4.6 o
                 anteriores: vsmlrt no lo admite desde 4.7)
  SCENE_THRESHOLD, TRT_STREAMS, VS_ROOT   igual que en produccion

Para medir la velocidad fuera de mpv (el video en bucle, sin decodificar ni
mostrar), con la ruta del video absoluta:
  vspipe -a SRC="R:\...\videos\salida.mp4" -a LOOP=10 scripts\realtime.vpy --
"""
import os
import sys
from fractions import Fraction

import vapoursynth as vs

core = vs.core

_ARGS = {k: v for k, v in globals().items() if k.isupper() and isinstance(v, str)}


def opt(name, default=None):
    """-a NAME=valor  >  variable de entorno NAME  >  default."""
    val = _ARGS.get(name)
    if val is None:
        val = os.environ.get(name)
    return default if val in (None, "") else val


def log(msg):
    print("[tiempo real] " + msg, file=sys.stderr)


# vspipe se cambia al directorio del script antes de ejecutarlo: si la ruta
# llego relativa, __file__ ya no es valido desde el cwd nuevo.
_HERE = (os.getcwd() if os.path.isfile(os.path.basename(__file__))
         else os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.abspath(opt("VS_ROOT", os.path.join(_HERE, "..")))
PLUGINS = os.path.join(ROOT, "Python", "plugins64")
if PLUGINS not in sys.path:
    sys.path.insert(0, PLUGINS)
if not hasattr(core, "trt"):
    core.std.LoadPlugin(os.path.join(PLUGINS, "vstrt.dll"))

from vsmlrt import RIFE, Backend  # noqa: E402

core.max_cache_size = int(opt("VS_CACHE_MB", 1200))

# ------------------------------------------------------------------ entrada
if "video_in" in globals():                           # dentro de mpv
    clip = video_in  # noqa: F821 (la define mpv)
    fps = Fraction(globals().get("container_fps") or 0).limit_denominator(10000)
    if fps <= 0:
        fps = Fraction(24000, 1001)
        log("el video no declara fps, se asume 23.976")
else:                                                 # medicion con vspipe
    src = os.path.abspath(opt("SRC"))
    clip = core.lsmas.LWLibavSource(src, cachefile=os.path.join(
        ROOT, "cache", "lwi", "%s.%d.lwi" % (os.path.basename(src), os.path.getsize(src))))
    fps = clip.fps
    clip = clip * int(opt("LOOP", 1))
clip = core.std.AssumeFPS(clip, fpsnum=fps.numerator, fpsden=fps.denominator)

target = int(opt("RT_FPS", 48))
multi = 2 if target <= 48 else Fraction(5, 2)
out_fps = fps * multi


# -------------------------------------------------------------------- color
# El color se lee frame a frame, nunca al arrancar: dentro de mpv, pedir un
# frame mientras el script se inicializa devuelve uno negro de relleno, sin
# datos de color.
#
# mpv manda la matriz con el nombre viejo _ColorSpace; la conversion a RGB lee
# _Matrix. Sin dato (2 = sin especificar) se deduce por la altura, como en
# produccion.
#
# Ademas matriz y rango se copian a RT_*, que sobreviven a RIFE, para volver a
# YUV con los mismos valores. Es obligatorio: mpv muestra la salida con los
# parametros de color de la ENTRADA e ignora los que traiga el frame. Medido: un
# frame etiquetado como rango completo se vio con el contraste corrido (error
# medio 9.4 contra 0.4). Con la ida y vuelta simetrica tambien quedan bien los
# videos HDR.
#
# Se hace con akarin (C++) y no con funciones de Python por frame: a 60 fps el
# modo video_player de vsmlrt ya corre cuatro por frame, y sumar dos mas hizo
# perder frames en mpv (47 en 61 s) aunque la velocidad total no cambiara.
# En akarin una propiedad ausente vale 0, que como rango es "limitado".
_fb = 1 if clip.height > 576 else 6
_matrix = ("x._Matrix 0 = x._Matrix 2 = or "
           "x._ColorSpace 0 = x._ColorSpace 2 = or %d x._ColorSpace ? x._Matrix ?" % _fb)
clip = core.akarin.PropExpr(clip, lambda: dict(_Matrix=_matrix, RT_Matrix=_matrix,
                                               RT_Range="x._Range"))

# ----------------------------------------------------------- cortes de escena
thr = float(opt("SCENE_THRESHOLD", 0.20))
sc = core.std.ShufflePlanes(clip, planes=0, colorfamily=vs.GRAY)
sc = core.resize.Bilinear(sc, width=640, height=360, format=vs.GRAY8)
sc = core.misc.SCDetect(sc, threshold=thr)
clip = core.std.CopyFrameProps(clip, sc, props=["_SceneChangeNext", "_SceneChangePrev"])

# ---------------------------------------------------------------------- RIFE
# Altura de proceso. RIFE cuesta en proporcion a los pixeles: si no llega a
# tiempo real, se interpola una version mas chica y mpv la lleva a pantalla
# completa con sus escaladores de GPU. Los subtitulos no se afectan: mpv los
# dibuja a la resolucion de la pantalla, no a la del video.
#   auto: 1080 a 48 fps (lo de mas de 1080p no llega a tiempo real) y 720 a
#   60 fps. Medido con esta GPU a x2.5: 1080p 38 fps, 900p 56, 810p 72, 720p
#   92. 810p llega en vspipe, pero reproduciendo en mpv (que ademas decodifica
#   y dibuja) una corrida salio perfecta y otra perdio el 1.3 por ciento de los
#   frames. 720p no perdio ninguno. Un numero fuerza esa altura; 0 = nativa.
res = str(opt("RT_RES", "auto")).strip().lower()
if res == "auto":
    res = 1080 if multi == 2 else 720
res = int(res) if str(res).isdigit() else 0
res -= res % 2                                        # YUV 4:2:0 pide alto par
if 0 < res < clip.height:
    w0 = int(round(clip.width * res / clip.height / 2)) * 2
    h0 = res
else:
    w0, h0 = clip.width, clip.height
rgb = core.resize.Bicubic(clip, width=w0, height=h0, format=vs.RGBH)

model = int(opt("RT_MODEL", 4161))
s = str(model)
version = (int(s[0]), int(s[1:3]))
variant = {"1": "_lite", "2": "_heavy"}.get(s[3] if len(s) >= 4 else "", "")
has_v2 = os.path.isfile(os.path.join(PLUGINS, "models", "rife_v2",
                                     "rife_v%d.%d%s.onnx" % (version + (variant,))))
impl = 2 if has_v2 else None
if not has_v2:
    # v1 exige que el tamano sea multiplo de 32 (64 desde 4.26): se replica el borde
    mult = 64 if version >= (4, 26) else 32
    pw, ph = (-w0) % mult, (-h0) % mult
    if pw or ph:
        rgb = core.resize.Point(rgb, width=w0 + pw, height=h0 + ph,
                                src_width=w0 + pw, src_height=h0 + ph)

scale = opt("RT_SCALE", "auto")
if scale == "auto":
    # desde 4.7 vsmlrt no admite otra escala de flujo
    scale = 1.0 if version >= (4, 7) or h0 <= 1080 else 0.5
scale = float(scale)

backend = Backend.TRT(
    fp16=True, tf32=False, output_format=1, static_shape=True,
    num_streams=int(opt("TRT_STREAMS", 2)), use_cuda_graph=True,
    builder_optimization_level=int(opt("TRT_OPT_LEVEL", 3)),
    device_id=int(opt("TRT_DEVICE", 0)),
)
rgb = RIFE(rgb, model=model, multi=multi, scale=scale, backend=backend,
           video_player=True, _implementation=impl)
if rgb.width != w0 or rgb.height != h0:
    rgb = core.std.Crop(rgb, right=rgb.width - w0, bottom=rgb.height - h0)

# ---------------------------------------------------------------- salida
# Una conversion por combinacion de matriz (709, 601, 2020) y rango, y akarin
# elige la que corresponde a cada frame. Solo se calcula la elegida.
_convs = [core.resize.Bicubic(rgb, format=vs.YUV420P10, matrix=m, range=r, dither_type="ordered")
          for m in (1, 6, 9) for r in (0, 1)]
out = core.akarin.Select(_convs, rgb,
                         "x.RT_Matrix 6 = x.RT_Matrix 5 = or 1 "
                         "x.RT_Matrix 9 = x.RT_Matrix 10 = or 2 0 ? ? 2 * x.RT_Range +")
cas = float(opt("RT_CAS", opt("CAS_SHARPNESS", 0.35)))
if cas > 0:
    out = core.cas.CAS(out, sharpness=cas, planes=[0])
out = core.std.AssumeFPS(out, fpsnum=out_fps.numerator, fpsden=out_fps.denominator)

log("%dx%d %.3f -> %.3f fps | RIFE %s%s | flujo x%s | cortes %.2f" % (
    w0, h0, float(fps), float(out_fps), model, " v2" if has_v2 else "", scale, thr))
out.set_output()
