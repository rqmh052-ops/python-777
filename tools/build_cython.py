"""المرحلة 4: تجميع bayan_runtime.py بـ Cython إلى امتداد .so.

  python tools/build_cython.py host  <out_dir>      # x86_64 على المضيف، لاختبار tools/test_*.py ضده
  python tools/build_cython.py android <out_dir>    # arm64-v8a بتجميع متقاطع بـ clang من NDK

حالة التحقق (صادقة): وضع host مكتوب كاملًا لكن لم يُشغَّل في بيئة التطوير (لا Cython ولا شبكة هناك)؛
يتحقق منه CI فعليًا عبر tools/test_runtime.py وtools/test_extra.py ضد الـ .so. وضع android يكتشف
ترويسات libpython الخاصة بـ Chaquopy من ذاكرة Gradle ولا يخمّنها: إن لم يجدها يفشل بوضوح
(والـ workflow يرجع حينها لنسخة .py القديمة). طريقة دمج الـ .so داخل Chaquopy (BYNUX_CYTHON_SO في
prepare_android.py) تحتاج تأكيدًا بأول بناء حقيقي؛ لذلك مدخل cython افتراضيه false.
تحذير: النصوص الحرفية (strings) وأسماء الدوال تبقى مقروءة داخل الـ .so، فلا تضع أي سر في كود بايثون.
"""
from __future__ import annotations

import glob
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "bayan_runtime.py"
PY_VERSION = "3.13"
MIN_SDK = 24


def cythonize(workdir: Path) -> Path:
    shutil.copy2(SRC, workdir / "bayan_runtime.py")
    subprocess.run(
        [
            sys.executable, "-m", "cython", "-3", "--no-docstrings",
            "-X", "language_level=3", "bayan_runtime.py", "-o", "bayan_runtime.c",
        ],
        cwd=workdir,
        check=True,
    )
    return workdir / "bayan_runtime.c"


def build_host(out_dir: Path) -> Path:
    import sysconfig

    ver = sys.version_info
    if f"{ver.major}.{ver.minor}" != PY_VERSION:
        print(f"WARNING: host python is {ver.major}.{ver.minor}, Chaquopy uses {PY_VERSION}")
    out_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        cfile = cythonize(work)
        suffix = sysconfig.get_config_var("EXT_SUFFIX")
        so = out_dir / f"bayan_runtime{suffix}"
        cc = os.environ.get("CC", "gcc")
        subprocess.run(
            [cc, "-O2", "-fPIC", "-shared", "-fvisibility=hidden", "-s",
             f"-I{sysconfig.get_paths()['include']}", str(cfile), "-o", str(so)],
            check=True,
        )
    # لا نسخة .py ولا .c بجوار الـ .so
    for stale in ("bayan_runtime.py", "bayan_runtime.c"):
        (out_dir / stale).unlink(missing_ok=True)
    print(f"host extension: {so}")
    return so


def find_ndk_clang() -> Path:
    for var in ("ANDROID_NDK_LATEST_HOME", "ANDROID_NDK_HOME", "ANDROID_NDK_ROOT"):
        root = os.environ.get(var)
        if root:
            found = glob.glob(f"{root}/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android{MIN_SDK}-clang")
            if found:
                return Path(found[0])
    raise SystemExit("FAIL: NDK clang for aarch64-linux-android%d not found (ANDROID_NDK_LATEST_HOME?)" % MIN_SDK)


def find_target_python() -> tuple[Path, Path]:
    """يبحث في ذاكرة Gradle عن ترويسات Python 3.13 وlibpython الخاصة بـ Chaquopy (لا تخمين)."""
    homes = [Path(os.environ.get("GRADLE_USER_HOME", "")), Path.home() / ".gradle"]
    for home in filter(lambda p: str(p), homes):
        for py_h in home.rglob("Python.h"):
            inc = py_h.parent
            if "arm64" not in str(inc) and "aarch64" not in str(inc) and "chaquopy" not in str(inc).lower():
                continue
            libs = list(inc.parents[1].rglob(f"libpython{PY_VERSION}*.so"))
            if libs:
                return inc, libs[0]
    raise SystemExit(
        "FAIL: Chaquopy target Python headers/libpython not found in the Gradle cache. "
        "Run a Gradle build first (so Chaquopy downloads its target Python) or set cython=false."
    )


def build_android(out_dir: Path) -> Path:
    clang = find_ndk_clang()
    inc, libpython = find_target_python()
    out_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        cfile = cythonize(work)
        so = out_dir / "bayan_runtime.cpython-313-aarch64-linux-android.so"
        subprocess.run(
            [str(clang), "-O2", "-fPIC", "-shared", "-s", "-fvisibility=hidden",
             "-Wl,-z,max-page-size=16384", f"-I{inc}", str(cfile),
             f"-L{libpython.parent}", f"-l:{libpython.name}", "-o", str(so)],
            check=True,
        )
    print(f"android extension: {so} (check NEEDED with: readelf -d)")
    return so


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in ("host", "android"):
        print(__doc__)
        return 2
    out = Path(sys.argv[2])
    (build_host if sys.argv[1] == "host" else build_android)(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
