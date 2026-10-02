"""
smoothness.py - Mide la fluidez de la salida interpolada.

Sobre la salida completa (48 o 60 fps) calcula la diferencia entre cada frame
y el siguiente, sin contar los cortes de escena, y reporta:

  congelados  % de frames de salida identicos al anterior. En anime "en dos"
              con interpolacion normal, gran parte de la salida son copias:
              el video avanza a saltos aunque sea de 48 fps.
  copias      % de frames de salida que son copia EXACTA del anterior. La
              columna "congelados" tambien cuenta como congelado un movimiento
              muy lento (menos de FROZEN por frame); esta no. Si una config da
              muchos congelados pero pocas copias, lo que tiene es movimiento
              lento y continuo, no frames quietos.
  tirones     irregularidad del movimiento: promedio de |d(j+1) - d(j)| / d
              medio. Movimiento parejo da un valor bajo; el patron
              quieto-salto-quieto-salto de la animacion en dos da uno alto.
              OJO: d es diferencia de pixeles, que mezcla movimiento con
              nitidez. Un frame interpolado a mitad de camino sale mas blando
              que uno cerca de un dibujo real, y eso tambien cuenta.
  vel. irreg  lo mismo pero con la VELOCIDAD real: el largo medio de los
              vectores de movimiento entre frames consecutivos (MVTools, solo
              para medir). No lo afecta la nitidez. Es la metrica que dice si
              el movimiento avanza parejo.

Uso:
    Python\\python.exe experimental\\tools\\smoothness.py <video> [--twos | --mix] config [config ...]
    --twos  simula animacion "en dos" repitiendo cada frame par.
    --mix       simula animacion "en dos y en tres": los dibujos son los frames
                0, 2, 5, 7, 10... y duran 2, 3, 2, 3. Cada dibujo trae tanto
                movimiento como tiempo dura (el animador ya lo compenso), asi que
                la velocidad YA es pareja: el suavizador de ritmo aca empeora.
    --mix-even  dibujos equiespaciados (frames 0, 2, 4, 6...) que duran 2, 3,
                2, 3. Mismo avance entre dibujos, tiempos distintos: la velocidad
                salta en cada dibujo. Es el caso que ataca el suavizador (SMOOTH).
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "vpy"))
import exp_core  # noqa: E402
import vapoursynth as vs  # noqa: E402

core = vs.core
core.max_cache_size = 1500

FROZEN = 0.0015
CUT = 0.20


def read_config(name):
    cfg = {}
    with open(os.path.join(exp_core.EXP_DIR, "configs", name + ".bat"), encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r'\s*set\s+"EXP_(\w+)=(.*)"\s*$', line)
            if m:
                cfg[m.group(1).lower()] = m.group(2)
    return cfg


def measure(clip):
    g = core.std.ShufflePlanes(clip, 0, vs.GRAY)
    g = core.resize.Bilinear(g, 480, 270, format=vs.GRAY8)
    d = core.std.PlaneStats(g, g[1:] + g[-1])
    diffs = [f.props["PlaneStatsDiff"] for f in d.frames(close=True)][:-1]
    moving = [x for x in diffs if x < CUT]
    frozen = sum(1 for x in moving if x < FROZEN) / max(1, len(moving))
    exact = sum(1 for x in moving if x == 0) / max(1, len(moving))
    mean = sum(moving) / max(1, len(moving))
    jerk = [abs(b - a) for a, b in zip(diffs, diffs[1:]) if a < CUT and b < CUT]

    # velocidad real: largo medio de los vectores de movimiento del frame j-1 al
    # j. mv.Mask(kind=0) pinta cada bloque proporcional al largo de su vector;
    # con ml alto no satura y el promedio es proporcional a la velocidad media.
    sup = core.mv.Super(g, pel=2, sharp=2, rfilter=4)
    vec = core.mv.Analyse(sup, isb=False, delta=1, blksize=16, overlap=8, search=3, truemotion=True)
    vel = core.std.PlaneStats(core.mv.Mask(g, vec, ml=60.0, kind=0))
    v = [f.props["PlaneStatsAverage"] for f in vel.frames(close=True)][1:]   # v[j]: de j a j+1
    vpair = [abs(v[j + 1] - v[j]) for j in range(len(v) - 1) if diffs[j] < CUT and diffs[j + 1] < CUT]
    vmoving = [v[j] for j in range(len(v)) if diffs[j] < CUT]
    vmean = sum(vmoving) / max(1, len(vmoving))
    virreg = (sum(vpair) / max(1, len(vpair))) / vmean if vmean else 0.0

    return (frozen, exact, (sum(jerk) / max(1, len(jerk))) / mean if mean else 0.0, virreg,
            len(diffs) + 1)


def main():
    args = sys.argv[1:]
    video = os.path.abspath(args.pop(0))
    twos = "--twos" in args
    mix = "--mix" in args
    mix_even = "--mix-even" in args
    names = [a for a in args if a not in ("--twos", "--mix", "--mix-even")]
    src = exp_core.source(video)
    label = ""
    if twos:
        src = core.std.Interleave([src.std.SelectEvery(2, 0)] * 2)[: src.num_frames]
        label = "  (simulado en dos)"
    elif mix:
        parts, k, i = [], 0, 0
        while k < src.num_frames:
            g = (2, 3)[i % 2]
            parts.append(src[k] * min(g, src.num_frames - k))
            k += g
            i += 1
        src = core.std.Splice(parts)
        label = "  (simulado en dos y en tres, avance proporcional)"
    elif mix_even:
        parts = [src[k] * (2, 3)[i % 2] for i, k in enumerate(range(0, src.num_frames, 2))]
        src = core.std.Splice(parts)
        label = "  (simulado en dos y en tres, dibujos equiespaciados)"
    print("%s%s" % (os.path.basename(video), label))
    print("%-24s | %-11s | %-9s | %-9s | %-10s | frames"
          % ("config", "congelados", "copias", "tirones", "vel. irreg"))
    for name in names:
        out, ci = exp_core.run(src, read_config(name))
        frozen, exact, jerk, virreg, n = measure(exp_core.to_yuv(out, ci, vs.YUV420P8))
        print("%-24s | %8.1f %%  | %6.1f %%  | %8.3f  | %9.3f  | %d"
              % (name, 100 * frozen, 100 * exact, jerk, virreg, n))


if __name__ == "__main__":
    main()
