"""
bench.py - Mide calidad, velocidad sostenida y VRAM de las configuraciones de
experimental\\configs\\.

Uso:
    Python\\python.exe experimental\\tools\\bench.py [video] [config ...]
    (sin configs: todas; sin video: el primero de videos\\)

Pruebas por configuracion:
  recon   VMAF / PSNR / SSIM reconstruyendo frames borrados (calidad pura).
  twos    lo mismo pero con animacion "en dos" simulada (fluidez en anime).
  speed   fps sostenidos con el clip en bucle, y pico de VRAM.

Resultados: experimental\\results\\bench.csv (se agrega una fila por corrida).
"""
import csv
import datetime
import glob
import os
import re
import subprocess
import sys
import threading
import time

EXP = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ROOT = os.path.abspath(os.path.join(EXP, ".."))
VSPIPE = os.path.join(ROOT, "Python", "Scripts", "vspipe.exe")
FFMPEG = os.path.join(ROOT, "ffmpeg", "bin", "ffmpeg.exe")
BENCH_VPY = os.path.join(EXP, "vpy", "exp_bench.vpy")
WORK = os.path.join(EXP, "results", "work")
CSV = os.path.join(EXP, "results", "bench.csv")
NO_WINDOW = 0x08000000


def read_config(name):
    path = os.path.join(EXP, "configs", name + ".bat")
    cfg = {}
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r'\s*set\s+"(EXP_\w+)=(.*)"\s*$', line)
            if m:
                cfg[m.group(1)] = m.group(2)
    return cfg


def vspipe_to_ffv1(mode, src, env_cfg, out_path):
    env = dict(os.environ, **env_cfg)
    p1 = subprocess.Popen([VSPIPE, "-c", "y4m", "-a", "MODE=" + mode, "-a", "SRC=" + src, BENCH_VPY, "-"],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, creationflags=NO_WINDOW)
    p2 = subprocess.Popen([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-f", "yuv4mpegpipe",
                           "-i", "pipe:0", "-c:v", "ffv1", "-level", "3", out_path],
                          stdin=p1.stdout, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                          creationflags=NO_WINDOW)
    p1.stdout.close()
    err1 = p1.stderr.read().decode("utf-8", "replace")
    p2.wait()
    p1.wait()
    if p1.returncode != 0 or not os.path.isfile(out_path):
        raise RuntimeError("vspipe %s fallo:\n%s" % (mode, err1[-1500:]))


def metrics(test, ref):
    def run(filt, pattern):
        r = subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "info", "-i", test, "-i", ref,
                            "-lavfi", "[0:v][1:v]" + filt, "-f", "null", "-"],
                           capture_output=True, text=True, encoding="utf-8", errors="replace",
                           creationflags=NO_WINDOW)
        m = re.findall(pattern, r.stderr)
        return float(m[-1]) if m else float("nan")
    return (run("libvmaf=n_threads=12", r"VMAF score: ([\d.]+)"),
            run("psnr", r"average:([\d.]+)"),
            run("ssim", r"All:([\d.]+)"))


class VramSampler(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.peak = 0
        self.stop = False

    def run(self):
        while not self.stop:
            try:
                r = subprocess.run(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
                                   capture_output=True, text=True, creationflags=NO_WINDOW)
                self.peak = max(self.peak, int(r.stdout.strip().splitlines()[0]))
            except Exception:
                pass
            time.sleep(0.4)


def vram_used():
    r = subprocess.run(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
                       capture_output=True, text=True, creationflags=NO_WINDOW)
    return int(r.stdout.strip().splitlines()[0])


def speed(src, env_cfg, loop=10):
    env = dict(os.environ, **env_cfg)
    # calentamiento: compila el engine si hace falta, y no cuenta para la medicion
    t0 = time.time()
    w = subprocess.run([VSPIPE, "-a", "MODE=speed", "-a", "LOOP=1", "-a", "SRC=" + src, "-e", "3", BENCH_VPY, "--"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace", env=env,
                       creationflags=NO_WINDOW)
    build = time.time() - t0
    if w.returncode != 0:
        raise RuntimeError("calentamiento fallo:\n" + w.stderr[-1500:])
    time.sleep(2)
    base = vram_used()
    sampler = VramSampler()
    sampler.start()
    r = subprocess.run([VSPIPE, "-a", "MODE=speed", "-a", "LOOP=%d" % loop, "-a", "SRC=" + src, BENCH_VPY, "--"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace", env=env,
                       creationflags=NO_WINDOW)
    sampler.stop = True
    sampler.join()
    if r.returncode != 0:
        raise RuntimeError("medicion de velocidad fallo:\n" + r.stderr[-1500:])
    m = re.findall(r"Output (\d+) frames in ([\d.]+) seconds \(([\d.]+) fps\)", r.stderr)
    frames, secs, fps = int(m[-1][0]), float(m[-1][1]), float(m[-1][2])
    return fps, build, max(0, sampler.peak - base), sampler.peak


def main():
    args = sys.argv[1:]
    video = None
    if args and os.path.isfile(args[0]):
        video = os.path.abspath(args.pop(0))
    if not video:
        vids = sorted(glob.glob(os.path.join(ROOT, "videos", "*.mp4")) + glob.glob(os.path.join(ROOT, "videos", "*.mkv")))
        video = vids[0]
    names = args or sorted(os.path.splitext(os.path.basename(p))[0] for p in glob.glob(os.path.join(EXP, "configs", "*.bat")))
    tests = os.environ.get("BENCH_TESTS", "recon,twos,speed").split(",")

    os.makedirs(WORK, exist_ok=True)
    ref = os.path.join(WORK, "ref_%s.mkv" % os.path.splitext(os.path.basename(video))[0])
    if not os.path.isfile(ref):
        vspipe_to_ffv1("ref", video, {}, ref)

    # fps de salida real del clip, para expresar la velocidad como x tiempo real
    probe = subprocess.run([FFMPEG.replace("ffmpeg.exe", "ffprobe.exe"), "-v", "error", "-select_streams", "v:0",
                            "-show_entries", "stream=r_frame_rate", "-of", "default=nw=1:nk=1", video],
                           capture_output=True, text=True, creationflags=NO_WINDOW).stdout.strip()
    num, den = probe.split("/")
    src_fps = float(num) / float(den)

    new_file = not os.path.isfile(CSV)
    with open(CSV, "a", newline="", encoding="utf-8") as fh:
        wr = csv.writer(fh)
        if new_file:
            wr.writerow(["fecha", "config", "video", "recon_vmaf", "recon_psnr", "recon_ssim",
                         "twos_vmaf", "twos_psnr", "twos_ssim", "fps", "x_tiempo_real",
                         "seg_por_10s", "vram_mb", "vram_pico_mb", "build_s"])
        print("%-26s | %-22s | %-22s | %s" % ("config", "recon VMAF/PSNR", "twos VMAF/PSNR", "velocidad / VRAM"))
        for name in names:
            cfg = read_config(name)
            multi = cfg.get("EXP_MULTI", "2")
            mval = float(multi.split("/")[0]) / float(multi.split("/")[1]) if "/" in multi else float(multi)
            row = {"recon": ("", "", ""), "twos": ("", "", ""), "speed": ("", "", "", "", "", "")}
            try:
                for t in ("recon", "twos"):
                    if t in tests:
                        out = os.path.join(WORK, "%s_%s.mkv" % (t, name))
                        vspipe_to_ffv1(t, video, cfg, out)
                        row[t] = metrics(out, ref)
                        os.remove(out)
                if "speed" in tests:
                    fps, build, vram, peak = speed(video, cfg)
                    rt = fps / (src_fps * mval)
                    row["speed"] = (fps, rt, 10.0 / rt, vram, peak, build)
            except Exception as e:  # una config rota no corta el resto
                print("%-26s | ERROR: %s" % (name, str(e).strip().splitlines()[-1][:120]))
                continue

            def fmt(m):
                return "%6.2f / %5.2f dB" % (m[0], m[1]) if m[0] != "" else "-"
            sp = row["speed"]
            sp_txt = ("%5.1f fps  x%.3f  %4.0f s/10s  VRAM %d MB" % (sp[0], sp[1], sp[2], sp[3])) if sp[0] != "" else "-"
            print("%-26s | %-22s | %-22s | %s" % (name, fmt(row["recon"]), fmt(row["twos"]), sp_txt))
            wr.writerow([datetime.datetime.now().isoformat(timespec="seconds"), name, os.path.basename(video),
                         *row["recon"], *row["twos"], *row["speed"]])
            fh.flush()


if __name__ == "__main__":
    main()
