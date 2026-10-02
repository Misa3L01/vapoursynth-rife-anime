"""
render_torch.py - Renderiza un video completo con los modelos del entorno
PyTorch (GMFSS, AMT, EMA-VFI), con el mismo tratamiento que produccion:
misma conversion de color, misma deteccion de cortes, misma linea de tiempo
anime-aware, mismo encoder NVENC y el mismo mux de audio, subtitulos,
tipografias y capitulos.

La cadena es:
    vspipe (VapourSynth)  ->  runner.py (PyTorch/CUDA)  ->  ffmpeg (NVENC)  ->  mux

Uso:
    Python\\python.exe experimental\\tools\\render_torch.py <video> [video ...]
        [--model gmfss_u] [--scale 1.0] [--multi 2] [--no-timeline] [--cq 20]

Ojo con los tiempos: GMFSS a escala 1.0 anda a ~1.4 fps de salida, o sea unas
5.7 horas por cada 10 minutos de video. Es para archivar, no para una cola.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench  # noqa: E402
import bench_torch as bt  # noqa: E402

NO_WINDOW = bt.NO_WINDOW

# Escala interna del flujo por modelo, medida en esta GPU de 6 GB:
# GMFSS entra a escala completa y ahi rinde bastante mejor (+0.9 VMAF).
# AMT y EMA-VFI se quedan sin memoria a 1080p con escala completa.
DEFAULT_SCALE = {"gmfss_u": 1.0, "amt_g": 0.5, "amt_l": 0.5, "amt_s": 0.5,
                 "ema": 0.5, "ema_small": 0.5, "gimm": 0.5, "gimm_lpips": 0.5,
                 "hold": 1.0, "blend": 1.0}


def probe_color(video):
    r = subprocess.run([bench.FFMPEG.replace("ffmpeg.exe", "ffprobe.exe"), "-v", "error",
                        "-select_streams", "v:0", "-show_entries",
                        "stream=color_space,color_primaries,color_transfer,color_range",
                        "-of", "default=nw=1", video], capture_output=True, text=True,
                       creationflags=NO_WINDOW).stdout
    c = {"color_space": "bt709", "color_primaries": "bt709", "color_transfer": "bt709", "color_range": "tv"}
    for line in r.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            if v.strip() and v.strip() != "unknown" and k in c:
                c[k] = v.strip()
    return c


def duration(video):
    r = subprocess.run([bench.FFMPEG.replace("ffmpeg.exe", "ffprobe.exe"), "-v", "error",
                        "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", video],
                       capture_output=True, text=True, creationflags=NO_WINDOW).stdout.strip()
    try:
        return float(r)
    except ValueError:
        return 0.0


def read_config(name):
    """Lee los ajustes de la linea de tiempo de una config de experimental\\configs,
    para combinar cualquier modelo de PyTorch con cualquier metodo (D2, D4...)."""
    path = os.path.join(bt.EXP, "configs", name + ".bat")
    if not os.path.isfile(path):
        raise SystemExit("No existe la config %s" % path)
    cfg = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r'\s*set\s+"EXP_(\w+)=(.*)"\s*$', line)
            if m:
                cfg[m.group(1).lower()] = m.group(2)
    return cfg


def render(video, model, scale, multi, timeline, cq, out_dir, suffix, plan_opts=None):
    os.makedirs(out_dir, exist_ok=True)
    name = os.path.splitext(os.path.basename(video))[0]
    tmp = os.path.join(bt.WORK, name + suffix + ".video.mkv")
    out = os.path.join(out_dir, name + suffix + ".mkv")
    os.makedirs(bt.WORK, exist_ok=True)

    print("[1/4] Analizando el video y armando el plan...")
    plan_path = bt.make_plan(video, "full", timeline=timeline, multi=multi, **(plan_opts or {}))
    with open(plan_path, encoding="utf-8") as fh:
        plan = json.load(fh)
    w, h = plan["width"], plan["height"]
    fps = "%d/%d" % (plan["out_fps_num"], plan["out_fps_den"])
    n_out = len(plan["plan"])
    col = probe_color(video)
    print("    %d frames de salida a %s fps | %d repetidos, %d cortes | color %s/%s"
          % (n_out, fps, plan["n_dup"], plan["n_cut"], col["color_space"], col["color_range"]))

    print("[2/4] Interpolando con %s (scale %.2f)..." % (model, scale))
    vs_cmd = [bench.VSPIPE, "-a", "MODE=rgbsrc", "-a", "SRC=" + video, "-a", "KIND=plain",
              bt.BENCH_VPY, "-"]
    run_cmd = [bt.TORCH_PY, bt.RUNNER, "--plan", plan_path, "--model", model, "--scale", str(scale),
               "--stats", os.path.join(bt.WORK, "render_stats.json")]
    ff_cmd = [bench.FFMPEG, "-hide_banner", "-loglevel", "warning", "-stats", "-y",
              "-f", "rawvideo", "-pix_fmt", "rgb48le", "-s", "%dx%d" % (w, h), "-r", fps, "-i", "pipe:0",
              "-vf", "zscale=m=%s:r=%s:d=error_diffusion:f=bicubic,format=yuv420p10le"
              % ("709" if col["color_space"] == "bt709" else col["color_space"],
                 "limited" if col["color_range"] == "tv" else "full"),
              "-c:v", "hevc_nvenc", "-preset", "p7", "-tune", "hq", "-rc", "vbr", "-cq", str(cq),
              "-b:v", "0", "-spatial-aq", "1", "-temporal-aq", "1", "-rc-lookahead", "32",
              "-bf", "4", "-b_ref_mode", "middle", "-g", "240", "-pix_fmt", "p010le",
              "-colorspace", col["color_space"], "-color_primaries", col["color_primaries"],
              "-color_trc", col["color_transfer"], "-color_range", col["color_range"],
              "-fps_mode", "passthrough", tmp]

    env = dict(os.environ, **bt.TORCH_ENV)
    t0 = time.time()
    p1 = subprocess.Popen(vs_cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, creationflags=NO_WINDOW)
    p2 = subprocess.Popen(run_cmd, stdin=p1.stdout, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          env=env, creationflags=NO_WINDOW)
    p3 = subprocess.Popen(ff_cmd, stdin=p2.stdout, creationflags=NO_WINDOW)
    p1.stdout.close()
    p2.stdout.close()
    err2 = p2.stderr.read().decode("utf-8", "replace")
    p3.wait()
    p2.wait()
    p1.kill()
    dt = time.time() - t0
    if p2.returncode != 0 or p3.returncode != 0 or not os.path.isfile(tmp):
        print("[X] Fallo el render:\n" + err2[-1200:])
        return False

    print("[3/4] Validando...")
    d_src, d_out = duration(video), duration(tmp)
    if d_src > 0 and abs(d_src - d_out) > 2:
        print("[X] Render truncado: fuente %.1fs vs salida %.1fs" % (d_src, d_out))
        os.remove(tmp)
        return False

    print("[4/4] Muxeando audio, subtitulos y capitulos...")
    mux = [bench.FFMPEG, "-hide_banner", "-loglevel", "warning", "-y", "-i", tmp, "-i", video,
           "-map", "0:v:0", "-map", "1:a?", "-map", "1:s?", "-map", "1:t?",
           "-map_chapters", "1", "-map_metadata", "1",
           "-c:v", "copy", "-c:a", "copy", "-c:s", "copy",
           "-colorspace", col["color_space"], "-color_primaries", col["color_primaries"],
           "-color_trc", col["color_transfer"], "-color_range", col["color_range"],
           "-max_interleave_delta", "0", out]
    if subprocess.run(mux, creationflags=NO_WINDOW).returncode != 0:
        print("[X] Fallo el muxing")
        return False
    os.remove(tmp)

    rt = d_src / dt if dt else 0
    print("[OK] %s  |  %s de video en %s  (x%.3f tiempo real)"
          % (os.path.basename(out), _hms(d_src), _hms(dt), rt))
    return True


def _hms(s):
    s = int(s)
    return "%d:%02d:%02d" % (s // 3600, (s % 3600) // 60, s % 60) if s >= 3600 else "%d:%02d" % (s // 60, s % 60)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("videos", nargs="*")
    ap.add_argument("--model", default="gmfss_u")
    ap.add_argument("--scale", type=float, default=None)
    ap.add_argument("--multi", default="2")
    ap.add_argument("--no-timeline", dest="timeline", action="store_false")
    ap.add_argument("--cq", type=int, default=20)
    ap.add_argument("--out", default=None)
    ap.add_argument("--suffix", default=None)
    ap.add_argument("--config", default=None,
                    help="toma multi y la linea de tiempo de una config (ej: D4_ritmo_60)")
    a = ap.parse_args()

    if a.scale is None:
        a.scale = DEFAULT_SCALE.get(a.model, 0.5)
    plan_opts = {}
    tag = ""
    if a.config:
        c = read_config(a.config)
        a.multi = c.get("multi", a.multi)
        a.timeline = c.get("timeline", "1") == "1"
        plan_opts = {"max_gap": c.get("max_gap"), "smooth": c.get("smooth"), "tail": c.get("tail"),
                     "sc": c.get("sc_threshold"), "dup_mean": c.get("dup_mean"), "dup_max": c.get("dup_max")}
        tag = c.get("suffix", "-" + a.config)
    videos = a.videos
    if not videos:
        import glob
        vdir = os.path.join(os.path.dirname(bt.EXP), "videos")
        videos = sorted(glob.glob(os.path.join(vdir, "*.mkv")) + glob.glob(os.path.join(vdir, "*.mp4")))
        if not videos:
            print("No hay videos en", vdir)
            return 1
    out_dir = a.out or os.path.join(bt.EXP, "output")
    suffix = a.suffix or ("-" + a.model + tag)
    ok = fail = 0
    for v in videos:
        v = os.path.abspath(v)
        print("\n" + "=" * 60)
        print("  %s  ->  %s  (scale %.2f, multi %s%s%s)"
              % (os.path.basename(v), a.model, a.scale, a.multi, ", linea de tiempo" if a.timeline else "",
                 ", metodo " + a.config if a.config else ""))
        print("=" * 60)
        if render(v, a.model, a.scale, a.multi, a.timeline, a.cq, out_dir, suffix, plan_opts):
            ok += 1
        else:
            fail += 1
    print("\nListos: %d   fallidos: %d" % (ok, fail))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
