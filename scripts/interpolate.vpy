r"""
interpolate.vpy - Pipeline RIFE + sharpening para anime (VapourSynth + TensorRT)

Todos los parametros se leen de variables de entorno (las setea config.bat) o de
argumentos de vspipe (-a CLAVE=valor). Los -a tienen prioridad sobre el entorno.

Uso directo:
    vspipe -c y4m -a SRC="R:\videos\ep01.mkv" scripts\interpolate.vpy - | ffmpeg ...
"""

import os
import sys
from fractions import Fraction

import vapoursynth as vs

core = vs.core

# ---------------------------------------------------------------- parametros
_ARGS = {k: v for k, v in globals().items() if k.isupper() and isinstance(v, str)}


def opt(name, default=None):
    """-a NAME=valor  >  variable de entorno NAME  >  default."""
    val = _ARGS.get(name)
    if val is None:
        val = os.environ.get(name)
    if val is None or val == "":
        return default
    return val


def opt_i(name, default):
    return int(opt(name, default))


def opt_f(name, default):
    return float(opt(name, default))


def opt_b(name, default):
    return str(opt(name, default)).strip().lower() in ("1", "true", "yes", "si", "on")


ROOT = os.path.abspath(opt("VS_ROOT", os.path.join(os.path.dirname(__file__), "..")))
PLUGINS = os.path.join(ROOT, "Python", "plugins64")

sys.path.insert(0, PLUGINS)
core.std.LoadPlugin(os.path.join(PLUGINS, "vstrt.dll"))

from vsmlrt import RIFE, Backend  # noqa: E402  (requiere sys.path de arriba)

# ------------------------------------------------------------- recursos host
# Limitar la cache evita el "Failed to allocate memory for plane / Out of memory"
# cuando el equipo tiene poca RAM libre. 1000-1500 MB es suficiente para RIFE x2.
core.max_cache_size = opt_i("VS_CACHE_MB", 1200)
_threads = opt_i("VS_THREADS", 0)
if _threads > 0:
    core.num_threads = _threads

# -------------------------------------------------------------------- source
SRC = opt("SRC") or opt("TARGET_VIDEO")
if not SRC:
    raise ValueError("interpolate.vpy: falta SRC (o TARGET_VIDEO) con la ruta del video.")
SRC = os.path.abspath(SRC)
if not os.path.isfile(SRC):
    raise FileNotFoundError(f"interpolate.vpy: no existe el archivo {SRC!r}")

# Los indices .lwi van a cache/lwi y no ensucian la carpeta de videos.
_cache_dir = opt("LWI_CACHE", os.path.join(ROOT, "cache", "lwi"))
os.makedirs(_cache_dir, exist_ok=True)
_cache_file = os.path.join(
    _cache_dir, f"{os.path.basename(SRC)}.{os.path.getsize(SRC)}.lwi"
)

clip = core.lsmas.LWLibavSource(source=SRC, cachefile=_cache_file)

if clip.fps_num == 0 or clip.fps_den == 0:
    raise ValueError(
        "interpolate.vpy: la fuente es VFR o no declara fps. Convertila a CFR antes "
        "de interpolar (ffmpeg -i in.mkv -fps_mode cfr -c:v ffv1 cfr.mkv)."
    )

# ------------------------------------------------- deteccion de espacio color
_props = clip.get_frame(0).props
_matrix = _props.get("_Matrix", 2)
if _matrix in (0, 2):  # 0=RGB, 2=unspecified -> adivinar por resolucion
    _matrix = 1 if clip.height > 576 else 6  # 1=bt709, 6=smpte170m
_chromaloc = _props.get("_ChromaLocation", 0)

# Rango de color. En VapourSynth R70+ el prop se llama _Range (_ColorRange quedo
# deprecado) y vale lo mismo que el argumento "range" de resize:
# RANGE_LIMITED = 0, RANGE_FULL = 1. La documentacion vieja dice lo contrario,
# asi que se usa el enum en vez de una constante escrita a mano.
_range = _props.get("_Range")
if _range is None:
    _range = _props.get("_ColorRange", int(vs.RANGE_LIMITED))
_range = int(_range)

if _matrix == 9 and not opt_b("ALLOW_HDR", 0):
    raise ValueError(
        "interpolate.vpy: la fuente es BT.2020 (posible HDR). RIFE trabaja en RGB "
        "lineal-ish y el resultado sera incorrecto. Pone ALLOW_HDR=1 si aun asi "
        "queres continuar."
    )

print(
    f"[interpolate] {os.path.basename(SRC)} | {clip.width}x{clip.height} "
    f"@ {clip.fps_num}/{clip.fps_den} | matrix={_matrix} "
    f"range={'full' if _range == int(vs.RANGE_FULL) else 'limited'} "
    f"| frames={clip.num_frames}",
    file=sys.stderr,
)

# ------------------------------------------------------------ deteccion corte
# CLAVE PARA ANIME: sin esto RIFE "funde" los cambios de plano y genera un frame
# fantasma en cada corte. Se calcula sobre una copia gris reducida (barato) y las
# props se copian al clip real, que es lo que lee vsmlrt.
if opt_b("SCENE_DETECT", 1):
    _thr = opt_f("SCENE_THRESHOLD", 0.20)
    # Solo el plano Y, reducido: barato y menos falsos positivos por grano/paneo.
    _sc = core.std.ShufflePlanes(clip, planes=0, colorfamily=vs.GRAY)
    _sc = core.resize.Bilinear(_sc, width=640, height=360, format=vs.GRAY8)
    _sc = core.misc.SCDetect(_sc, threshold=_thr)
    clip = core.std.CopyFrameProps(
        clip, _sc, props=["_SceneChangeNext", "_SceneChangePrev"]
    )

# ------------------------------------------------------------- preparar a RGB
# RGBH = RGB half-float, el formato nativo del backend TensorRT en fp16.
_kernel = opt("TO_RGB_KERNEL", "Bicubic")
clip = getattr(core.resize, _kernel)(
    clip, format=vs.RGBH,
    matrix_in=_matrix, range_in=_range, chromaloc_in=_chromaloc,
)

# ----------------------------------------------------------- padding a multiplo
MODEL = opt_i("RIFE_MODEL", 4161)


def _tile_requirement(model: int) -> int:
    """Mismo criterio que vsmlrt.RIFEMerge: multiplo exigido por el modelo."""
    s = str(model)
    major, minor = int(s[0]), int(s[1:3])
    variant = s[3] if len(s) >= 4 else ""
    if (major, minor) >= (4, 26):
        return 64
    if (major, minor) == (4, 25) and variant == "1":  # 4.25 lite
        return 128
    if (major, minor) == (4, 25) and variant == "2":  # 4.25 heavy
        return 64
    return 32


_impl = opt_i("RIFE_IMPL", 0) or None

def _has_v2(model: int) -> bool:
    """La implementacion v2 solo existe para algunos modelos. Si falta el onnx,
    vsmlrt vuelve a v1 EN SILENCIO, y v1 si necesita el padding manual."""
    s = str(model)
    variant = {"1": "_lite", "2": "_heavy"}.get(s[3] if len(s) >= 4 else "", "")
    name = f"rife_v{int(s[0])}.{int(s[1:3])}{variant}{'_ensemble' if opt_b('RIFE_ENSEMBLE', 0) else ''}.onnx"
    return os.path.isfile(os.path.join(PLUGINS, "models", "rife_v2", name))


# v2 hace su propio padding interno, asi que no hay que agrandar el tensor.
_use_v2 = _impl == 2 and _has_v2(MODEL)
_mult = 1 if _use_v2 else _tile_requirement(MODEL)
_pad_w = (-clip.width) % _mult
_pad_h = (-clip.height) % _mult
if _pad_w or _pad_h:
    # resize.Point con src_* mas grande replica el borde en vez de meter negro.
    # AddBorders mete una franja negra y RIFE calcula flujo optico contra ese
    # borde duro, lo que ensucia las ultimas filas/columnas antes del crop.
    clip = core.resize.Point(
        clip,
        width=clip.width + _pad_w, height=clip.height + _pad_h,
        src_width=clip.width + _pad_w, src_height=clip.height + _pad_h,
    )

# ---------------------------------------------------------------------- RIFE
_multi_raw = str(opt("RIFE_MULTI", "2")).strip()
if "/" in _multi_raw:
    MULTI = Fraction(_multi_raw)
elif "." in _multi_raw:
    MULTI = Fraction(_multi_raw).limit_denominator(1000)
else:
    MULTI = int(_multi_raw)

backend = Backend.TRT(
    fp16=True,
    num_streams=opt_i("TRT_STREAMS", 2),
    use_cuda_graph=opt_b("TRT_CUDA_GRAPH", 1),
    builder_optimization_level=opt_i("TRT_OPT_LEVEL", 3),
    output_format=opt_i("TRT_OUTPUT_FORMAT", 1),  # 1 = salida fp16, menos ancho de banda
    device_id=opt_i("TRT_DEVICE", 0),
    static_shape=True,
    tf32=False,
    engine_folder=opt("TRT_ENGINE_DIR") or None,
)

if _impl == 2 and not _use_v2:
    print(f"[interpolate] AVISO: no hay modelo rife_v2 para {MODEL}, se usa v1.",
          file=sys.stderr)

clip = RIFE(clip, model=MODEL, multi=MULTI, backend=backend,
            ensemble=opt_b("RIFE_ENSEMBLE", 0), _implementation=_impl)

if _pad_w or _pad_h:
    clip = core.std.Crop(clip, right=_pad_w, bottom=_pad_h)

# ------------------------------------------------------------ vuelta a YUV
_dither = opt("DITHER", "error_diffusion")
_deband = opt_b("DEBAND", 0)

# placebo.Deband solo acepta 8/16 bits enteros o 32 float: NO acepta 10 bits.
# Por eso, si hay deband, se pasa por 16 bits y recien al final se baja a 10
# con dithering. Sin deband se va directo a 10 bits como siempre.
clip = core.resize.Bicubic(
    clip, format=vs.YUV420P16 if _deband else vs.YUV420P10,
    matrix=_matrix, range=_range, chromaloc=_chromaloc,
    dither_type=_dither,
)

# ------------------------------------------------------------------ post proc
# CAS solo en luma: en 4:2:0 el croma esta submuestreado y afilarlo produce
# flecos de color en los bordes de linea, que es justo lo que abunda en anime.
_sharp = opt_f("CAS_SHARPNESS", 0.35)
if _sharp > 0:
    _planes = [0] if opt_b("CAS_LUMA_ONLY", 1) else [0, 1, 2]
    clip = core.cas.CAS(clip, sharpness=_sharp, planes=_planes)

# Debanding opcional (GPU, via libplacebo). Util en degradados y fundidos, donde
# el ida y vuelta por RGB fp16 puede dejar banding visible al codificar.
if _deband:
    clip = core.placebo.Deband(
        clip,
        threshold=opt_f("DEBAND_THRESHOLD", 3.0),
        radius=opt_f("DEBAND_RADIUS", 16.0),
        grain=opt_f("DEBAND_GRAIN", 0.0),
        planes=1 | 2 | 4,
    )
    clip = core.resize.Point(clip, format=vs.YUV420P10, dither_type=_dither)

print(
    f"[interpolate] salida: {clip.width}x{clip.height} @ "
    f"{clip.fps_num}/{clip.fps_den} ({clip.fps_num / clip.fps_den:.3f} fps) | "
    f"modelo={MODEL}{' v2' if _use_v2 else ''} multi={MULTI} "
    f"streams={opt_i('TRT_STREAMS', 2)} scd={opt_b('SCENE_DETECT', 1)}"
    f"{' deband' if _deband else ''}",
    file=sys.stderr,
)

clip.set_output()
