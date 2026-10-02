r"""
exp_bench.vpy - Grafos de medicion. Lo usa experimental\tools\bench.py.

MODE (via -a MODE=...):
  ref     frames impares del original, 8 bits: la "verdad" para comparar.
  recon   se tira un frame de cada dos, RIFE los reconstruye, y se devuelven
          solo los reconstruidos. Mide calidad pura de interpolacion.
  twos    simula animacion "en dos": cada frame par se muestra dos veces. Se
          interpola a x2 y se devuelven los frames que caen donde estaban los
          impares originales. Con interpolacion normal esos frames son una
          copia congelada del anterior; con la linea de tiempo anime-aware
          deberian parecerse al original.
  speed   el clip repetido LOOP veces (default 10), render completo sin
          encoder. Mide velocidad sostenida: la GPU de esta laptop esta
          limitada por potencia y los primeros segundos corren en boost.
  full    salida completa x2/x2.5 en 8 bits, para medir fluidez o mirarla.
"""
import os
import sys

# vspipe se cambia al directorio del script antes de ejecutarlo: si la ruta
# llego relativa, __file__ ya no es valido desde el cwd nuevo.
_HERE = os.getcwd() if os.path.isfile(os.path.basename(__file__)) else os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
import exp_core  # noqa: E402
import vapoursynth as vs  # noqa: E402

core = vs.core
core.max_cache_size = 1500

MODE = globals().get("MODE", "recon")
SRC = globals().get("SRC") or os.environ.get("SRC")
cfg = exp_core.cfg_from(globals())
src = exp_core.source(SRC)
ci = exp_core.color_info(src)

if MODE == "ref":
    out = src.std.SelectEvery(2, 1)
    out = core.resize.Bicubic(out, format=vs.YUV420P8)

elif MODE == "recon":
    half = src.std.SelectEvery(2, 0)
    rec, _ = exp_core.run(half, dict(cfg, multi="2"))
    rec = rec.std.SelectEvery(2, 1)
    out = exp_core.to_yuv(rec, ci, vs.YUV420P8)

elif MODE == "twos":
    held = core.std.Interleave([src.std.SelectEvery(2, 0)] * 2)[: src.num_frames]
    rec, _ = exp_core.run(held, dict(cfg, multi="2"))
    rec = rec.std.SelectEvery(4, 2)
    out = exp_core.to_yuv(rec, ci, vs.YUV420P8)

elif MODE == "rgbsrc":
    # Fuente en RGB fp16 para el entorno PyTorch: misma conversion de color que
    # usa RIFE, asi la comparacion entre modelos no mezcla diferencias de color.
    base = exp_core.derive(src, globals().get("KIND", "plain"), int(globals().get("LOOP", "1")))
    out = exp_core.to_rgb(base, ci, "fp16", cfg.get("kernel", "Bicubic"))

elif MODE == "speed":
    looped = src * int(globals().get("LOOP", "10"))
    rec, _ = exp_core.run(looped, cfg)
    out = exp_core.to_yuv(rec, ci, vs.YUV420P10)
    cas = float(cfg.get("cas", 0.35))
    if cas > 0:
        out = core.cas.CAS(out, sharpness=cas, planes=[0])

elif MODE == "full":
    base = src
    if globals().get("TWOS", "0") == "1":
        base = core.std.Interleave([src.std.SelectEvery(2, 0)] * 2)[: src.num_frames]
    rec, _ = exp_core.run(base, cfg)
    out = exp_core.to_yuv(rec, ci, vs.YUV420P8)

else:
    raise ValueError("MODE desconocido: %r" % MODE)

out.set_output()
