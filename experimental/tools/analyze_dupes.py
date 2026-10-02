"""
analyze_dupes.py - Mide cuanto de un video son frames repetidos.

El anime suele animarse "en dos" o "en tres": cada dibujo se mantiene 2 o 3
frames a 24 fps. Si RIFE interpola frame a frame, entre dos frames iguales no
hay movimiento que inventar, y todo el movimiento se concentra en un solo
intervalo: la salida de 48 fps avanza a los saltos. Este script dice cuanto
pesa ese problema en una fuente concreta.

Uso:
    Python\\python.exe experimental\\tools\\analyze_dupes.py <video> [frames]
"""
import os
import sys

import vapoursynth as vs

core = vs.core
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

DUP_THR = 0.0035   # diferencia media por debajo de esto = mismo dibujo
CUT_THR = 0.20     # el mismo umbral de corte que usa produccion


def analyze(path, max_frames=1500):
    lwi = os.path.join(ROOT, "cache", "lwi", os.path.basename(path) + ".%d.lwi" % os.path.getsize(path))
    clip = core.lsmas.LWLibavSource(source=path, cachefile=lwi)
    n = min(clip.num_frames - 1, max_frames)
    g = core.std.ShufflePlanes(clip, 0, vs.GRAY)
    g = core.resize.Bilinear(g, 480, 270, format=vs.GRAY8)
    diff = core.std.PlaneStats(g, g[1:] + g[-1])
    vals = [diff.get_frame(i).props["PlaneStatsDiff"] for i in range(n)]

    dup = sum(1 for v in vals if v < DUP_THR)
    cut = sum(1 for v in vals if v > CUT_THR)

    # largo de las corridas de duplicados: 1 = "en dos", 2 = "en tres", etc.
    runs, r = {}, 0
    for v in vals:
        if v < DUP_THR:
            r += 1
        else:
            if r:
                runs[r] = runs.get(r, 0) + 1
            r = 0
    return n, dup, cut, runs


if __name__ == "__main__":
    targets = sys.argv[1:2] or [
        os.path.join(ROOT, "videos", f) for f in sorted(os.listdir(os.path.join(ROOT, "videos")))
        if f.lower().endswith((".mkv", ".mp4"))
    ]
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 1500
    for t in targets:
        n, dup, cut, runs = analyze(t, limit)
        top = ", ".join("%d:%d" % kv for kv in sorted(runs.items(), key=lambda kv: -kv[1])[:4])
        print("%-26s | %5d pares | duplicados %5.1f %% | cortes %3d | corridas largo:veces  %s"
              % (os.path.basename(t)[:26], n, 100.0 * dup / n, cut, top))
