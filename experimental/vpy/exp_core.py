"""
exp_core.py - Nucleo del pipeline experimental de interpolacion.

Todo lo que es red neuronal corre en TensorRT (GPU). No hay backend de CPU ni
fallback: vsmlrt.fallback_backend se fuerza a None y make_backend() solo
devuelve Backend.TRT. Ademas los backends de CPU (vsort, vsov, vsncnn) ya no
estan instalados, asi que un fallback a CPU seria imposible aunque se pidiera.

Lo que si corre en CPU son los filtros clasicos de VapourSynth (decodificar,
convertir color, redimensionar, estadisticas de corte), igual que en
produccion: no existe version GPU de ellos en este entorno.

Palancas experimentales (cada una se puede prender por separado):

  precision   fp16 | fp32. fp32 usa entrada RGBS y desactiva TF32.
  res_scale   procesa RIFE a mas resolucion (1.333 = 1440p) y vuelve a 1080p.
  tta         promedia RIFE normal con RIFE sobre el cuadro espejado.
  timeline    interpolacion con linea de tiempo propia: detecta frames
              repetidos (anime "en dos/tres") y reparte el movimiento de cada
              dibujo sobre todo su tiempo en pantalla, en vez de concentrarlo
              en un solo intervalo. Sirve para cualquier multi (x2, x2.5).
  smooth      suavizador de ritmo sobre la linea de tiempo (0 = apagado). Empareja
              la velocidad cuando los dibujos duran 2, 3, 2, 3 frames. Es lo que
              SVFI llama TruMotion.
"""
import bisect
import json
import os
import sys
from fractions import Fraction

import vapoursynth as vs

core = vs.core

EXP_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ROOT = os.path.abspath(os.path.join(EXP_DIR, ".."))
PLUGINS = os.path.join(ROOT, "Python", "plugins64")

if PLUGINS not in sys.path:
    sys.path.insert(0, PLUGINS)
if not hasattr(core, "trt"):
    core.std.LoadPlugin(os.path.join(PLUGINS, "vstrt.dll"))

import vsmlrt  # noqa: E402
from vsmlrt import RIFE, RIFEMerge, Backend  # noqa: E402

# Solo GPU: si TensorRT falla, que falle. Nunca probar otro backend.
vsmlrt.fallback_backend = None


# --------------------------------------------------------------------- backend
def make_backend(precision="fp16", streams=2, cuda_graph=True, opt_level=3):
    if precision == "fp16":
        b = Backend.TRT(fp16=True, tf32=False, output_format=1, num_streams=streams,
                        use_cuda_graph=cuda_graph, builder_optimization_level=opt_level,
                        static_shape=True)
    elif precision == "fp32":
        b = Backend.TRT(fp16=False, tf32=False, output_format=0, num_streams=streams,
                        use_cuda_graph=cuda_graph, builder_optimization_level=opt_level,
                        static_shape=True)
    else:
        raise ValueError("precision debe ser fp16 o fp32, no %r" % precision)
    assert isinstance(b, Backend.TRT), "solo se permite TensorRT (GPU)"
    return b


def rgb_format(precision):
    return vs.RGBH if precision == "fp16" else vs.RGBS


def mask_format(precision):
    return vs.GRAYH if precision == "fp16" else vs.GRAYS


# ------------------------------------------------------------------ modelos
def tile_requirement(model):
    s = str(model)
    major, minor = int(s[0]), int(s[1:3])
    variant = s[3] if len(s) >= 4 else ""
    if (major, minor) >= (4, 26):
        return 64
    if (major, minor) == (4, 25) and variant == "1":
        return 128
    if (major, minor) == (4, 25) and variant == "2":
        return 64
    return 32


def has_v2(model):
    s = str(model)
    variant = {"1": "_lite", "2": "_heavy"}.get(s[3] if len(s) >= 4 else "", "")
    name = "rife_v%d.%d%s.onnx" % (int(s[0]), int(s[1:3]), variant)
    return os.path.isfile(os.path.join(PLUGINS, "models", "rife_v2", name))


def model_available(model):
    s = str(model)
    variant = {"1": "_lite", "2": "_heavy"}.get(s[3] if len(s) >= 4 else "", "")
    name = "rife_v%d.%d%s.onnx" % (int(s[0]), int(s[1:3]), variant)
    return os.path.isfile(os.path.join(PLUGINS, "models", "rife", name))


# ------------------------------------------------------------ color / props
def color_info(clip):
    p = clip.get_frame(0).props
    matrix = p.get("_Matrix", 2)
    if matrix in (0, 2):
        matrix = 1 if clip.height > 576 else 6
    rng = p.get("_Range")
    if rng is None:
        rng = p.get("_ColorRange", int(vs.RANGE_LIMITED))
    return {"matrix": int(matrix), "range": int(rng), "chromaloc": int(p.get("_ChromaLocation", 0))}


def scene_detect(clip, threshold=0.20):
    """Igual que produccion: SCDetect sobre la luma reducida a 640x360."""
    sc = core.std.ShufflePlanes(clip, 0, vs.GRAY)
    sc = core.resize.Bilinear(sc, 640, 360, format=vs.GRAY8)
    sc = core.misc.SCDetect(sc, threshold=threshold)
    return core.std.CopyFrameProps(clip, sc, props=["_SceneChangeNext", "_SceneChangePrev"])


def to_rgb(clip, ci, precision="fp16", kernel="Bicubic"):
    return getattr(core.resize, kernel)(
        clip, format=rgb_format(precision),
        matrix_in=ci["matrix"], range_in=ci["range"], chromaloc_in=ci["chromaloc"])


def to_yuv(clip, ci, fmt=vs.YUV420P10, dither="error_diffusion"):
    return core.resize.Bicubic(clip, format=fmt, matrix=ci["matrix"], range=ci["range"],
                               chromaloc=ci["chromaloc"], dither_type=dither)


# ------------------------------------------------------------ resolucion
def _even(v, mult=8):
    return int(round(v / mult)) * mult


def upscale(rgb, res_scale):
    if res_scale == 1:
        return rgb
    w, h = _even(rgb.width * res_scale), _even(rgb.height * res_scale)
    return core.resize.Spline36(rgb, w, h)


def downscale(rgb, width, height):
    if rgb.width == width and rgb.height == height:
        return rgb
    return core.resize.Spline36(rgb, width, height)


def pad_for(rgb, model, impl):
    """v2 hace su propio padding; v1 exige multiplos de 32/64/128."""
    mult = 1 if (impl == 2 and has_v2(model)) else tile_requirement(model)
    pw, ph = (-rgb.width) % mult, (-rgb.height) % mult
    if pw or ph:
        rgb = core.resize.Point(rgb, rgb.width + pw, rgb.height + ph,
                                src_width=rgb.width + pw, src_height=rgb.height + ph)
    return rgb, pw, ph


def unpad(rgb, pw, ph):
    return core.std.Crop(rgb, right=pw, bottom=ph) if (pw or ph) else rgb


# ------------------------------------------------------------------ TTA
def _average(a, b):
    if a.format.bits_per_sample == 16 and a.format.sample_type == vs.FLOAT:
        return core.akarin.Expr([a, b], "x y + 0.5 *")
    return core.std.Merge(a, b, 0.5)


def _flip(c):
    return core.std.FlipHorizontal(c)


# ------------------------------------------------- interpolacion estandar
def interpolate_standard(rgb, multi, model, backend, impl=None, tta=False):
    """vsmlrt.RIFE tal cual (mismo camino que produccion), opcionalmente con TTA."""
    out = RIFE(rgb, model=model, multi=multi, backend=backend, _implementation=impl)
    if tta:
        alt = _flip(RIFE(_flip(rgb), model=model, multi=multi, backend=backend, _implementation=impl))
        out = _average(out, alt)
    return out


# ------------------------------------------------- analisis de duplicados
def analyze_timeline(src, sc_threshold=0.20, dup_mean=0.0035, dup_max=0.10, cache_key=None):
    """
    Recorre el video UNA vez y devuelve, por frame, si repite el dibujo anterior
    y si hay corte de escena. Se cachea en experimental\\cache por video.

    Un frame cuenta como repetido si la diferencia media es minima Y tampoco hay
    una zona chica que cambio mucho (una boca que se mueve sobre una cara quieta
    da media baja pero maximo alto). El maximo se mide sobre la diferencia
    suavizada, para que el ruido de compresion no cuente como cambio.
    """
    cache_path = None
    if cache_key:
        cdir = os.path.join(EXP_DIR, "cache")
        os.makedirs(cdir, exist_ok=True)
        cache_path = os.path.join(cdir, "%s.timeline.json" % cache_key)
        if os.path.isfile(cache_path):
            with open(cache_path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            if data.get("params") == [sc_threshold, dup_mean, dup_max] and len(data["dup"]) == src.num_frames:
                return data["dup"], data["cut"], data.get("mean"), data.get("max")

    g = core.std.ShufflePlanes(src, 0, vs.GRAY)
    g = core.resize.Bilinear(g, 480, 270, format=vs.GRAY8)
    prev = g[0] + g[:-1]
    ad = core.std.Expr([g, prev], "x y - abs")
    ad = core.std.BoxBlur(ad, hradius=1, vradius=1)
    ad = core.std.PlaneStats(ad, prop="D")
    sc = scene_detect(src, sc_threshold)
    ad = core.std.CopyFrameProps(ad, sc, props=["_SceneChangePrev"])

    means, maxs, cuts = [], [], []
    for f in ad.frames(close=True):
        means.append(f.props["DAverage"])
        maxs.append(f.props["DMax"] / 255.0)
        cuts.append(bool(f.props.get("_SceneChangePrev", 0)))
    dup = [i > 0 and (not cuts[i]) and means[i] < dup_mean and maxs[i] < dup_max for i in range(len(means))]

    if cache_path:
        with open(cache_path, "w", encoding="utf-8") as fh:
            json.dump({"params": [sc_threshold, dup_mean, dup_max], "dup": dup, "cut": cuts,
                       "mean": means, "max": maxs}, fh)
    return dup, cuts, means, maxs


def smooth_key_times(keys, cut, max_gap, smooth):
    """
    Suavizador de ritmo: devuelve el instante (en frames de origen) en que se
    muestra cada dibujo.

    Sin suavizar, cada dibujo se muestra en su frame original y el movimiento
    hasta el siguiente se reparte sobre su propio tiempo en pantalla. Si los
    dibujos duran 2, 3, 2, 3 frames, la velocidad salta de 1/2 a 1/3 en cada
    dibujo: el movimiento acelera y frena aunque ningun frame quede congelado.

    El suavizado reemplaza cada instante por el promedio de sus vecinos (ventana
    de 2*smooth+1 dibujos), asi una secuencia 0, 2, 5, 7, 10 queda casi
    equiespaciada y el movimiento avanza a velocidad pareja. Cada dibujo se
    corre normalmente una fraccion de frame, que no se nota contra el audio.
    Es lo que SVFI llama TruMotion.

    Solo se suaviza dentro de un tramo continuo: los cortes de escena y las
    pausas largas (mas de max_gap) quedan fijos, y la ventana se achica cerca de
    esos bordes para no correrlos.
    """
    times = [Fraction(k) for k in keys]
    if smooth <= 0 or len(keys) < 3:
        return times
    runs, start = [], 0
    for m in range(len(keys) - 1):
        if cut[keys[m + 1]] or keys[m + 1] - keys[m] > max_gap:
            runs.append((start, m))
            start = m + 1
    runs.append((start, len(keys) - 1))
    out = list(times)
    for s, e in runs:
        for i in range(s + 1, e):
            w = min(smooth, i - s, e - i)
            out[i] = sum(times[i - w:i + w + 1]) / (2 * w + 1)
    return out


def build_timeline(n_src, multi, dup, cut, max_gap=3, dedup=True, smooth=0, tail=False):
    """
    Para cada frame de salida j (tiempo t = j / multi, en unidades de frame de
    origen) decide: copiar un frame, o interpolar entre los dibujos a y b con
    proporcion r. Devuelve una lista de tuplas (a, b, r); r = 0 significa copiar a.

    - Con dedup, los "dibujos" son los frames que no repiten al anterior, y el
      movimiento entre dos dibujos se reparte sobre todo el tiempo que el
      primero estuvo en pantalla (hasta max_gap frames: "en dos" o "en tres").
    - Pausas mas largas que max_gap se interpolan frame a frame, como el metodo
      normal. Pueden ser un plano quieto de verdad (sale igual) o un movimiento
      tan tenue que pasa por repetido, como una gota clara sobre fondo claro:
      tratarlas como quietas lo congelaria. Tampoco conviene repartir el
      movimiento sobre toda la pausa: el personaje arrancaria antes de tiempo.
    - Nunca se interpola a traves de un corte de escena.
    - Con smooth > 0, los instantes de los dibujos se suavizan para que el
      movimiento avance a velocidad pareja (ver smooth_key_times).
    - Con tail, el final de una toma (desde el ultimo dibujo hasta el corte) se
      interpola frame a frame en vez de quedarse en ese dibujo. Es el mismo
      criterio que las pausas largas: si esos frames se tomaron por repetidos
      pero en realidad tenian un movimiento tenue, sin esto se congelan. Si
      eran repetidos de verdad, interpolar entre frames iguales da el mismo
      frame y no cambia nada.
    """
    multi = Fraction(multi)
    n_out = int(n_src * multi)
    if dedup:
        keys = [i for i in range(n_src) if i == 0 or not dup[i]]
        times = smooth_key_times(keys, cut, max_gap, smooth)
    else:
        keys = list(range(n_src))
        times = [Fraction(k) for k in keys]

    plan = []
    for j in range(n_out):
        t = Fraction(j) / multi
        m = bisect.bisect_right(times, t) - 1
        a = keys[m]
        if m + 1 >= len(keys):                       # despues del ultimo dibujo
            i = min(int(t), n_src - 1)
            r = float(t - i)
            plan.append((i, i + 1, r) if tail and r > 0 and i + 1 < n_src else (i, 0, 0.0))
            continue
        b = keys[m + 1]
        if cut[b]:                                   # el siguiente dibujo es otra escena
            i = int(t)
            r = float(t - i)
            if tail and i + 1 < b and r > 0:         # final de toma: frame a frame
                plan.append((i, i + 1, r))
            elif tail:
                plan.append((i, 0, 0.0))
            else:
                plan.append((a, 0, 0.0))
            continue
        gap = b - a
        if gap > max_gap:                            # pausa larga: frame a frame
            i = int(t)
            r = float(t - i)
            plan.append((i, i + 1, r) if r > 0 else (i, 0, 0.0))
            continue
        # sin suavizar, times[m] == a y times[m + 1] == b: es (t - a) / gap
        r = float((t - times[m]) / (times[m + 1] - times[m]))
        plan.append((a, b, r) if r > 0 else (a, 0, 0.0))
    return plan


def interpolate_timeline(rgb, plan, model, backend, precision="fp16", impl=None, tta=False, r_steps=240):
    """
    Ejecuta el plan con RIFEMerge, que acepta cualquier par de frames y cualquier
    proporcion. Los frames que son copias nunca piden inferencia a la GPU.
    """
    n_out = len(plan)
    a_idx = [p[0] for p in plan]
    b_idx = [p[1] for p in plan]
    r_q = [int(round(p[2] * r_steps)) for p in plan]
    do = [p[2] > 0 for p in plan]

    one = rgb[0]
    template = core.std.Loop(one, n_out)

    def pick(idx):
        def _f(n):
            return core.std.Loop(rgb[idx[n]], n_out)
        return _f

    clipa = core.std.FrameEval(template, pick(a_idx))
    clipb = core.std.FrameEval(template, pick(b_idx))

    mfmt = mask_format(precision)
    masks = {}

    def mask_for(n):
        q = r_q[n]
        if q not in masks:
            masks[q] = core.std.BlankClip(width=rgb.width, height=rgb.height, format=mfmt,
                                          length=n_out, color=q / r_steps)
        return masks[q]

    mtemplate = core.std.BlankClip(width=rgb.width, height=rgb.height, format=mfmt, length=n_out)
    mask = core.std.FrameEval(mtemplate, mask_for)

    merged = RIFEMerge(clipa, clipb, mask, model=model, backend=backend, _implementation=impl)
    if tta:
        alt = _flip(RIFEMerge(_flip(clipa), _flip(clipb), mask, model=model, backend=backend,
                              _implementation=impl))
        merged = _average(merged, alt)
    merged = core.std.SetFrameProps(merged, _SceneChangeNext=0)  # prolijidad
    return core.std.FrameEval(clipa, lambda n: merged if do[n] else clipa)


# ------------------------------------------------------ configuracion
CFG_KEYS = ["model", "impl", "precision", "multi", "res_scale", "tta", "timeline", "dedup",
            "max_gap", "smooth", "tail", "sc_threshold", "dup_mean", "dup_max", "streams", "cuda_graph",
            "opt_level", "kernel", "cas"]


def cfg_from(script_globals):
    """EXP_<CLAVE> desde vspipe -a (prioridad) o desde el entorno."""
    cfg = {}
    for k in CFG_KEYS:
        name = "EXP_" + k.upper()
        v = script_globals.get(name)
        if v is None:
            v = os.environ.get(name)
        if v not in (None, ""):
            cfg[k] = v
    return cfg


def source(path):
    lwi = os.path.join(ROOT, "cache", "lwi", "%s.%d.lwi" % (os.path.basename(path), os.path.getsize(path)))
    return core.lsmas.LWLibavSource(source=path, cachefile=lwi)


def cache_key_for(path, cfg, tag=""):
    import hashlib
    h = hashlib.sha1(("%s|%d|%s" % (os.path.basename(path), os.path.getsize(path), tag)).encode("utf-8"))
    return h.hexdigest()[:16]


# ------------------------------------------------ fuentes derivadas
def derive(src, kind="plain", loop=1):
    """Las mismas fuentes derivadas que usan los modos de medicion, en un solo
    lugar, para que el pipeline de VapourSynth y el de PyTorch vean lo mismo."""
    if kind == "decimated":          # se tira un frame de cada dos
        return src.std.SelectEvery(2, 0)
    if kind == "held":               # animacion "en dos" simulada
        return core.std.Interleave([src.std.SelectEvery(2, 0)] * 2)[: src.num_frames]
    if kind == "looped":
        return src * int(loop)
    return src


# ------------------------------------------------------ pipeline completo
def run(src, cfg, cache_key=None):
    """
    src: clip YUV de origen. cfg: dict con las claves de abajo.
    Devuelve (clip RGB interpolado a la resolucion original, info de color).
    """
    precision = cfg.get("precision", "fp16")
    model = int(cfg.get("model", 4161))
    impl = int(cfg.get("impl", 2)) or None
    multi = cfg.get("multi", "2")
    multi = Fraction(multi) if "/" in str(multi) else int(multi)
    res_scale = float(cfg.get("res_scale", 1.0))
    tta = bool(int(cfg.get("tta", 0)))
    timeline = bool(int(cfg.get("timeline", 0)))
    sc_thr = float(cfg.get("sc_threshold", 0.20))

    if not model_available(model):
        raise FileNotFoundError("falta el modelo RIFE %s en Python\\plugins64\\models\\rife" % model)
    if impl == 2 and not has_v2(model):
        impl = None

    backend = make_backend(precision, int(cfg.get("streams", 2)), bool(int(cfg.get("cuda_graph", 1))),
                           int(cfg.get("opt_level", 3)))
    ci = color_info(src)
    w0, h0 = src.width, src.height

    if timeline:
        dup, cut, _, _ = analyze_timeline(src, sc_thr, float(cfg.get("dup_mean", 0.0035)),
                                          float(cfg.get("dup_max", 0.10)), cache_key)
        plan = build_timeline(src.num_frames, multi, dup, cut, int(cfg.get("max_gap", 3)),
                              dedup=bool(int(cfg.get("dedup", 1))), smooth=int(cfg.get("smooth", 0)),
                              tail=bool(int(cfg.get("tail", 0))))
        rgb = upscale(to_rgb(src, ci, precision, cfg.get("kernel", "Bicubic")), res_scale)
        rgb, pw, ph = pad_for(rgb, model, impl)
        out = interpolate_timeline(rgb, plan, model, backend, precision, impl, tta)
    else:
        src = scene_detect(src, sc_thr)
        rgb = upscale(to_rgb(src, ci, precision, cfg.get("kernel", "Bicubic")), res_scale)
        rgb, pw, ph = pad_for(rgb, model, impl)
        out = interpolate_standard(rgb, multi, model, backend, impl, tta)

    out = downscale(unpad(out, pw, ph), w0, h0)
    fps = Fraction(src.fps_num, src.fps_den) * Fraction(multi)
    out = core.std.AssumeFPS(out, fpsnum=fps.numerator, fpsden=fps.denominator)
    return out, ci
