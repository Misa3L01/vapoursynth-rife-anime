"""
bench_mv.py - Mide la interpolacion clasica por vectores de movimiento
(MVTools) con el mismo protocolo, el mismo clip y la misma referencia que se
usaron para RIFE y para los modelos de PyTorch.

MVTools es la familia de SVP y del "TruMotion" de los televisores: no aprende
nada, busca cada bloque de la imagen en el frame siguiente y mueve los pixeles
por el camino encontrado.

Corre en CPU. Esta aca como punto de comparacion medido, no como candidato.

Uso:
    Python\python.exe experimental\tools\bench_mv.py <video> [nombre ...]
"""
import argparse
import csv
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench  # noqa: E402

EXP = os.path.abspath(os.path.join(HERE, ".."))
MV_VPY = os.path.join(EXP, "vpy", "exp_mv.vpy")
WORK = os.path.join(EXP, "results", "work")
CSV = os.path.join(EXP, "results", "bench_mv.csv")
NO_WINDOW = bench.NO_WINDOW

# nombre -> argumentos de exp_mv.vpy
VARIANTS = {
    # control: sin movimiento, en YUV puro. Comparado con el mismo control por
    # la ruta RGB (21.37) dice cuanto cuesta la conversion de color.
    "hold":         dict(METHOD="hold"),
    # lo que hace un televisor barato: mueve bloques enteros
    "block16":      dict(METHOD="block", BLK=16),
    "block8":       dict(METHOD="block", BLK=8),
    # lo que hace SVP: deforma la imagen pixel a pixel siguiendo los vectores
    "flow16":       dict(METHOD="flow", BLK=16),
    "flow8":        dict(METHOD="flow", BLK=8),
    "flow32":       dict(METHOD="flow", BLK=32),
    "flow16_pel4":  dict(METHOD="flow", BLK=16, PEL=4),
    "flow16_nomask": dict(METHOD="flow", BLK=16, MASK=0),
    "flow16_norefine": dict(METHOD="flow", BLK=16, REFINE=0),
    # "mirar 2 frames adelante": vectores calculados al frame de dos lugares
    "flow16_delta2": dict(METHOD="flow", BLK=16, DELTA=2),
}


def run_mode(src, mode, args, out_path, extra=()):
    a = []
    for k, v in args.items():
        a += ["-a", "%s=%s" % (k, v)]
    cmd = [bench.VSPIPE, "-c", "y4m", "-a", "MODE=" + mode, "-a", "SRC=" + src] + a + list(extra)
    cmd += [MV_VPY, "-"]
    p1 = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, creationflags=NO_WINDOW)
    p2 = subprocess.Popen([bench.FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
                           "-f", "yuv4mpegpipe", "-i", "pipe:0", "-c:v", "ffv1", "-level", "3", out_path],
                          stdin=p1.stdout, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                          creationflags=NO_WINDOW)
    p1.stdout.close()
    err = p1.stderr.read().decode("utf-8", "replace")
    p2.wait()
    p1.wait()
    if p1.returncode != 0 or not os.path.isfile(out_path):
        raise RuntimeError(err[-1200:])
    return err


def speed(src, args, loop=10):
    a = []
    for k, v in args.items():
        a += ["-a", "%s=%s" % (k, v)]
    cmd = [bench.VSPIPE, "-a", "MODE=speed", "-a", "LOOP=%d" % loop, "-a", "SRC=" + src] + a
    cmd += [MV_VPY, "--"]
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace",
                       creationflags=NO_WINDOW)
    if r.returncode != 0:
        raise RuntimeError(r.stderr[-1200:])
    m = re.findall(r"Output (\d+) frames in ([\d.]+) seconds \(([\d.]+) fps\)", r.stderr)
    return float(m[-1][2]) if m else float("nan")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("names", nargs="*")
    ap.add_argument("--loop", type=int, default=10)
    ap.add_argument("--tests", default="twos,recon,speed")
    a = ap.parse_args()

    src = os.path.abspath(a.video)
    names = a.names or list(VARIANTS)
    tests = a.tests.split(",")
    os.makedirs(WORK, exist_ok=True)

    ref = os.path.join(WORK, "ref_mv.mkv")
    if not os.path.isfile(ref):
        run_mode(src, "ref", {}, ref)
        print("referencia lista")

    new = not os.path.isfile(CSV)
    fh = open(CSV, "a", newline="", encoding="utf-8")
    wr = csv.writer(fh)
    if new:
        wr.writerow(["fecha", "variante", "twos_vmaf", "twos_psnr", "twos_ssim",
                     "recon_vmaf", "recon_psnr", "recon_ssim", "fps"])
    print("%-18s | %-16s | %-16s | %s" % ("variante", "en dos VMAF", "recon VMAF", "fps"))
    for name in names:
        args = VARIANTS[name]
        row = {"twos": ("", "", ""), "recon": ("", "", "")}
        fps = ""
        try:
            for t in ("twos", "recon"):
                if t in tests:
                    out = os.path.join(WORK, "mv_%s_%s.mkv" % (name, t))
                    run_mode(src, t, args, out)
                    row[t] = bench.metrics(out, ref)
                    os.remove(out)
            if "speed" in tests and name != "hold":
                fps = round(speed(src, args, a.loop), 1)
        except Exception as e:
            print("%-18s ERROR: %s" % (name, str(e).strip().splitlines()[-1][:100]))
            continue

        def f(m):
            return "%6.2f / %5.2f dB" % (m[0], m[1]) if m[0] != "" else "-"
        print("%-18s | %-16s | %-16s | %s" % (name, f(row["twos"]), f(row["recon"]), fps))
        wr.writerow([time.strftime("%Y-%m-%dT%H:%M:%S"), name, *row["twos"], *row["recon"], fps])
        fh.flush()
    fh.close()


if __name__ == "__main__":
    main()
