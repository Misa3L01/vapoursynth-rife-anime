"""
models.py - Adaptadores de cada modelo de interpolacion a una interfaz comun.

Interfaz:
    multiple            a que multiplo hay que rellenar la imagen
    prepare(i0, i1)     trabajo pesado que se comparte entre timesteps del mismo
                        par de frames (flujo optico, features). Puede devolver None.
    interp(i0, i1, t, ctx) -> tensor (1,3,H,W) en 0..1

Todos reciben y devuelven tensores en la GPU. Ninguno tiene camino por CPU.
"""
import os
import sys

import torch
import torch.nn.functional as F

HERE = os.path.dirname(os.path.abspath(__file__))
ENV = os.path.dirname(HERE)
REPOS = os.path.join(ENV, "repos")
WEIGHTS = os.path.join(ENV, "weights")


def _add_repo(name):
    p = os.path.join(REPOS, name)
    if p not in sys.path:
        sys.path.insert(0, p)
    return p


class Hold:
    """Control: repite el frame anterior. Sirve para verificar que el puente de
    color entre VapourSynth y este entorno no cambia los resultados: en la
    prueba "en dos", RIFE normal tambien produce copias, asi que el VMAF de
    este control tiene que coincidir con el de RIFE."""
    multiple = 1

    def __init__(self, device, fp16=True, scale=1.0):
        pass

    def prepare(self, i0, i1):
        return None

    def interp(self, i0, i1, t, ctx=None):
        return i0


class Blend:
    """Control 2: promedio simple de los dos frames. Es el piso: cualquier
    modelo que no lo supere no esta aportando nada."""
    multiple = 1

    def __init__(self, device, fp16=True, scale=1.0):
        pass

    def prepare(self, i0, i1):
        return None

    def interp(self, i0, i1, t, ctx=None):
        return i0 * (1.0 - t) + i1 * t


class GmfssUnion:
    """GMFSS Fortuna (union): GMFlow + RIFE + softsplat + fusion, afinado para
    anime. Acepta timestep arbitrario y comparte el flujo entre timesteps del
    mismo par, que es justo lo que necesita la linea de tiempo."""
    multiple = 64

    def __init__(self, device, fp16=True, scale=1.0, weights="gmfss_union_anime"):
        repo = _add_repo("GMFSS_Fortuna")
        cwd = os.getcwd()
        os.chdir(repo)                      # el repo importa "model.*" en relativo
        try:
            from model.GMFSS_infer_u import Model
        finally:
            os.chdir(cwd)
        self.model = Model()
        self.model.load_model(os.path.join(WEIGHTS, weights), -1)
        self.model.eval()
        self.model.device()
        self.fp16 = fp16
        self.scale = scale
        # Los pesos quedan en fp32 y la precision media se maneja con autocast.
        # Forzar .half() rompe: adentro de GMFlow hay tensores que vuelven a
        # fp32 (grillas de coordenadas) y chocan con los pesos.
        self.amp = torch.autocast("cuda", dtype=torch.float16, enabled=fp16)
        # A 1080p la atencion global de GMFlow no entra en 6 GB: con scale=0.5
        # el flujo se calcula a media resolucion, que es lo que recomienda el
        # propio script del repo. El relleno sube a 128 en ese caso.
        self.multiple = max(64, int(round(64 / scale)))

    def prepare(self, i0, i1):
        with self.amp:
            return self.model.reuse(i0.float(), i1.float(), self.scale)

    def interp(self, i0, i1, t, ctx):
        with self.amp:
            return self.model.inference(i0.float(), i1.float(), ctx, t).float()


class Amt:
    """AMT (CVPR 2023). No comparte trabajo entre timesteps: recalcula todo."""
    multiple = 64

    def __init__(self, device, fp16=True, scale=1.0, variant="amt-g"):
        import importlib.util
        repo = _add_repo("AMT")
        spec = importlib.util.spec_from_file_location(
            "amt_net", os.path.join(repo, "networks", variant.upper().replace("AMT-", "AMT-") + ".py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        self.net = mod.Model(corr_radius=3, corr_lvls=4, num_flows=5) if variant == "amt-g" else mod.Model()
        ck = torch.load(os.path.join(WEIGHTS, variant + ".pth"), map_location="cpu", weights_only=False)
        self.net.load_state_dict(ck["state_dict"] if "state_dict" in ck else ck)
        self.net.to(device).eval()
        self.fp16 = fp16
        self.scale = scale
        # Igual que GMFSS: autocast en vez de .half(), porque grid_sample recibe
        # grillas en fp32 generadas adentro de la red.
        self.amp = torch.autocast("cuda", dtype=torch.float16, enabled=fp16)

    def prepare(self, i0, i1):
        return None

    def interp(self, i0, i1, t, ctx=None):
        a, b = i0.float(), i1.float()
        embt = torch.full((a.shape[0], 1, 1, 1), t, dtype=a.dtype, device=a.device)
        with self.amp:
            out = self.net(a, b, embt, scale_factor=self.scale, eval=True)
        out = out["imgt_pred"] if isinstance(out, dict) else out
        return out.float()


class EmaVfi:
    """EMA-VFI (CVPR 2023). hr_inference() baja la resolucion del flujo, que es
    lo que hace falta para 1080p en 6 GB."""
    multiple = 64

    def __init__(self, device, fp16=True, scale=0.5, variant="ours_t"):
        repo = _add_repo("EMA-VFI")
        cwd = os.getcwd()
        os.chdir(repo)
        try:
            import config as cfg
            cfg.MODEL_CONFIG["LOGNAME"] = variant
            # "_t" son las variantes de timestep arbitrario. La chica (small)
            # usa mucha menos memoria: la grande no entra en 6 GB a 1080p.
            if "small" in variant:
                cfg.MODEL_CONFIG["MODEL_ARCH"] = cfg.init_model_config(F=16, depth=[2, 2, 2, 2, 2])
            else:
                cfg.MODEL_CONFIG["MODEL_ARCH"] = cfg.init_model_config(F=32, depth=[2, 2, 2, 4, 4])
            from Trainer import Model as EmaModel
            self.model = EmaModel(-1)
            # load_model() abre "ckpt/<nombre>.pkl" relativo al directorio actual
            os.chdir(os.path.join(WEIGHTS, "ema"))
            self.model.load_model(name=variant)
        finally:
            os.chdir(cwd)
        self.model.eval()
        self.model.device()
        self.scale = scale
        self.fp16 = fp16

    def prepare(self, i0, i1):
        return None

    def interp(self, i0, i1, t, ctx=None):
        a, b = i0.float(), i1.float()
        return self.model.hr_inference(a, b, TTA=False, down_scale=self.scale, timestep=t)



class GimmVfi:
    """GIMM-VFI (NeurIPS 2024). En vez de suponer que el movimiento entre dos
    dibujos es una linea recta a velocidad constante, aprende una funcion
    continua del movimiento y la evalua en el instante que se le pida. Esa es
    justo la diferencia con RIFE y compania, que interpolan el flujo de forma
    lineal.

    La variante "_r" usa RAFT para el flujo optico; la "_f" usa FlowFormer, que
    es un transformer y no entra comodo en 6 GB a 1080p.

    El repo tiene su propio paquete llamado "models", igual que este archivo.
    Por eso el import se hace sacando el nuestro de sys.modules y devolviendolo
    despues: si no, cada uno se pisa con el otro.
    """
    multiple = 32

    def __init__(self, device, fp16=True, scale=1.0, variant="gimmvfi_r_arb"):
        repo = os.path.join(REPOS, "GIMM-VFI")
        src = os.path.join(repo, "src")
        cwd = os.getcwd()
        saved = sys.modules.pop("models", None)
        sys.path.insert(0, src)
        # RAFT carga "pretrained_ckpt/raft-things.pth" relativo al directorio
        # actual, asi que hay que pararse en la raiz del repo.
        os.chdir(repo)
        try:
            from utils.config import load_config, augment_arch_defaults
            from models import create_model
            cfg = load_config(os.path.join(repo, "configs", "gimmvfi", "gimmvfi_r_arb.yaml"))
            model, _ = create_model(augment_arch_defaults(cfg.arch))
            ckpt = torch.load(os.path.join(WEIGHTS, "gimm", variant + ".pt"),
                              map_location="cpu", weights_only=False)
            model.load_state_dict(ckpt["state_dict"], strict=True)
        finally:
            os.chdir(cwd)
            if src in sys.path:
                sys.path.remove(src)
            if saved is not None:
                sys.modules["models"] = saved
        self.model = model.to(device).eval()
        self.scale = scale
        self.fp16 = fp16

    def prepare(self, i0, i1):
        return None

    def interp(self, i0, i1, t, ctx=None):
        xs = torch.cat((i0.float().unsqueeze(2), i1.float().unsqueeze(2)), dim=2)
        n = xs.shape[0]
        coord = self.model.sample_coord_input(n, xs.shape[-2:], [t], device=xs.device,
                                              upsample_ratio=self.scale)
        ts = [t * torch.ones(n, device=xs.device, dtype=torch.float)]
        with torch.autocast("cuda", torch.float16, enabled=self.fp16):
            out = self.model(xs, [(coord, None)], t=ts, ds_factor=self.scale)
        return out["imgt_pred"][0].float().clamp(0, 1)


MODELS = {
    "hold": Hold,
    "blend": Blend,
    "gmfss_u": GmfssUnion,
    "amt_g": lambda **kw: Amt(variant="amt-g", **kw),
    "amt_l": lambda **kw: Amt(variant="amt-l", **kw),
    "ema": EmaVfi,
    "ema_small": lambda **kw: EmaVfi(variant="ours_small_t", **kw),
    "gimm": GimmVfi,
    "gimm_lpips": lambda **kw: GimmVfi(variant="gimmvfi_r_arb_lpips", **kw),
}


def build_model(name, device, fp16=True, scale=1.0):
    factory = MODELS[name]
    return factory(device=device, fp16=fp16, scale=scale)
