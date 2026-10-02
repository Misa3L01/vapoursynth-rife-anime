"""
calibrate_dupes.py - Muestra las metricas de "frame repetido" de un video, para
elegir umbrales con datos en vez de a ojo.

Uso:  Python\\python.exe experimental\\tools\\calibrate_dupes.py <video>
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "vpy"))
import exp_core  # noqa: E402
import vapoursynth as vs  # noqa: E402

core = vs.core
path = sys.argv[1]
lwi = os.path.join(exp_core.ROOT, "cache", "lwi", os.path.basename(path) + ".%d.lwi" % os.path.getsize(path))
src = core.lsmas.LWLibavSource(source=path, cachefile=lwi)
dup, cut, means, maxs = exp_core.analyze_timeline(src, 0.20, 0.0035, 0.10, cache_key=None)

rows = sorted(range(1, len(means)), key=lambda i: means[i])
print("frame |  media   |  maximo  | corte | repetido")
for i in rows[:30]:
    print("%5d | %.5f | %.5f |  %s   |   %s" % (i, means[i], maxs[i], "X" if cut[i] else " ", "SI" if dup[i] else ""))
print("...")
print("mayores medias:", ["%.3f" % means[i] for i in rows[-5:]])
print("total repetidos con umbral actual: %d de %d" % (sum(dup), len(dup)))
