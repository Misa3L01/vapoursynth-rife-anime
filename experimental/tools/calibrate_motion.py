"""
calibrate_motion.py - Calibra el guardia de movimiento de la linea de tiempo.

Repartir el movimiento de un dibujo sobre 2-3 frames le pide a RIFE saltos mas
grandes. En movimiento moderado sale mucho mejor que la copia congelada; en
un latigazo (giro de cabeza rapido) RIFE no alcanza y deja un fantasma.

Este script mide VMAF frame por frame de la interpolacion normal y de la linea
de tiempo sobre animacion "en dos" simulada, y lo cruza con el tamano del
salto entre dibujos. El umbral bueno es donde la linea de tiempo deja de ganar.

Uso:  Python\\python.exe experimental\\tools\\calibrate_motion.py <video>
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "vpy"))
sys.path.insert(0, HERE)
import bench  # noqa: E402
import exp_core  # noqa: E402
import vapoursynth as vs  # noqa: E402

core = vs.core
video = os.path.abspath(sys.argv[1])
os.makedirs(bench.WORK, exist_ok=True)

ref = os.path.join(bench.WORK, "ref_%s.mkv" % os.path.splitext(os.path.basename(video))[0])
if not os.path.isfile(ref):
    bench.vspipe_to_ffv1("ref", video, {}, ref)


def per_frame(cfg_name):
    cfg = bench.read_config(cfg_name)
    out = os.path.join(bench.WORK, "pf_%s.mkv" % cfg_name)
    bench.vspipe_to_ffv1("twos", video, cfg, out)
    log = "pf_%s.json" % cfg_name
    subprocess.run([bench.FFMPEG, "-hide_banner", "-loglevel", "error", "-i", out, "-i", ref, "-lavfi",
                    "[0:v][1:v]libvmaf=n_threads=12:log_fmt=json:log_path=%s" % log, "-f", "null", "-"],
                   cwd=bench.WORK, creationflags=bench.NO_WINDOW)
    with open(os.path.join(bench.WORK, log), encoding="utf-8") as fh:
        return [f["metrics"]["vmaf"] for f in json.load(fh)["frames"]]


normal = per_frame("B1_base_426")
aware = per_frame("X1_calidad_48")

# tamano del salto: diferencia entre el dibujo siguiente y el actual, medida
# sobre el mismo clip "en dos" que ve el pipeline
src = exp_core.source(video)
held = core.std.Interleave([src.std.SelectEvery(2, 0)] * 2)[: src.num_frames]
_, cut, means, _ = exp_core.analyze_timeline(held, 0.20, 0.0035, 0.10)

rows = []
for i, (vn, va) in enumerate(zip(normal, aware)):
    k = 2 * i + 1
    if k + 1 >= src.num_frames or cut[k + 1]:
        continue
    rows.append((means[k + 1], vn, va))
rows.sort()

print("salto     | VMAF normal | VMAF linea | diferencia")
for m, vn, va in rows:
    print("%.4f    |   %6.2f    |   %6.2f   |  %+6.2f %s" % (m, vn, va, va - vn, "<-- pierde" if va < vn else ""))

print("\numbral candidato -> VMAF medio si se usa linea de tiempo solo con salto menor al umbral:")
for thr in (0.02, 0.03, 0.04, 0.05, 0.06, 0.08, 0.10, 0.15, 1.0):
    mix = [va if m < thr else vn for m, vn, va in rows]
    print("  %-5s  %.3f   (linea de tiempo en %d de %d frames)" % (
        "sin" if thr == 1.0 else "%.2f" % thr, sum(mix) / len(mix), sum(1 for m, _, _ in rows if m < thr), len(rows)))
