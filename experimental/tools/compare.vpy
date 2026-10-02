r"""
compare.vpy - Imagen comparativa de un frame: verdad | interpolacion normal |
linea de tiempo anime-aware, sobre animacion "en dos" simulada.

    vspipe -a SRC=<video> -a K=<frame impar> -s 0 -e 0 -c y4m compare.vpy - | ffmpeg ... out.png
"""
import os
import sys

_HERE = os.getcwd() if os.path.isfile(os.path.basename(__file__)) else os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "..", "vpy"))
import exp_core  # noqa: E402
import vapoursynth as vs  # noqa: E402

core = vs.core
src = exp_core.source(globals()["SRC"])
k = int(globals().get("K", "75")) | 1
held = core.std.Interleave([src.std.SelectEvery(2, 0)] * 2)[: src.num_frames]
base = {"model": "426", "impl": "0", "precision": "fp16", "multi": "2"}

normal, ci = exp_core.run(held, dict(base, timeline="0"))
aware, _ = exp_core.run(held, dict(base, timeline="1", dedup="1"))


def tile(clip, label):
    c = exp_core.to_yuv(clip, ci, vs.YUV420P8) if clip.format.color_family == vs.RGB else \
        core.resize.Bicubic(clip, format=vs.YUV420P8)
    c = core.std.Crop(c, left=480, right=480, top=150, bottom=210)
    return core.text.Text(c, label, alignment=7, scale=2)


out = core.std.StackHorizontal([
    tile(src[k], "VERDAD (frame original %d)" % k),
    tile(normal[2 * k], "NORMAL: copia congelada"),
    tile(aware[2 * k], "LINEA DE TIEMPO"),
])
out.set_output()
