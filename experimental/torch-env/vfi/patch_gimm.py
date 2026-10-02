"""
patch_gimm.py - Deja el repo de GIMM-VFI en condiciones de correr aca.

El repo se escribio para Python 3.10 y CuPy 12. Son dos arreglos mecanicos, los
dos idempotentes: se puede correr las veces que haga falta.

  1. Dataclasses con defaults mutables. Python 3.11 dejo de aceptar
     "campo: Config = Config()" y exige field(default_factory=Config).
  2. El kernel CUDA de softsplat llama a cupy.cuda.compile_with_cache, que se
     elimino en CuPy 13. El reemplazo es cupy.RawModule.

Lo llama setup.bat. Tambien se puede correr suelto:
    torch-env\\venv\\Scripts\\python.exe torch-env\\vfi\\patch_gimm.py
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(os.path.dirname(HERE), "repos", "GIMM-VFI")
INR = os.path.join(REPO, "src", "models", "generalizable_INR")


def read(p):
    return io.open(p, encoding="utf-8").read()


def write(p, s):
    io.open(p, "w", encoding="utf-8", newline="\n").write(s)


def patch_dataclasses():
    n = 0
    for rel in ("configs.py", os.path.join("modules", "module_config.py")):
        p = os.path.join(INR, rel)
        if not os.path.isfile(p):
            continue
        s = read(p)
        s2 = re.sub(r"(\w+): (\w+Config) = \2\(\)",
                    lambda m: "%s: %s = field(default_factory=%s)" % (m.group(1), m.group(2), m.group(2)), s)
        if s2 != s:
            head = s2.split("from dataclasses import", 1)
            if len(head) > 1 and "field" not in head[1].split("\n", 1)[0]:
                s2 = s2.replace("from dataclasses import dataclass",
                                "from dataclasses import dataclass, field", 1)
            write(p, s2)
            n += 1
    return n


def patch_softsplat():
    p = os.path.join(INR, "modules", "softsplat.py")
    if not os.path.isfile(p):
        return 0
    s = read(p)
    if "compile_with_cache" not in s:
        return 0
    old = re.search(r"    return cupy\.cuda\.compile_with_cache\(.*?\n    \)\.get_function\("
                    r"objCudacache\[strKey\]\[\"strFunction\"\]\)", s, re.S)
    if not old:
        return 0
    new = ('    # cupy.cuda.compile_with_cache se elimino en CuPy 13. RawModule hace lo\n'
           '    # mismo: compila el kernel con nvrtc y devuelve la funcion.\n'
           '    return cupy.RawModule(\n'
           '        code=objCudacache[strKey]["strKernel"],\n'
           '        backend="nvrtc",\n'
           '        options=("-I " + os.environ["CUDA_HOME"], "-I " + os.environ["CUDA_HOME"] + "/include"),\n'
           '    ).get_function(objCudacache[strKey]["strFunction"])')
    write(p, s[:old.start()] + new + s[old.end():])
    return 1


def place_raft():
    """RAFT abre "pretrained_ckpt/raft-things.pth" relativo al directorio actual,
    y el adaptador se para en la raiz del repo para que lo encuentre."""
    src = os.path.join(os.path.dirname(HERE), "weights", "gimm", "raft-things.pth")
    dst_dir = os.path.join(REPO, "pretrained_ckpt")
    dst = os.path.join(dst_dir, "raft-things.pth")
    if not os.path.isfile(src) or os.path.isfile(dst):
        return 0
    os.makedirs(dst_dir, exist_ok=True)
    import shutil
    shutil.copyfile(src, dst)
    return 1


def main():
    if not os.path.isdir(REPO):
        print("  GIMM-VFI no esta clonado, nada que parchear")
        return 0
    a, b, c = patch_dataclasses(), patch_softsplat(), place_raft()
    print("  GIMM-VFI: %d dataclasses, %d softsplat, %d pesos de RAFT" % (a, b, c)
          if (a or b or c) else "  GIMM-VFI: ya estaba listo")
    return 0


if __name__ == "__main__":
    sys.exit(main())
