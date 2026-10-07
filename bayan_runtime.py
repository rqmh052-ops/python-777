"""Runtime execution and package manager for Bayan.

This module is bundled as app code by Chaquopy, but all writable state lives
under the private Bayan environment configured by the Android bridge.
"""

from __future__ import annotations

import builtins
import csv
import hashlib
import importlib
import io
import json
import os
import re
import shutil
import sys
import tempfile
import threading
import time
import traceback
from concurrent.futures import ThreadPoolExecutor
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from email.parser import Parser
from pathlib import Path
from typing import Any

PYTHON_VERSION = f"{sys.version_info.major}.{sys.version_info.minor}"
PYPI_JSON = "https://pypi.org/pypi/{name}/json"
CHAQUOPY_INDEX = "https://chaquo.com/pypi-13.1/{name}/"

_ENV_ROOT: Path | None = None
_HOME: Path | None = None
_SITE: Path | None = None
_CACHE: Path | None = None
_METADATA: Path | None = None

_CONFIG_LOCK = threading.RLock()


def configure(env_root: str) -> str:
    global _ENV_ROOT, _HOME, _SITE, _CACHE, _METADATA
    with _CONFIG_LOCK:
        _ENV_ROOT = Path(env_root).resolve()
        _HOME = _ENV_ROOT / "home"
        _SITE = _ENV_ROOT / "site-packages"
        _CACHE = _ENV_ROOT / "cache"
        _METADATA = _ENV_ROOT / "metadata"
        for p in (_ENV_ROOT, _HOME, _SITE, _CACHE, _METADATA, _CACHE / "downloads", _CACHE / "indexes", _CACHE / "tmp"):
            p.mkdir(parents=True, exist_ok=True)
        os.environ["HOME"] = str(_HOME)
        os.environ["BAYAN_HOME"] = str(_HOME)
        os.environ["BAYAN_SITE_PACKAGES"] = str(_SITE)
        os.environ["TMPDIR"] = str(_CACHE / "tmp")
        if str(_SITE) not in sys.path:
            sys.path.insert(0, str(_SITE))
        importlib.invalidate_caches()
    return str(_ENV_ROOT)


def _require_config() -> tuple[Path, Path, Path, Path]:
    if _ENV_ROOT is None or _HOME is None or _SITE is None or _CACHE is None or _METADATA is None:
        raise RuntimeError("Bayan Python environment is not configured")
    return _ENV_ROOT, _HOME, _SITE, _CACHE


def _configure_android(android_api: int, abi: str) -> None:
    os.environ["BAYAN_ANDROID_API"] = str(android_api or 24)
    os.environ["BAYAN_ABI"] = abi or "arm64-v8a"


def environment_info(android_api: int = 0, abi: str = "") -> str:
    _configure_android(android_api, abi)
    root, home, site, cache = _require_config()
    return json.dumps(
        {
            "python": PYTHON_VERSION,
            "envRoot": str(root),
            "home": str(home),
            "sitePackages": str(site),
            "cache": str(cache),
            "androidApi": android_api,
            "abi": abi,
        },
        ensure_ascii=False,
    )


class StopRequested(BaseException):
    pass


class _CallbackStream(io.TextIOBase):
    def __init__(self, callback: Any, kind: str):
        super().__init__()
        self.callback = callback
        self.kind = kind

    def write(self, s: str) -> int:
        if s:
            self.callback.emitOutput(self.kind, s)
        return len(s)

    def flush(self) -> None:
        return None

    def isatty(self) -> bool:
        return False

    @property
    def encoding(self) -> str:
        return "utf-8"


class _CallbackStdin(io.TextIOBase):
    def __init__(self, callback: Any):
        super().__init__()
        self.callback = callback

    def readline(self, size: int = -1) -> str:
        if self.callback.shouldStop():
            raise StopRequested()
        self.callback.emitInput("")
        value = self.callback.requestInput("")
        if value is None:
            raise StopRequested()
        if self.callback.shouldStop():
            raise StopRequested()
        return str(value) + "\n"

    def read(self, size: int = -1) -> str:
        return self.readline(size)

    def isatty(self) -> bool:
        return False

    @property
    def encoding(self) -> str:
        return "utf-8"


def _trace_factory(callback: Any):
    def trace(frame, event, arg):
        if callback.shouldStop():
            raise StopRequested()
        # Opcode tracing makes stop responsive even for tight single-line loops.
        if event == "call":
            try:
                frame.f_trace_opcodes = True
            except Exception:
                pass
        elif event == "opcode":
            if callback.shouldStop():
                raise StopRequested()
        return trace

    return trace


def _run_exit_code(value: Any) -> int:
    if value is None:
        return 0
    if isinstance(value, int):
        return int(value)
    try:
        return int(str(value))
    except Exception:
        return 1


def run_script(script_path: str, callback: Any) -> int:
    """Execute one user script in the shared Bayan Python interpreter."""
    _, _, site, _ = _require_config()
    path = Path(script_path).resolve()
    if not path.is_file():
        callback.emitError(f"الملف غير موجود: {path}")
        callback.emitExit(1)
        return 1

    old_cwd = Path.cwd()
    old_stdout = sys.stdout
    old_stderr = sys.stderr
    old_stdin = sys.stdin
    old_input = builtins.input
    old_path = list(sys.path)
    old_trace = sys.gettrace()
    old_thread_trace = threading.gettrace() if hasattr(threading, "gettrace") else None

    out = _CallbackStream(callback, "stdout")
    err = _CallbackStream(callback, "stderr")
    stdin = _CallbackStdin(callback)
    trace = _trace_factory(callback)
    exit_code = 0
    callback.emitState("running")

    try:
        site_str = str(site)
        script_dir = str(path.parent)
        sys.path[:] = [script_dir, site_str] + [p for p in old_path if p not in {script_dir, site_str}]
        os.chdir(script_dir)
        sys.stdout = out
        sys.stderr = err
        sys.stdin = stdin

        def bayan_input(prompt: str = "") -> str:
            if callback.shouldStop():
                raise StopRequested()
            callback.emitInput(str(prompt))
            value = callback.requestInput(str(prompt))
            if value is None or callback.shouldStop():
                raise StopRequested()
            return str(value)

        builtins.input = bayan_input
        sys.settrace(trace)
        if hasattr(threading, "settrace"):
            threading.settrace(trace)

        with path.open("r", encoding="utf-8", errors="replace") as fh:
            source = fh.read()
        if source.startswith("\ufeff"):
            source = source[1:]
        code = compile(source, str(path), "exec")
        namespace = {
            "__name__": "__main__",
            "__file__": str(path),
            "__package__": None,
            "__cached__": None,
        }
        exec(code, namespace, namespace)
        exit_code = 0
    except StopRequested:
        exit_code = 130
        callback.emitState("stopped")
    except SystemExit as exc:
        exit_code = _run_exit_code(exc.code)
        if exit_code != 0:
            traceback.print_exc(file=err)
    except BaseException:
        exit_code = 1
        traceback.print_exc(file=err)
    finally:
        try:
            sys.settrace(old_trace)
        except Exception:
            pass
        if hasattr(threading, "settrace"):
            try:
                threading.settrace(old_thread_trace)
            except Exception:
                pass
        sys.stdout = old_stdout
        sys.stderr = old_stderr
        sys.stdin = old_stdin
        builtins.input = old_input
        sys.path[:] = old_path
        try:
            os.chdir(old_cwd)
        except Exception:
            pass
        importlib.invalidate_caches()
        callback.emitExit(exit_code)
        callback.emitState("finished" if exit_code == 0 else ("stopped" if exit_code == 130 else "error"))
    return exit_code


# ---------------------------------------------------------------------------
# Runtime package manager
# ---------------------------------------------------------------------------

CATALOG = [
    {"name": "requests", "description": "طلبات HTTP للإنترنت", "module": "requests"},
    {"name": "beautifulsoup4", "description": "تحليل صفحات HTML", "module": "bs4"},
    {"name": "python-dotenv", "description": "قراءة متغيرات البيئة من ملفات .env", "module": "dotenv"},
    {"name": "PyYAML", "description": "قراءة وكتابة YAML", "module": "yaml"},
    {"name": "python-telegram-bot", "description": "تطوير بوتات Telegram", "module": "telegram"},
    {"name": "pyTelegramBotAPI", "description": "إنشاء بوتات Telegram بواجهة بسيطة", "module": "telebot"},
    {"name": "Telethon", "description": "عميل Telegram عبر MTProto", "module": "telethon"},
]

_CACHE_JSON: dict[str, tuple[float, dict[str, Any]]] = {}
_CACHE_TTL = 300.0
_CACHE_LOCK = threading.RLock()
_PACKAGE_LOCK = threading.RLock()


def _norm_name(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name.strip()).lower()


def _parse_spec(spec: str) -> tuple[str, list[tuple[str, str]]]:
    spec = spec.strip()
    if not spec:
        raise ValueError("اسم المكتبة فارغ")
    # Reject URLs, local paths and options. Bayan installs named packages only.
    if spec.startswith(("-", ".", "/", "http://", "https://")):
        raise ValueError("اكتب اسم مكتبة من PyPI فقط")
    name_match = re.match(r"^([A-Za-z0-9][A-Za-z0-9_.-]*)(.*)$", spec)
    if not name_match:
        raise ValueError("اسم المكتبة غير صالح")
    raw_name, remainder = name_match.groups()
    if ";" in raw_name:
        raise ValueError("اسم المكتبة غير صالح")
    constraints: list[tuple[str, str]] = []
    remainder = remainder.strip()
    if remainder:
        remainder = remainder.replace("(", "").replace(")", "")
        for part in re.split(r",\s*", remainder):
            m = re.match(r"^(==|!=|<=|>=|<|>|~=)\s*([A-Za-z0-9!+._-]+)$", part.strip())
            if not m:
                raise ValueError("صيغة الإصدار غير مدعومة")
            constraints.append((m.group(1), m.group(2)))
    return _norm_name(raw_name), constraints


def _version_parts(v: str) -> tuple:
    v = v.strip().lower()
    v = v.split("+", 1)[0]
    epoch = 0
    if "!" in v:
        ep, v = v.split("!", 1)
        try:
            epoch = int(ep)
        except ValueError:
            epoch = 0
    # Common PEP 440 prerelease/postrelease handling. Good for package selection
    # without bringing the large `packaging` dependency into the base runtime.
    m = re.match(r"^([0-9]+(?:\.[0-9]+)*)(.*)$", v)
    if not m:
        return (epoch, (0,), 0, "")
    release = tuple(int(x) for x in m.group(1).split("."))
    tail = m.group(2)
    pre_rank = 3
    pre_num = 0
    post = 0
    if tail:
        pm = re.search(r"(?:^|\.)(a|alpha|b|beta|rc)([0-9]*)", tail)
        if pm:
            pre_tag = pm.group(1)
            pre_rank = {"a": 0, "alpha": 0, "b": 1, "beta": 1, "rc": 2}[pre_tag]
            pre_num = int(pm.group(2) or 0)
        postm = re.search(r"(?:post|rev|r)[._-]?([0-9]+)", tail)
        if postm:
            post = int(postm.group(1)) + 1
    return (epoch, release, pre_rank, pre_num, post)


def _cmp_version(a: str, b: str) -> int:
    pa, pb = _version_parts(a), _version_parts(b)
    if pa < pb:
        return -1
    if pa > pb:
        return 1
    return 0


def _satisfies(version: str, constraints: list[tuple[str, str]]) -> bool:
    for op, wanted in constraints:
        c = _cmp_version(version, wanted)
        if op == "==" and c != 0:
            return False
        if op == "!=" and c == 0:
            return False
        if op == ">=" and c < 0:
            return False
        if op == "<=" and c > 0:
            return False
        if op == ">" and c <= 0:
            return False
        if op == "<" and c >= 0:
            return False
        if op == "~=":
            # Compatible release: same first release component and >= wanted.
            if c < 0:
                return False
            if _version_parts(version)[0:2] != _version_parts(wanted)[0:2]:
                return False
    return True


def _marker_value(name: str) -> str:
    if name in {"python_version", "python_full_version"}:
        return f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}" if name == "python_full_version" else PYTHON_VERSION
    if name == "sys_platform":
        return sys.platform
    if name == "platform_machine":
        return os.environ.get("BAYAN_ABI", "aarch64")
    if name == "platform_system":
        return "Android"
    if name == "os_name":
        return "posix"
    if name == "implementation_name":
        return "cpython"
    return ""


def _eval_marker(expr: str) -> bool:
    expr = expr.strip()
    if not expr:
        return True
    if "extra" in expr.lower():
        return False
    expr = expr.replace("(", "").replace(")", "")
    for or_part in re.split(r"\s+or\s+", expr, flags=re.I):
        ok = True
        for atom in re.split(r"\s+and\s+", or_part.strip(), flags=re.I):
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*|platform_release)\s*(==|!=|<=|>=|<|>|not\s+in|in)\s*[\"']([^\"']*)[\"']$", atom.strip())
            if not m:
                # Unknown marker: conservative choice is to skip it rather than
                # install a potentially wrong dependency.
                ok = False
                break
            key, op, wanted = m.groups()
            actual = _marker_value(key)
            if op in {"in", "not in"}:
                values = {v.strip() for v in wanted.split(",")}
                contains = actual in values
                if (op == "in" and not contains) or (op == "not in" and contains):
                    ok = False
                continue
            if key in {"python_version", "python_full_version"}:
                cmp = _cmp_version(actual, wanted)
            else:
                cmp = -1 if actual < wanted else (1 if actual > wanted else 0)
            if op == "==" and cmp != 0:
                ok = False
            elif op == "!=" and cmp == 0:
                ok = False
            elif op == ">=" and cmp < 0:
                ok = False
            elif op == "<=" and cmp > 0:
                ok = False
            elif op == ">" and cmp <= 0:
                ok = False
            elif op == "<" and cmp >= 0:
                ok = False
        if ok:
            return True
    return False


def _req_parts(raw: str) -> tuple[str, list[tuple[str, str]]] | None:
    if ";" in raw:
        base, marker = raw.split(";", 1)
        if not _eval_marker(marker):
            return None
        raw = base.strip()
    # Extras are already optional here.
    raw = re.sub(r"\[[^\]]*\]", "", raw)
    try:
        return _parse_spec(raw)
    except ValueError:
        raise ValueError(f"اعتماد غير مدعوم: {raw}")


def _get_json(name: str, callback: Any | None = None) -> dict[str, Any]:
    key = _norm_name(name)
    now = time.monotonic()
    with _CACHE_LOCK:
        cached = _CACHE_JSON.get(key)
        if cached is not None and now - cached[0] < _CACHE_TTL:
            return cached[1]
    url = PYPI_JSON.format(name=urllib.parse.quote(key, safe=""))
    if callback is not None:
        callback.emitPackage("search", 0, 0, f"البحث عن {key}...")
    req = urllib.request.Request(url, headers={"User-Agent": "Bayan-Python/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise ValueError("لم يتم العثور على مكتبة بهذا الاسم")
        raise RuntimeError(f"PyPI HTTP {exc.code}")
    except urllib.error.URLError as exc:
        raise RuntimeError(f"تعذر الاتصال بـPyPI: {exc.reason}")
    with _CACHE_LOCK:
        _CACHE_JSON[key] = (time.monotonic(), data)
    return data


def _requires_python_ok(requires_python: str | None) -> bool:
    if not requires_python:
        return True
    # Requires-Python uses comma separated specifiers.
    try:
        constraints = []
        for part in requires_python.split(","):
            m = re.match(r"^(==|!=|<=|>=|<|>|~=)\s*([0-9][^, ]*)$", part.strip())
            if m:
                constraints.append((m.group(1), m.group(2)))
        return _satisfies(PYTHON_VERSION, constraints)
    except Exception:
        return True


def _parse_wheel_filename(filename: str) -> dict[str, str] | None:
    if not filename.lower().endswith(".whl"):
        return None
    parts = filename[:-4].split("-")
    if len(parts) < 5:
        return None
    py_tag, abi_tag, platform_tag = parts[-3], parts[-2], parts[-1]
    version = parts[-4]
    return {"version": version, "python": py_tag, "abi": abi_tag, "platform": platform_tag}


def _abi_tag() -> str:
    abi = os.environ.get("BAYAN_ABI", "arm64-v8a")
    return abi.replace("-", "_")


def _android_api() -> int:
    try:
        return int(os.environ.get("BAYAN_ANDROID_API", "24"))
    except Exception:
        return 24


def _wheel_compatible(filename: str) -> bool:
    info = _parse_wheel_filename(filename)
    if not info:
        return False
    py = info["python"]
    if py not in {"py3", "py2.py3", "py3.py3", "abi3", f"cp{sys.version_info.major}{sys.version_info.minor}"}:
        # Multiple Python tags may be dot separated in a wheel name.
        if f"cp{sys.version_info.major}{sys.version_info.minor}" not in py.split("."):
            return False
    platform = info["platform"]
    if platform == "any":
        return info["abi"] == "none"
    m = re.match(r"^android_(\d+)_(.+)$", platform)
    if not m:
        return False
    min_api = int(m.group(1))
    abi = m.group(2)
    return min_api <= _android_api() and abi == _abi_tag()


def _chaquopy_wheel(name: str, requested_version: str | None = None) -> dict[str, Any] | None:
    url = CHAQUOPY_INDEX.format(name=urllib.parse.quote(_norm_name(name), safe=""))
    req = urllib.request.Request(url, headers={"User-Agent": "Bayan-Python/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            text = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise RuntimeError(f"Chaquopy wheel index HTTP {exc.code}")
    except urllib.error.URLError as exc:
        raise RuntimeError(f"تعذر الاتصال بمستودع Chaquopy: {exc.reason}")
    hrefs = re.findall(r'href=["\']([^"\']+)["\']', text, flags=re.I)
    items: list[dict[str, Any]] = []
    for href in hrefs:
        filename = urllib.parse.unquote(href.rsplit("/", 1)[-1].split("#", 1)[0])
        info = _parse_wheel_filename(filename)
        if not info or not _wheel_compatible(filename):
            continue
        if requested_version and _cmp_version(info["version"], requested_version) != 0:
            continue
        items.append({"filename": filename, "url": urllib.parse.urljoin(url, href), "digest": None, "requires_python": None, "source": "chaquopy", "version": info["version"]})
    if not items:
        return None
    items.sort(key=lambda x: _version_parts(x["version"]), reverse=True)
    return items[0]


def _distribution_record(norm: str) -> tuple[Path, dict[str, Any]] | None:
    _, _, site, _ = _require_config()
    target = None
    for dist_info in site.glob("*.dist-info"):
        meta = dist_info / "METADATA"
        if not meta.is_file():
            continue
        try:
            parsed = Parser().parsestr(meta.read_text("utf-8", errors="replace"))
        except Exception:
            continue
        if _norm_name(parsed.get("Name", "")) == norm:
            target = (dist_info, {"name": parsed.get("Name", norm), "version": parsed.get("Version", "")})
            break
    return target


def _installed_version(norm: str) -> str | None:
    found = _distribution_record(norm)
    return found[1]["version"] if found else None


def _read_metadata_from_wheel(path: Path) -> tuple[dict[str, str], list[str], list[str]]:
    with zipfile.ZipFile(path, "r") as zf:
        meta_name = next((n for n in zf.namelist() if n.endswith(".dist-info/METADATA")), None)
        wheel_name = next((n for n in zf.namelist() if n.endswith(".dist-info/WHEEL")), None)
        top_name = next((n for n in zf.namelist() if n.endswith(".dist-info/top_level.txt")), None)
        if not meta_name or not wheel_name:
            raise ValueError("ملف wheel ناقص metadata")
        metadata = Parser().parsestr(zf.read(meta_name).decode("utf-8", errors="replace"))
        wheel = zf.read(wheel_name).decode("utf-8", errors="replace")
        top = []
        if top_name:
            top = [x.strip() for x in zf.read(top_name).decode("utf-8", errors="replace").splitlines() if x.strip()]
        if "Wheel-Version:" not in wheel:
            raise ValueError("صيغة wheel غير صحيحة")
        if "Tag:" not in wheel:
            raise ValueError("wheel لا يحتوي على Tag")
        reqs = list(metadata.get_all("Requires-Dist") or [])
        flat = {
            "name": metadata.get("Name", ""),
            "version": metadata.get("Version", ""),
            "requires_python": metadata.get("Requires-Python", ""),
        }
        return flat, reqs, top


def _safe_member(name: str) -> str:
    name = name.replace("\\", "/")
    if name.startswith("/") or "\x00" in name:
        raise ValueError("مسار داخل wheel غير آمن")
    parts = [p for p in name.split("/") if p not in {"", "."}]
    if any(p == ".." for p in parts):
        raise ValueError("مسار داخل wheel غير آمن")
    return "/".join(parts)


def _download(url: str, destination: Path, callback: Any | None = None, expected_sha256: str | None = None) -> int:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp = destination.with_suffix(destination.suffix + ".part")
    if temp.exists():
        temp.unlink()
    req = urllib.request.Request(url, headers={"User-Agent": "Bayan-Python/1.0"})
    received = 0
    total = 0
    digest = hashlib.sha256()
    try:
        with urllib.request.urlopen(req, timeout=45) as resp, temp.open("wb") as out:
            try:
                total = int(resp.headers.get("Content-Length") or 0)
            except Exception:
                total = 0
            while True:
                chunk = resp.read(128 * 1024)
                if not chunk:
                    break
                out.write(chunk)
                digest.update(chunk)
                received += len(chunk)
                if callback is not None:
                    callback.emitPackage("download", received, total, destination.name)
        sha = digest.hexdigest()
        if expected_sha256 and sha.lower() != expected_sha256.lower():
            raise RuntimeError("فشل التحقق من checksum للملف")
        os.replace(temp, destination)
        return received
    except Exception:
        try:
            temp.unlink()
        except Exception:
            pass
        raise


def _wheel_cache_path(name: str, version: str, filename: str, sha256: str | None) -> Path:
    _, _, _, cache = _require_config()
    token = sha256 or hashlib.sha256(filename.encode("utf-8")).hexdigest()[:20]
    safe = re.sub(r"[^A-Za-z0-9._-]+", "_", f"{_norm_name(name)}-{version}-{token}.whl")
    return cache / "downloads" / safe


def _obtain_wheel(name: str, constraints: list[tuple[str, str]], callback: Any | None = None) -> tuple[Path, dict[str, Any]]:
    data = _get_json(name, callback)
    releases = data.get("releases") or {}
    requested_version = None
    if constraints and len(constraints) == 1 and constraints[0][0] == "==":
        requested_version = constraints[0][1]
    candidate = None
    # Search PyPI first for a compatible pure-Python or Android-specific wheel.
    for version in ([requested_version] if requested_version else sorted(releases.keys(), key=_version_parts, reverse=True)):
        if version is None:
            continue
        if constraints and not _satisfies(version, constraints):
            continue
        for file_info in releases.get(version, []):
            filename = file_info.get("filename", "")
            if not _wheel_compatible(filename):
                continue
            if not _requires_python_ok(file_info.get("requires_python") or (data.get("info") or {}).get("requires_python")):
                continue
            candidate = dict(file_info)
            candidate["version"] = version
            candidate["source"] = "pypi"
            break
        if candidate:
            break

    # If PyPI has no Android-compatible native wheel, use Chaquopy's Android wheel repo.
    if candidate is None:
        candidate = _chaquopy_wheel(name, requested_version)
        if candidate is not None and constraints and not _satisfies(candidate["version"], constraints):
            candidate = None

    if candidate is None:
        raise ValueError("لا توجد wheel متوافقة مع Python/Android/ABI الحاليين لهذا الإصدار")

    version = candidate["version"]
    filename = candidate["filename"]
    sha = ((candidate.get("digests") or {}).get("sha256") if candidate.get("source") == "pypi" else None)
    path = _wheel_cache_path(name, version, filename, sha)
    if path.is_file() and path.stat().st_size > 0:
        if sha:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            if digest.lower() != sha.lower():
                path.unlink()
            else:
                return path, candidate
        else:
            try:
                with zipfile.ZipFile(path) as zf:
                    zf.testzip()
                return path, candidate
            except Exception:
                path.unlink(missing_ok=True)
    url = candidate.get("url")
    if not url:
        # PyPI JSON gives this explicitly.
        url = next((f.get("url") for f in releases.get(version, []) if f.get("filename") == filename), None)
    if not url:
        raise RuntimeError("تعذر العثور على رابط wheel")
    if callback is not None:
        callback.emitPackage("download_start", 0, 0, filename)
    _download(url, path, callback, sha)
    try:
        with zipfile.ZipFile(path) as zf:
            zf.testzip()
    except Exception:
        path.unlink(missing_ok=True)
        raise RuntimeError("الملف المنزّل ليس wheel صالحاً")
    return path, candidate


def _plan_package(norm: str, constraints: list[tuple[str, str]], callback: Any, plan: list[tuple[Path, dict[str, Any], list[str], list[str]]], visiting: set[str]) -> None:
    installed = _installed_version(norm)
    if installed and _satisfies(installed, constraints):
        return
    if norm in visiting:
        raise ValueError(f"اعتماد دائري اكتُشف عند {norm}")
    visiting.add(norm)
    wheel_path, source_info = _obtain_wheel(norm, constraints, callback)
    metadata, reqs, top = _read_metadata_from_wheel(wheel_path)
    actual_norm = _norm_name(metadata["name"] or norm)
    if actual_norm != norm:
        norm = actual_norm
    if not _satisfies(metadata["version"], constraints):
        raise ValueError(f"الإصدار {metadata['version']} لا يطابق الطلب")
    if not _requires_python_ok(metadata.get("requires_python")):
        raise ValueError("الحزمة لا تدعم إصدار Python الحالي")
    for raw_req in reqs:
        parsed = _req_parts(raw_req)
        if parsed is None:
            continue
        dep_norm, dep_constraints = parsed
        _plan_package(dep_norm, dep_constraints, callback, plan, visiting)
    if not any(_norm_name(meta["name"]) == actual_norm and meta["version"] == metadata["version"] for _, meta, _, _ in plan):
        plan.append((wheel_path, metadata, reqs, top))
    visiting.remove(norm)


def _extract_wheel(path: Path, staging: Path) -> tuple[list[str], str]:
    staging.mkdir(parents=True, exist_ok=True)
    files: list[str] = []
    dist_info = None
    with zipfile.ZipFile(path, "r") as zf:
        for member in zf.infolist():
            if member.is_dir():
                continue
            safe = _safe_member(member.filename)
            if not safe:
                continue
            if ".data/" in safe:
                # Only allow purelib/platlib targets. Scripts/data outside the
                # import tree are not meaningful for Bayan's runtime installer.
                marker = ".data/"
                _, rest = safe.split(marker, 1)
                if rest.startswith("purelib/") or rest.startswith("platlib/"):
                    safe = rest.split("/", 1)[1]
                else:
                    raise ValueError("هذه wheel تستخدم مسارات تثبيت خارج site-packages")
            target = (staging / safe).resolve()
            if staging.resolve() not in target.parents and target != staging.resolve():
                raise ValueError("wheel تحتوي مساراً خارج مجلد التثبيت")
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(member, "r") as src, target.open("wb") as dst:
                shutil.copyfileobj(src, dst, length=128 * 1024)
            files.append(safe)
            if safe.endswith(".dist-info/METADATA"):
                dist_info = safe.rsplit("/", 1)[0]
    if not dist_info:
        raise ValueError("wheel لا تحتوي dist-info")
    return files, dist_info


def _record_paths(dist_info: Path) -> list[str]:
    record = dist_info / "RECORD"
    if not record.is_file():
        return []
    out: list[str] = []
    with record.open("r", newline="", encoding="utf-8", errors="replace") as fh:
        for row in csv.reader(fh):
            if row and row[0]:
                safe = _safe_member(row[0])
                if safe:
                    out.append(safe)
    return out


def _remove_distribution_files(dist_info: Path, site: Path, backup_root: Path, backed: set[str]) -> None:
    touched_dirs: set[Path] = set()
    for rel in _record_paths(dist_info):
        target = (site / rel).resolve()
        if site.resolve() not in target.parents and target != site.resolve():
            continue
        if not target.exists() and not target.is_symlink():
            continue
        if rel in backed:
            continue
        backup = backup_root / rel
        backup.parent.mkdir(parents=True, exist_ok=True)
        os.replace(target, backup)
        backed.add(rel)
        parent = target.parent
        while site.resolve() in parent.parents or parent == site.resolve():
            touched_dirs.add(parent)
            if parent == site.resolve():
                break
            parent = parent.parent
    # Python can leave bytecode behind in __pycache__. Keeping a stale package
    # directory can make it importable as a namespace package after uninstall,
    # so remove caches belonging to directories touched by this distribution.
    for directory in touched_dirs:
        pycache = directory / "__pycache__"
        if pycache.is_dir():
            shutil.rmtree(pycache, ignore_errors=True)


def _install_from_staging(staging: Path, files: list[str], site: Path, backup_root: Path, backed: set[str], installed_now: list[str]) -> None:
    for rel in files:
        src = staging / rel
        dst = site / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if dst.exists() or dst.is_symlink():
            if rel not in backed:
                backup = backup_root / rel
                backup.parent.mkdir(parents=True, exist_ok=True)
                os.replace(dst, backup)
                backed.add(rel)
        os.replace(src, dst)
        installed_now.append(rel)


def _cleanup_empty_dirs(root: Path) -> None:
    if not root.exists():
        return
    for directory in sorted([p for p in root.rglob("*") if p.is_dir()], key=lambda p: len(p.parts), reverse=True):
        try:
            directory.rmdir()
        except OSError:
            pass


def _clear_site_modules() -> None:
    if _SITE is None:
        return
    prefix = str(_SITE.resolve())
    for name, module in list(sys.modules.items()):
        if not module or name == __name__:
            continue
        try:
            location = getattr(module, "__file__", None)
            if location and str(Path(location).resolve()).startswith(prefix + os.sep):
                sys.modules.pop(name, None)
        except Exception:
            pass
    importlib.invalidate_caches()


def _current_packages() -> list[dict[str, Any]]:
    _, _, site, _ = _require_config()
    out: list[dict[str, Any]] = []
    for dist in sorted(site.glob("*.dist-info"), key=lambda p: p.name.lower()):
        meta_file = dist / "METADATA"
        if not meta_file.is_file():
            continue
        try:
            meta = Parser().parsestr(meta_file.read_text("utf-8", errors="replace"))
            name = meta.get("Name", "").strip()
            version = meta.get("Version", "").strip()
            if not name or not version:
                continue
            size = 0
            for rel in _record_paths(dist):
                p = site / rel
                try:
                    if p.is_file():
                        size += p.stat().st_size
                except OSError:
                    pass
            out.append({"name": name, "version": version, "size": size})
        except Exception:
            continue
    return out


def list_installed() -> str:
    return json.dumps(_current_packages(), ensure_ascii=False)


def _latest_compatible_for(name: str) -> dict[str, Any]:
    data = _get_json(name)
    releases = data.get("releases") or {}
    for version in sorted(releases.keys(), key=_version_parts, reverse=True):
        files = releases.get(version, [])
        if any(_wheel_compatible(f.get("filename", "")) and _requires_python_ok(f.get("requires_python") or (data.get("info") or {}).get("requires_python")) for f in files):
            f = next(f for f in files if _wheel_compatible(f.get("filename", "")) and _requires_python_ok(f.get("requires_python") or (data.get("info") or {}).get("requires_python")))
            return {"version": version, "size": f.get("size") or 0, "compatible": True}
    native = _chaquopy_wheel(name)
    if native:
        return {"version": native["version"], "size": 0, "compatible": True}
    return {"version": None, "size": 0, "compatible": False}


def catalog_status() -> str:
    def one(item: dict[str, str]) -> dict[str, Any]:
        name = item["name"]
        installed = _installed_version(_norm_name(name))
        try:
            latest = _latest_compatible_for(name)
        except Exception as exc:
            latest = {"version": None, "size": 0, "compatible": False, "error": str(exc)}
        return {
            **item,
            "installedVersion": installed,
            "latestVersion": latest.get("version"),
            "latestSize": latest.get("size", 0),
            "compatible": latest.get("compatible", False),
            "updateAvailable": bool(installed and latest.get("version") and _cmp_version(installed, latest.get("version")) < 0),
            "error": latest.get("error", ""),
        }

    # Catalog lookups are network-bound. Keep Flutter responsive and avoid
    # making seven PyPI lookups serially on the Python bridge thread.
    with ThreadPoolExecutor(max_workers=min(6, len(CATALOG))) as pool:
        futures = [pool.submit(one, item) for item in CATALOG]
        results = [future.result() for future in futures]
    return json.dumps(results, ensure_ascii=False)


def _store_metadata(last_result: dict[str, Any]) -> None:
    if _METADATA is None:
        return
    path = _METADATA / "packages.json"
    payload = {"python": PYTHON_VERSION, "updated": int(time.time()), "packages": _current_packages(), "last": last_result}
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def install_package(spec: str, callback: Any, job_id: str) -> str:
    with _PACKAGE_LOCK:
        callback.emitPackage("start", 0, 0, "بدء التثبيت")
        root_norm, root_constraints = _parse_spec(spec)
        plan: list[tuple[Path, dict[str, Any], list[str], list[str]]] = []
        _plan_package(root_norm, root_constraints, callback, plan, set())
        if not plan:
            installed = _installed_version(root_norm)
            result = {"ok": True, "name": root_norm, "version": installed or "", "already": True}
            callback.emitPackage("done", 1, 1, "المكتبة مثبتة بالفعل")
            _store_metadata(result)
            return json.dumps(result, ensure_ascii=False)

        _, _, site, cache = _require_config()
        transaction = Path(tempfile.mkdtemp(prefix="txn-", dir=str(cache / "tmp")))
        backup_root = transaction / "backup"
        install_root = transaction / "install"
        backed: set[str] = set()
        installed_now: list[str] = []
        primary_name = root_norm
        primary_version = ""
        try:
            callback.emitPackage("dependencies", 0, len(plan), f"تم العثور على {len(plan)} حزمة")
            for index, (wheel_path, metadata, reqs, top) in enumerate(plan, 1):
                norm = _norm_name(metadata["name"])
                callback.emitPackage("verify", index - 1, len(plan), f"التحقق من {metadata['name']} {metadata['version']}")
                # Remove older distribution contents into rollback storage.
                old = _distribution_record(norm)
                if old and old[1]["version"] != metadata["version"]:
                    _remove_distribution_files(old[0], site, backup_root, backed)
                stage = install_root / re.sub(r"[^A-Za-z0-9_.-]+", "_", f"{norm}-{metadata['version']}")
                files, _ = _extract_wheel(wheel_path, stage)
                callback.emitPackage("install", index - 1, len(plan), f"تثبيت {metadata['name']} {metadata['version']}")
                _install_from_staging(stage, files, site, backup_root, backed, installed_now)
                if norm == primary_name:
                    primary_version = metadata["version"]
                # Drop cached modules from the shared site-packages tree so updates
                # become visible to the next import in the same Python process.
                _clear_site_modules()
                if callback.shouldStop():
                    raise RuntimeError("تم إيقاف التثبيت")

            # Verify the primary distribution by importing a top-level module.
            _clear_site_modules()
            primary = next((item for item in plan if _norm_name(item[1]["name"]) == primary_name), None)
            if primary is None:
                raise RuntimeError("لم تكتمل خطة تثبيت المكتبة المطلوبة")
            top_levels = primary[3] or [primary_name.replace("-", "_")]
            import_errors = []
            tested = False
            for mod in top_levels:
                if not re.match(r"^[A-Za-z_][A-Za-z0-9_.]*$", mod):
                    continue
                try:
                    importlib.invalidate_caches()
                    importlib.import_module(mod)
                    tested = True
                    break
                except Exception as exc:
                    import_errors.append(f"{mod}: {exc}")
            if not tested:
                raise RuntimeError("تعذر اختبار import بعد التثبيت: " + "; ".join(import_errors[:3]))

            _cleanup_empty_dirs(site)
            result = {"ok": True, "name": primary_name, "version": primary_version, "already": False}
            callback.emitPackage("done", len(plan), len(plan), f"تم تثبيت {primary_name} {primary_version}")
            _store_metadata(result)
            return json.dumps(result, ensure_ascii=False)
        except Exception as exc:
            callback.emitPackage("rollback", 0, 0, "استعادة الحالة السابقة")
            for rel in reversed(installed_now):
                target = site / rel
                try:
                    if target.exists() or target.is_symlink():
                        target.unlink()
                except Exception:
                    pass
            for rel in sorted(backed, key=lambda x: len(x.split("/"))):
                backup = backup_root / rel
                target = site / rel
                if backup.exists() or backup.is_symlink():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    try:
                        os.replace(backup, target)
                    except Exception:
                        pass
            _cleanup_empty_dirs(site)
            result = {"ok": False, "name": root_norm, "error": str(exc)}
            callback.emitPackage("error", 0, 0, str(exc))
            _store_metadata(result)
            return json.dumps(result, ensure_ascii=False)
        finally:
            shutil.rmtree(transaction, ignore_errors=True)
            _clear_site_modules()


def remove_package(name: str) -> str:
    with _PACKAGE_LOCK:
        norm, _ = _parse_spec(name)
        found = _distribution_record(norm)
        if not found:
            return json.dumps({"ok": False, "error": "المكتبة غير مثبتة"}, ensure_ascii=False)
        _, _, site, cache = _require_config()
        transaction = Path(tempfile.mkdtemp(prefix="rm-", dir=str(cache / "tmp")))
        backup = transaction / "backup"
        backed: set[str] = set()
        try:
            _remove_distribution_files(found[0], site, backup, backed)
            _cleanup_empty_dirs(site)
            _store_metadata({"ok": True, "name": found[1]["name"], "version": found[1]["version"], "removed": True})
            return json.dumps({"ok": True, "name": found[1]["name"], "version": found[1]["version"]}, ensure_ascii=False)
        except Exception as exc:
            for rel in sorted(backed, key=lambda x: len(x.split("/"))):
                src = backup / rel
                dst = site / rel
                if src.exists() or src.is_symlink():
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    try:
                        os.replace(src, dst)
                    except Exception:
                        pass
            return json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False)
        finally:
            shutil.rmtree(transaction, ignore_errors=True)
            importlib.invalidate_caches()
