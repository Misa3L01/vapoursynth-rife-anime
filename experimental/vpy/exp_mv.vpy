r"""
exp_mv.vpy - Banco de pruebas para interpolacion clasica por vectores de
movimiento (MVTools), la familia a la que pertenecen SVP y el "TruMotion" de
los televisores.

Es un metodo distinto al de las redes neuronales: en vez de aprender como se
ve un frame intermedio, parte la imagen en bloques, busca cada bloque en el
frame siguiente y mueve los pixeles por el camino encontrado.

OJO: MVTools corre en CPU. Esta aca como punto de comparacion medido, no como
candidato para produccion.

Parametros (via vspipe -a):
  MODE     ref | recon | twos | speed   (mismos modos que exp_bench.vpy)
  METHOD   flow  -> mv.FlowFPS   (warp por pixel, lo que hace SVP)
           block -> mv.BlockFPS  (mueve bloques enteros, lo que hace una TV barata)
  BLK      tamano de bloque (16 default, 8 = mas fino y mas lento)
  PEL      precision subpixel: 1 = pixel entero, 2 = medio, 4 = cuarto
  SEARCH   tipo de busqueda de MVTools (3 = exhaustiva, la habitual)
  MASK     enmascarado de artefactos en FlowFPS (0..2)
  ML       limite de movimiento: cuanto se permite deformar antes de rendirse
  REFINE   1 = segunda pasada con bloques de la mitad (lo que SVP llama refine)
  DELTA    a cuantos frames de distancia se calculan los vectores (1 = al
           frame de al lado). Es la palanca de "mirar 2 o 3 frames adelante".
"""
import os
import sys

_HERE = os.getcwd() if os.path.isfile(os.path.basename(__file__)) else os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
import exp_core  # noqa: E402
import vapoursynth as vs  # noqa: E402

core = vs.core
core.max_cache_size = 1500

MODE = globals().get("MODE", "recon")
SRC = globals().get("SRC") or os.environ.get("SRC")
METHOD = globals().get("METHOD", "flow")
BLK = int(globals().get("BLK", 16))
PEL = int(globals().get("PEL", 2))
SEARCH = int(globals().get("SEARCH", 3))
MASK = int(globals().get("MASK", 2))
ML = float(globals().get("ML", 100))
REFINE = int(globals().get("REFINE", 1))
DELTA = int(globals().get("DELTA", 1))
LOOP = int(globals().get("LOOP", 10))

src = exp_core.source(SRC)
src8 = core.resize.Bicubic(src, format=vs.YUV420P8)


def interp2x(clip):
    """Duplica la tasa de frames con vectores de movimiento."""
    if METHOD == "hold":
        # Control: repite el frame anterior, sin movimiento. Sirve para medir
        # cuanto cuesta el viaje de color YUV->RGB->YUV que si hacen RIFE y los
        # modelos de PyTorch, y que esta ruta en YUV puro se ahorra.
        return core.std.Interleave([clip, clip])
    overlap = BLK // 2
    sup = core.mv.Super(clip, pel=PEL, sharp=2, rfilter=4)
    bv = core.mv.Analyse(sup, isb=True, delta=DELTA, blksize=BLK, overlap=overlap,
                         search=SEARCH, dct=0)
    fv = core.mv.Analyse(sup, isb=False, delta=DELTA, blksize=BLK, overlap=overlap,
                         search=SEARCH, dct=0)
    if REFINE and BLK > 8:
        half = BLK // 2
        bv = core.mv.Recalculate(sup, bv, blksize=half, overlap=half // 2, thsad=100, search=SEARCH)
        fv = core.mv.Recalculate(sup, fv, blksize=half, overlap=half // 2, thsad=100, search=SEARCH)
    num = clip.fps.numerator * 2
    den = clip.fps.denominator
    if METHOD == "block":
        return core.mv.BlockFPS(clip, sup, bv, fv, num=num, den=den, mode=3,
                                thscd1=140, thscd2=112)
    return core.mv.FlowFPS(clip, sup, bv, fv, num=num, den=den, mask=MASK, ml=ML,
                           thscd1=140, thscd2=112)


if MODE == "ref":
    out = src8.std.SelectEvery(2, 1)

elif MODE == "recon":
    half = src8.std.SelectEvery(2, 0)
    out = interp2x(half).std.SelectEvery(2, 1)

elif MODE == "twos":
    held = core.std.Interleave([src8.std.SelectEvery(2, 0)] * 2)[: src8.num_frames]
    out = interp2x(held).std.SelectEvery(4, 2)

elif MODE == "speed":
    out = interp2x(src8 * LOOP)

elif MODE == "full":
    out = interp2x(src8)

else:
    raise ValueError("MODE desconocido: %r" % MODE)

out.set_output()
