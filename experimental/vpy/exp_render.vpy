r"""
exp_render.vpy - Render experimental. Mismo contrato que scripts\interpolate.vpy
(recibe SRC, devuelve YUV 4:2:0 10 bits), asi que lo puede llamar el
process-one.bat de produccion sin tocarlo: run-exp.bat solo cambia la variable
VPY para que apunte aca.

La configuracion llega como variables EXP_* (las define cada archivo de
experimental\configs\).
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
core.max_cache_size = int(os.environ.get("VS_CACHE_MB", "1200"))

SRC = globals().get("SRC") or os.environ.get("SRC")
if not SRC or not os.path.isfile(SRC):
    raise FileNotFoundError("exp_render.vpy: falta SRC o no existe: %r" % SRC)

cfg = exp_core.cfg_from(globals())
src = exp_core.source(SRC)
if src.fps_num == 0:
    raise ValueError("exp_render.vpy: fuente VFR, convertila a CFR antes.")

out, ci = exp_core.run(src, cfg, cache_key=exp_core.cache_key_for(SRC, cfg, "render"))
out = exp_core.to_yuv(out, ci, vs.YUV420P10)

cas = float(cfg.get("cas", 0.35))
if cas > 0:
    out = core.cas.CAS(out, sharpness=cas, planes=[0])

print("[exp] %s | %s -> %s/%s fps | %s" % (os.path.basename(SRC), src.num_frames, out.fps_num,
      out.fps_den, " ".join("%s=%s" % kv for kv in sorted(cfg.items()))), file=sys.stderr)
out.set_output()
