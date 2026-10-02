"""
runner.py - Ejecuta un plan de interpolacion con un modelo de PyTorch.

Entrada : frames RGB fp16 planares por stdin (los manda vspipe desde el
          VapourSynth de produccion, con la misma conversion de color que usa
          RIFE, para que comparar modelos no mezcle diferencias de color).
Plan    : JSON de experimental\\tools\\make_plan.py. Una decision por frame de
          salida: copiar un frame, o interpolar entre dos con una proporcion.
Salida  : frames rgb48le por stdout (los toma ffmpeg).

Solo GPU: aborta si no hay CUDA. No existe camino por CPU.

Uso:
  vspipe ... | python runner.py --plan plan.json --model gmfss_u | ffmpeg ...
"""
import argparse
import json
import os
import sys
import time

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from models import build_model, MODELS  # noqa: E402


class FrameSource:
    """Lee frames del pipe en orden y mantiene una ventana en la GPU."""

    def __init__(self, stream, width, height, device, multiple):
        self.s = stream
        self.w, self.h = width, height
        self.device = device
        self.nbytes = width * height * 3 * 2          # 3 planos, fp16
        self.buf = {}
        self.next = 0
        # padding al multiplo que exige el modelo
        self.pw = (-width) % multiple
        self.ph = (-height) % multiple

    def _read_one(self):
        raw = self.s.read(self.nbytes)
        if raw is None or len(raw) < self.nbytes:
            raise EOFError("se corto la fuente en el frame %d" % self.next)
        a = np.frombuffer(raw, dtype=np.float16).reshape(3, self.h, self.w)
        # OJO: vspipe escribe los planos RGB en orden G, B, R (como el gbrp de
        # ffmpeg), aunque en memoria VapourSynth los tenga como R, G, B. Sin
        # este reordenamiento salen los rojos y los azules cambiados.
        a = a[[2, 0, 1]]
        t = torch.from_numpy(a.copy()).to(self.device, non_blocking=True).unsqueeze(0)
        if self.pw or self.ph:
            t = torch.nn.functional.pad(t, (0, self.pw, 0, self.ph), mode="replicate")
        self.buf[self.next] = t
        self.next += 1

    def get(self, i):
        while self.next <= i:
            self._read_one()
        return self.buf[i]

    def prune(self, keep_from):
        for k in [k for k in self.buf if k < keep_from]:
            del self.buf[k]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True)
    ap.add_argument("--model", required=True, choices=sorted(MODELS))
    ap.add_argument("--scale", type=float, default=1.0, help="escala interna del flujo (0.5 para 1080p pesado)")
    ap.add_argument("--fp16", action="store_true", default=True)
    ap.add_argument("--fp32", dest="fp16", action="store_false")
    ap.add_argument("--limit", type=int, default=0, help="procesar solo N frames de salida")
    ap.add_argument("--stats", default=None)
    a = ap.parse_args()

    if not torch.cuda.is_available():
        sys.exit("runner: no hay CUDA. Este entorno es solo GPU, no hay camino por CPU.")
    device = torch.device("cuda")
    torch.set_grad_enabled(False)
    torch.backends.cudnn.benchmark = True

    with open(a.plan, encoding="utf-8") as fh:
        plan_data = json.load(fh)
    plan = plan_data["plan"]
    W, H = plan_data["width"], plan_data["height"]

    sel = plan_data.get("select")
    if sel:
        wanted = [j for j in range(len(plan)) if j % sel["cycle"] in sel["offsets"]]
    else:
        wanted = list(range(len(plan)))
    if a.limit:
        wanted = wanted[: a.limit]

    model = build_model(a.model, device=device, fp16=a.fp16, scale=a.scale)
    src = FrameSource(sys.stdin.buffer, W, H, device, model.multiple)
    out = sys.stdout.buffer

    ctx = None
    ctx_key = None
    n_inf = 0
    torch.cuda.reset_peak_memory_stats()
    t0 = time.time()

    for j in wanted:
        af, bf, r = plan[j]
        src.prune(min(af, bf) - 2)
        if r <= 0:
            img = src.get(af)
        else:
            i0, i1 = src.get(af), src.get(bf)
            if ctx_key != (af, bf):
                ctx = model.prepare(i0, i1)
                ctx_key = (af, bf)
            img = model.interp(i0, i1, float(r), ctx)
            n_inf += 1
        img = img[:, :, :H, :W].float().clamp_(0, 1)
        frame = (img[0].permute(1, 2, 0) * 65535.0 + 0.5).to(torch.uint16).cpu().numpy()
        out.write(frame.tobytes())

    out.flush()
    dt = time.time() - t0
    stats = {
        "model": a.model, "frames": len(wanted), "inferencias": n_inf,
        "segundos": round(dt, 2), "fps": round(len(wanted) / dt, 2) if dt else 0,
        "vram_pico_mb": round(torch.cuda.max_memory_allocated() / 1048576),
        "scale": a.scale, "fp16": a.fp16,
    }
    print(json.dumps(stats), file=sys.stderr)
    if a.stats:
        with open(a.stats, "w", encoding="utf-8") as fh:
            json.dump(stats, fh)


if __name__ == "__main__":
    main()
