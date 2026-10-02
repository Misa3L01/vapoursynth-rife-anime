"""
bench_torch.py - Mide los modelos del entorno PyTorch con el mismo protocolo
que se uso para RIFE.

La cadena es:

  vspipe (VapourSynth de produccion)  ->  runner.py (entorno PyTorch)  ->  ffmpeg
  frames RGB fp16, misma conversion       ejecuta el modelo segun          a YUV con zimg,
  de color que usa RIFE                   el plan (cortes, linea            la misma libreria
                                          de tiempo)                        que VapourSynth

Asi la unica diferencia entre modelos es el modelo. El control "hold" repite el
frame anterior: en la prueba "en dos" tiene que dar el mismo VMAF que RIFE
normal (21.36), porque ahi RIFE tambien produce copias. Si coincide, el puente
entre los dos entornos no esta cambiando nada.

Uso:
    Python\\python.exe experimental\\tools\\bench_torch.py <video> <modelo> [modelo ...]
    Python\\python.exe experimental\\tools\\bench_torch.py <video> gmfss_u --scale 0.5 --tests twos,recon,speed
"""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench  # noqa: E402  (reusa metrics(), rutas y VramSampler)

EXP = bench.ROOT and os.path.join(os.path.dirname(bench.ROOT), "") or None
EXP = os.path.abspath(os.path.join(HERE, ".."))
TORCH_PY = os.path.join(EXP, "torch-env", "venv", "Scripts", "python.exe")
RUNNER = os.path.join(EXP, "torch-env", "vfi", "runner.py")
BENCH_VPY = os.path.join(EXP, "vpy", "exp_bench.vpy")
WORK = os.path.join(EXP, "results", "work")
CSV = os.path.join(EXP, "results", "bench_torch.csv")
NO_WINDOW = 0x08000000

TORCH_ENV = {
    "PYTORCH_CUDA_ALLOC_CONF": "expandable_segments:True",
    # Para que GMFSS use el kernel CUDA original de softsplat (via CuPy) en vez
    # de su implementacion alternativa.
    "CUDA_PATH": os.path.join(EXP, "torch-env", "venv", "Lib", "site-packages", "nvidia", "cuda_runtime"),
}


def make_plan(video, mode, timeline=False, multi="2", loop=10, **opts):
    """opts: max_gap, smooth, tail, sc, dup_mean, dup_max (los mismos ajustes de la
    linea de tiempo que usan las configs de experimental\\configs)."""
    cmd = [os.path.join(bench.ROOT, "Python", "python.exe"), os.path.join(HERE, "make_plan.py"),
           video, mode, "--multi", str(multi), "--loop", str(loop)]
    if timeline:
        cmd.append("--timeline")
    for k, v in opts.items():
        if v is not None:
            cmd += ["--" + k.replace("_", "-"), str(v)]
    r = subprocess.run(cmd, capture_output=True, text=True, creationflags=NO_WINDOW)
    if r.returncode != 0:
        raise RuntimeError("make_plan fallo: " + r.stderr[-800:])
    return r.stdout.strip().splitlines()[-1]


def run_chain(video, plan_path, model, scale, out_path, stats_path, limit=0, discard=False):
    """discard=True descarta la salida en vez de guardarla. Para medir velocidad:
    si se guarda, el tiempo incluye comprimir 1.5 GB a disco y el modelo queda
    esperando al compresor, lo que no pasa en el render real ni en la medicion
    de RIFE."""
    with open(plan_path, encoding="utf-8") as fh:
        plan = json.load(fh)
    w, h = plan["width"], plan["height"]
    # Velocidad fija para los archivos de medicion: ffmpeg alinea los dos videos
    # por marca de tiempo, no por numero de frame. El clip diezmado del modo
    # recon corre a la mitad de fps, asi que con la velocidad "real" cada frame
    # terminaba comparado contra otro que no le correspondia.
    fps = "24"

    # sin -c: salida cruda (los tres planos RGB fp16, uno atras del otro)
    vs_cmd = [bench.VSPIPE, "-a", "MODE=rgbsrc", "-a", "SRC=" + video,
              "-a", "KIND=" + plan["kind"], "-a", "LOOP=%d" % plan.get("loop", 1), BENCH_VPY, "-"]
    run_cmd = [TORCH_PY, RUNNER, "--plan", plan_path, "--model", model,
               "--scale", str(scale), "--stats", stats_path]
    if limit:
        run_cmd += ["--limit", str(limit)]
    ff_cmd = [bench.FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
              "-f", "rawvideo", "-pix_fmt", "rgb48le", "-s", "%dx%d" % (w, h), "-r", fps,
              "-i", "pipe:0",
              # zimg, igual que VapourSynth, para no mezclar diferencias de color
              "-vf", "zscale=m=709:r=limited:d=error_diffusion:f=bicubic,format=yuv420p",
              "-c:v", "ffv1", "-level", "3", out_path]

    env = dict(os.environ, **TORCH_ENV)
    p1 = subprocess.Popen(vs_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, creationflags=NO_WINDOW)
    p2 = subprocess.Popen(run_cmd, stdin=p1.stdout,
                          stdout=subprocess.DEVNULL if discard else subprocess.PIPE,
                          stderr=subprocess.PIPE, env=env, creationflags=NO_WINDOW)
    p3 = None
    if not discard:
        p3 = subprocess.Popen(ff_cmd, stdin=p2.stdout, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                              creationflags=NO_WINDOW)
    p1.stdout.close()
    if p2.stdout:
        p2.stdout.close()
    err2 = p2.stderr.read().decode("utf-8", "replace")
    err3 = ""
    if p3:
        err3 = p3.stderr.read().decode("utf-8", "replace")
        p3.wait()
    p2.wait()
    p1.kill()
    if p3 and p3.returncode != 0:
        raise RuntimeError("%s: ffmpeg fallo:\n%s" % (model, err3[-1200:]))
    if p2.returncode != 0 or (not discard and not os.path.isfile(out_path)):
        err1 = p1.stderr.read().decode("utf-8", "replace") if p1.stderr else ""
        err3 = p3.stderr.read().decode("utf-8", "replace") if p3.stderr else ""
        raise RuntimeError("%s fallo:\n-- vspipe --\n%s\n-- runner --\n%s\n-- ffmpeg --\n%s"
                           % (model, err1[-700:], err2[-900:], err3[-400:]))
    return err2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("models", nargs="+")
    ap.add_argument("--scale", type=float, default=0.5)
    ap.add_argument("--tests", default="twos,recon,speed")
    ap.add_argument("--speed-frames", type=int, default=120, help="frames de salida a medir en la prueba de velocidad")
    a = ap.parse_args()

    video = os.path.abspath(a.video)
    tests = a.tests.split(",")
    os.makedirs(WORK, exist_ok=True)

    # referencia por el mismo camino de color que los modelos
    ref = os.path.join(WORK, "ref_torch.mkv")
    if not os.path.isfile(ref):
        plan_ref = make_plan(video, "ref")
        run_chain(video, plan_ref, "hold", 1.0, ref, os.path.join(WORK, "ref_stats.json"))
        print("referencia lista:", ref)

    plans = {}
    for t in tests:
        if t == "twos":
            # con linea de tiempo: si no, el plan pide copias y todos los
            # modelos dan el mismo resultado (no se mide nada)
            plans[t] = make_plan(video, t, timeline=True)
        elif t == "recon":
            plans[t] = make_plan(video, t)
        elif t == "speed":
            plans[t] = make_plan(video, "speed", loop=1)

    new = not os.path.isfile(CSV)
    with open(CSV, "a", newline="", encoding="utf-8") as fh:
        import csv
        wr = csv.writer(fh)
        if new:
            wr.writerow(["fecha", "modelo", "scale", "video", "twos_vmaf", "twos_psnr", "twos_ssim",
                         "recon_vmaf", "recon_psnr", "recon_ssim", "fps_interp", "seg_por_10s_x2",
                         "vram_mb"])
        print("%-10s %-5s | %-21s | %-21s | %s" % ("modelo", "scale", "en dos VMAF/PSNR", "recon VMAF/PSNR", "velocidad"))
        for model in a.models:
            row = {"twos": ("", "", ""), "recon": ("", "", "")}
            speed = ("", "", "")
            try:
                for t in ("twos", "recon"):
                    if t in tests:
                        out = os.path.join(WORK, "t_%s_%s.mkv" % (model, t))
                        run_chain(video, plans[t], model, a.scale, out,
                                  os.path.join(WORK, "stats_%s_%s.json" % (model, t)))
                        row[t] = bench.metrics(out, ref)
                        os.remove(out)
                if "speed" in tests:
                    out = os.path.join(WORK, "s_%s.mkv" % model)
                    sp = os.path.join(WORK, "stats_%s_speed.json" % model)
                    run_chain(video, plans["speed"], model, a.scale, out, sp,
                              limit=a.speed_frames, discard=True)
                    with open(sp, encoding="utf-8") as fhs:
                        st = json.load(fhs)
                    if os.path.isfile(out):
                        os.remove(out)
                    # fps de salida x2 = 2 x los frames interpolados por segundo
                    fps_out = st["fps"]
                    speed = (round(fps_out, 2), round(10 * 47.952 / fps_out) if fps_out else 0, st["vram_pico_mb"])
            except Exception as e:
                print("%-10s ERROR: %s" % (model, str(e).strip().splitlines()[-1][:110]))
                continue

            def f(m):
                return "%6.2f / %5.2f dB" % (m[0], m[1]) if m[0] != "" else "-"
            sp_txt = "%5.1f fps de salida  %4s s/10s  VRAM %s MB" % speed if speed[0] != "" else "-"
            print("%-10s %-5.2f | %-21s | %-21s | %s" % (model, a.scale, f(row["twos"]), f(row["recon"]), sp_txt))
            wr.writerow([time.strftime("%Y-%m-%dT%H:%M:%S"), model, a.scale, os.path.basename(video),
                         *row["twos"], *row["recon"], *speed])
            fh.flush()


if __name__ == "__main__":
    main()
