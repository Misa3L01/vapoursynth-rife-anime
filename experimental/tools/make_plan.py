"""
make_plan.py - Genera el "plan de interpolacion" que consume el entorno PyTorch.

El plan es una lista de decisiones, una por frame de salida: copiar un frame de
origen, o interpolar entre dos frames con cierta proporcion. Lo calcula el mismo
codigo que usa el pipeline de RIFE (exp_core), asi que los modelos de PyTorch
reciben exactamente las mismas decisiones de corte de escena y de linea de
tiempo. Sin esto, comparar modelos mezclaria diferencias de modelo con
diferencias de logica.

Uso:
    Python\\python.exe experimental\\tools\\make_plan.py <video> <modo> [--timeline] [--multi 2] [--loop 10]

    modo: recon | twos | speed | full
"""
import argparse
import json
import os
import sys
from fractions import Fraction

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "vpy"))
import exp_core  # noqa: E402

KIND = {"recon": "decimated", "twos": "held", "speed": "looped", "full": "plain", "ref": "plain"}
# que frames de la salida se evaluan en cada modo (los que tienen verdad para comparar)
SELECT = {"recon": {"cycle": 2, "offsets": [1]},
          "twos": {"cycle": 4, "offsets": [2]},
          "speed": None, "full": None, "ref": None}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("mode", choices=list(KIND))
    ap.add_argument("--timeline", action="store_true")
    ap.add_argument("--multi", default="2")
    ap.add_argument("--loop", type=int, default=10)
    ap.add_argument("--max-gap", type=int, default=3)
    ap.add_argument("--smooth", type=int, default=0, help="suavizador de ritmo (0 = apagado)")
    ap.add_argument("--tail", type=int, default=0, help="1 = interpolar el final de cada toma")
    ap.add_argument("--sc", type=float, default=0.20)
    ap.add_argument("--dup-mean", type=float, default=0.0035)
    ap.add_argument("--dup-max", type=float, default=0.10)
    ap.add_argument("-o", "--out", default=None)
    a = ap.parse_args()

    video = os.path.abspath(a.video)
    src = exp_core.source(video)
    kind = KIND[a.mode]
    base = exp_core.derive(src, kind, a.loop)

    multi = Fraction(a.multi) if "/" in a.multi else int(a.multi)
    if a.mode in ("recon", "twos"):
        multi = 2  # las pruebas de calidad siempre son x2

    if a.mode == "ref":
        # La verdad para comparar: los frames impares del original, pero pasados
        # por el mismo camino de color que los modelos de PyTorch, para que la
        # comparacion no mida diferencias de conversion.
        dup = cut = []
        plan = [[2 * j + 1, 0, 0.0] for j in range(base.num_frames // 2)]
    else:
        dup, cut, _, _ = exp_core.analyze_timeline(base, a.sc, a.dup_mean, a.dup_max)
        plan = exp_core.build_timeline(base.num_frames, multi, dup, cut, a.max_gap, dedup=a.timeline,
                                       smooth=a.smooth, tail=bool(a.tail))

    data = {
        "video": video, "mode": a.mode, "kind": kind, "multi": str(multi),
        "timeline": bool(a.timeline), "loop": a.loop if kind == "looped" else 1,
        "width": base.width, "height": base.height, "n_src": base.num_frames,
        "fps_num": base.fps_num, "fps_den": base.fps_den,
        "out_fps_num": int(base.fps_num * Fraction(multi).numerator),
        "out_fps_den": int(base.fps_den * Fraction(multi).denominator),
        "select": SELECT[a.mode],
        "n_dup": int(sum(dup)), "n_cut": int(sum(cut)),
        "plan": plan,
    }
    out = a.out or os.path.join(exp_core.EXP_DIR, "cache", "plan_%s_%s%s.json" % (
        os.path.splitext(os.path.basename(video))[0], a.mode, "_tl" if a.timeline else ""))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    n_interp = sum(1 for p in plan if p[2] > 0)
    print("%s  %s  %dx%d  %d frames de origen -> %d de salida (%d interpolados)  %s"
          % (os.path.basename(video), a.mode, base.width, base.height, base.num_frames,
             len(plan), n_interp, out), file=sys.stderr)
    print(out)


if __name__ == "__main__":
    main()
