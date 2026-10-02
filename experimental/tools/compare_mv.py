"""
compare_mv.py - Imagen comparativa de un mismo frame reconstruido por el metodo
clasico (MVTools) y por RIFE, contra el original.

Uso:
    Python\python.exe experimental\tools\compare_mv.py <video> [indice]

El indice es sobre el modo "recon": el frame N de recon reconstruye el frame
impar 2N+1 del original.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench  # noqa: E402

EXP = os.path.abspath(os.path.join(HERE, ".."))
WORK = os.path.join(EXP, "results", "work")
NO_WINDOW = bench.NO_WINDOW


def grab(vpy, mode, src, idx, out_png, args=(), env=None):
    """Saca un frame suelto como PNG."""
    cmd = [bench.VSPIPE, "-c", "y4m", "-a", "MODE=" + mode, "-a", "SRC=" + src,
           "-s", str(idx), "-e", str(idx)] + list(args) + [vpy, "-"]
    p1 = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          env=dict(os.environ, **(env or {})), creationflags=NO_WINDOW)
    p2 = subprocess.Popen([bench.FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
                           "-f", "yuv4mpegpipe", "-i", "pipe:0", "-frames:v", "1", out_png],
                          stdin=p1.stdout, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                          creationflags=NO_WINDOW)
    p1.stdout.close()
    err = p1.stderr.read().decode("utf-8", "replace")
    p2.wait()
    p1.wait()
    if not os.path.isfile(out_png):
        raise RuntimeError(err[-900:])


def main():
    src = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(EXP, "..", "videos", "salida.mp4"))
    idx = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    os.makedirs(WORK, exist_ok=True)
    mv_vpy = os.path.join(EXP, "vpy", "exp_mv.vpy")
    bn_vpy = os.path.join(EXP, "vpy", "exp_bench.vpy")

    paths = []
    for tag, vpy, mode, args, env in [
        ("original", mv_vpy, "ref", (), None),
        ("mvtools", mv_vpy, "recon", ("-a", "METHOD=flow", "-a", "BLK=16", "-a", "PEL=4"), None),
        ("rife426", bn_vpy, "recon", (), {"EXP_MODEL": "426", "EXP_IMPL": "0"}),
    ]:
        png = os.path.join(WORK, "cmp_%s.png" % tag)
        grab(vpy, mode, src, idx, png, args, env)
        paths.append((tag, png))
        print("  ", tag, "ok")

    labels = {"original": "ORIGINAL (verdad)", "mvtools": "MVTOOLS flow 16 pel4",
              "rife426": "RIFE 4.26"}
    out = os.path.join(EXP, "results", "mvtools_vs_rife.png")
    ins = []
    for _, p in paths:
        ins += ["-i", p]
    # una fila de tres, cada una con su etiqueta arriba
    filt = []
    for i, (tag, _) in enumerate(paths):
        filt.append("[%d:v]drawtext=text='%s':x=14:y=12:fontsize=30:fontcolor=white:"
                    "box=1:boxcolor=black@0.65:boxborderw=8[v%d]" % (i, labels[tag], i))
    filt.append("[v0][v1][v2]hstack=inputs=3[out]")
    cmd = [bench.FFMPEG, "-hide_banner", "-loglevel", "error", "-y"] + ins + \
          ["-filter_complex", ";".join(filt), "-map", "[out]", "-frames:v", "1", out]
    r = subprocess.run(cmd, capture_output=True, text=True, creationflags=NO_WINDOW)
    if r.returncode != 0:
        raise RuntimeError(r.stderr[-900:])
    for _, p in paths:
        os.remove(p)
    print("->", out)


if __name__ == "__main__":
    main()
