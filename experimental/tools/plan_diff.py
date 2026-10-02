"""
plan_diff.py - Muestra en que frames la linea de tiempo anime-aware decide algo
distinto que la interpolacion normal, sobre el video real (sin GPU: solo arma
los dos planes y los compara).

Uso:  Python\\python.exe experimental\\tools\\plan_diff.py <video> [multi]
"""
import os
import sys
from fractions import Fraction

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "vpy"))
import exp_core  # noqa: E402

video = os.path.abspath(sys.argv[1])
multi = sys.argv[2] if len(sys.argv) > 2 else "2"
multi = Fraction(multi) if "/" in multi else int(multi)

src = exp_core.source(video)
dup, cut, _, _ = exp_core.analyze_timeline(src, 0.20, 0.0035, 0.10)
std = exp_core.build_timeline(src.num_frames, multi, dup, cut, 3, dedup=False)
ani = exp_core.build_timeline(src.num_frames, multi, dup, cut, 3, dedup=True)

diff = [j for j in range(len(std)) if std[j] != ani[j]]
print("%s  x%s: %d frames de salida, %d repetidos en origen, %d decisiones distintas"
      % (os.path.basename(video), multi, len(std), sum(dup), len(diff)))
for j in diff[:20]:
    print("  salida %4d  normal %-22s  anime-aware %s" % (j, std[j], ani[j]))
