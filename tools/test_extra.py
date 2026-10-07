"""Regression tests for bugs found in the Bayan runtime.

1. Contract: every method that bayan_runtime.py calls on the Android callback
   objects must exist in MainActivity.kt (RunCallback / PackageCallback).
   The old tests used a fake Python callback that had every method, so a
   missing Kotlin method (PackageCallback.shouldStop) went unnoticed.
2. Wheel/version parsing, pre-release/yanked handling, `.data` wheels,
   dependency cycles, PyPI Simple-API fallback, throttled stop checks.
"""
from __future__ import annotations

import ast
import hashlib
import importlib.util
import json
import re
import sys
import tempfile
import threading
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "bayan_runtime.py"
KOTLIN = ROOT / "MainActivity.kt"

spec = importlib.util.spec_from_file_location("bayan_runtime_extra_target", RUNTIME)
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


# ---------------------------------------------------------------------------
# 1. Kotlin <-> Python contract
# ---------------------------------------------------------------------------
def kotlin_class_methods(source: str, class_name: str) -> set[str]:
    start = re.search(rf"\bclass\s+{class_name}\b[^{{]*\{{", source)
    assert start, f"{class_name} not found in MainActivity.kt"
    depth = 1
    i = start.end()
    while depth and i < len(source):
        depth += {"{": 1, "}": -1}.get(source[i], 0)
        i += 1
    body = source[start.end() : i]
    return set(re.findall(r"\bfun\s+(\w+)\s*\(", body))


def callback_calls(node: ast.AST) -> set[str]:
    found: set[str] = set()
    for sub in ast.walk(node):
        if not isinstance(sub, ast.Call) or not isinstance(sub.func, ast.Attribute):
            continue
        owner = sub.func.value
        is_cb = (isinstance(owner, ast.Name) and owner.id == "callback") or (
            isinstance(owner, ast.Attribute) and owner.attr == "callback"
        )
        if is_cb:
            found.add(sub.func.attr)
    return found


def test_kotlin_contract() -> None:
    kt = KOTLIN.read_text(encoding="utf-8")
    run_methods = kotlin_class_methods(kt, "RunCallback")
    pkg_methods = kotlin_class_methods(kt, "PackageCallback")
    tree = ast.parse(RUNTIME.read_text(encoding="utf-8"))

    run_nodes = {"run_script", "_CallbackStream", "_CallbackStdin", "_trace_factory"}
    run_used: set[str] = set()
    pkg_used: set[str] = set()
    for node in tree.body:
        if not isinstance(node, (ast.FunctionDef, ast.ClassDef)):
            continue
        used = callback_calls(node)
        if node.name in run_nodes:
            run_used |= used
        elif node.name == "_should_stop":
            run_used |= used
            pkg_used |= used
        else:
            pkg_used |= used

    missing_run = sorted(run_used - run_methods)
    missing_pkg = sorted(pkg_used - pkg_methods)
    assert not missing_run, f"RunCallback is missing: {missing_run}"
    assert not missing_pkg, f"PackageCallback is missing: {missing_pkg}"


def test_build_disables_shrink() -> None:
    wf = (ROOT / ".github" / "workflows" / "build.yml").read_text(encoding="utf-8")
    line = next(l for l in wf.splitlines() if "flutter build apk" in l and "run:" in l)
    assert "--no-shrink" in line, "R8 would rename RunCallback/PackageCallback again"


# ---------------------------------------------------------------------------
# 2. Parsing helpers
# ---------------------------------------------------------------------------
def test_wheel_filename_build_tag() -> None:
    info = mod._parse_wheel_filename("PyYAML-6.0.2-0-cp313-cp313-android_21_arm64_v8a.whl")
    assert info and info["version"] == "6.0.2" and info["platform"] == "android_21_arm64_v8a", info
    info = mod._parse_wheel_filename("requests-2.32.3-py3-none-any.whl")
    assert info and info["version"] == "2.32.3" and info["abi"] == "none", info
    assert mod._parse_wheel_filename("not-a-wheel.tar.gz") is None


def test_versions() -> None:
    v = mod._cmp_version
    assert v("1.0", "1.0.0") == 0
    assert v("1.0.dev1", "1.0a1") < 0 < v("1.0", "1.0rc1")
    assert v("2.0.0rc1", "1.9.9") > 0
    assert v("1.0.post1", "1.0") > 0
    # tuples must always be comparable (old code raised TypeError here)
    assert v("garbage", "0") in (-1, 0, 1)
    assert mod._is_prerelease("22.0b1") and mod._is_prerelease("1.0.dev3")
    assert not mod._is_prerelease("1.2.3")
    assert mod._satisfies("1.4.2", [("==", "1.4.*")]) and not mod._satisfies("1.5.0", [("==", "1.4.*")])
    assert mod._satisfies("2.0", [(">=", "1.0"), ("<", "3")])
    assert mod._parse_spec("requests[socks]>=2.0,<3") == ("requests", [(">=", "2.0"), ("<", "3")])


def test_markers() -> None:
    mod._configure_android(35, "arm64-v8a")
    assert mod._eval_marker('platform_machine == "aarch64"')
    assert mod._eval_marker('platform_python_implementation == "CPython"')
    assert not mod._eval_marker('sys_platform == "win32"')
    assert not mod._eval_marker('extra == "socks"')


# ---------------------------------------------------------------------------
# 3. Installer behaviour
# ---------------------------------------------------------------------------
class Cb:
    """Callback that, like the real PackageCallback, has no shouldStop-less gaps."""

    def __init__(self) -> None:
        self.events: list[tuple] = []

    def shouldStop(self) -> bool:
        return False

    def emitPackage(self, *values) -> None:
        self.events.append(values)


class CbWithoutStop(Cb):
    shouldStop = None  # type: ignore[assignment]

    def __getattribute__(self, name):
        if name == "shouldStop":
            raise AttributeError(name)
        return object.__getattribute__(self, name)


def write_wheel(root: Path, name: str, version: str, files: dict[str, str], requires: list[str] | None = None, top_level: bool = True) -> Path:
    norm = name.replace("-", "_")
    dist = f"{norm}-{version}.dist-info"
    wheel = root / f"{norm}-{version}-py3-none-any.whl"
    meta = (
        "Metadata-Version: 2.1\n"
        f"Name: {name}\nVersion: {version}\nRequires-Python: >=3.8\n"
        + "".join(f"Requires-Dist: {r}\n" for r in (requires or []))
        + "\n"
    )
    content = dict(files)
    content[f"{dist}/METADATA"] = meta
    content[f"{dist}/WHEEL"] = "Wheel-Version: 1.0\nGenerator: t\nRoot-Is-Purelib: true\nTag: py3-none-any\n"
    if top_level:
        content[f"{dist}/top_level.txt"] = f"{norm}\n"
    content[f"{dist}/RECORD"] = "\n".join(f"{p},," for p in [*content, f"{dist}/RECORD"]) + "\n"
    with zipfile.ZipFile(wheel, "w") as zf:
        for path, text in content.items():
            zf.writestr(path, text)
    return wheel


def file_info(wheel: Path, **extra) -> dict:
    return {
        "filename": wheel.name,
        "url": wheel.as_uri(),
        "size": wheel.stat().st_size,
        "digests": {"sha256": hashlib.sha256(wheel.read_bytes()).hexdigest()},
        "requires_python": ">=3.8",
        **extra,
    }


def test_candidate_selection() -> None:
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        stable = write_wheel(root, "pkg", "1.0.0", {"pkg/__init__.py": ""})
        pre_dir = root / "pre"
        pre_dir.mkdir()
        pre = write_wheel(pre_dir, "pkg", "2.0.0rc1", {"pkg/__init__.py": ""})
        yk_dir = root / "yk"
        yk_dir.mkdir()
        yanked = write_wheel(yk_dir, "pkg", "1.5.0", {"pkg/__init__.py": ""})
        data = {
            "releases": {
                "1.0.0": [file_info(stable)],
                "2.0.0rc1": [file_info(pre)],
                "1.5.0": [file_info(yanked, yanked=True)],
            }
        }
        pick = mod._select_pypi_candidate(data, [])
        assert pick and pick["version"] == "1.0.0", pick  # not the rc, not the yanked file
        # explicit pin on a pre-release is honoured
        pick = mod._select_pypi_candidate(data, [("==", "2.0.0rc1")])
        assert pick and pick["version"] == "2.0.0rc1", pick


def with_env(fn):
    with tempfile.TemporaryDirectory(prefix="bayan-extra-") as td:
        root = Path(td)
        mod.configure(str(root / "env"))
        mod._configure_android(35, "arm64-v8a")
        saved = (mod._get_json, mod._chaquopy_wheel)
        mod._CACHE_JSON.clear()
        try:
            fn(root)
        finally:
            mod._get_json, mod._chaquopy_wheel = saved
            mod._clear_site_modules()


def install(spec_text: str, lookup: dict, cb=None) -> dict:
    mod._get_json = lambda name, callback=None: lookup[mod._norm_name(name)]
    mod._chaquopy_wheel = lambda *a, **k: None
    return json.loads(mod.install_package(spec_text, cb or Cb(), "job"))


def test_install_flows() -> None:
    def body(root: Path) -> None:
        # a) wheel without top_level.txt, module name differs from dist name,
        #    plus a `.data/scripts` entry that used to abort the install.
        w = write_wheel(
            root,
            "python-thing",
            "1.0.0",
            {
                "thing/__init__.py": "VALUE = 5\n",
                "python_thing-1.0.0.data/scripts/thing-cli": "#!/bin/sh\n",
                "python_thing-1.0.0.data/purelib/extra_mod.py": "X = 1\n",
            },
            top_level=False,
        )
        res = install("python-thing", {"python-thing": {"releases": {"1.0.0": [file_info(w)]}}})
        assert res["ok"] is True, res
        assert (mod._SITE / "thing" / "__init__.py").is_file()
        assert (mod._SITE / "extra_mod.py").is_file()
        assert not any("scripts" in str(p) for p in mod._SITE.rglob("*"))
        removed = json.loads(mod.remove_package("python-thing"))
        assert removed["ok"], removed
        assert not (mod._SITE / "extra_mod.py").exists(), "purelib data file left behind"

        # b) dependency cycle must not fail the install
        a = write_wheel(root, "cyc-a", "1.0", {"cyc_a/__init__.py": "V=1\n"}, ["cyc-b"])
        b = write_wheel(root, "cyc-b", "1.0", {"cyc_b/__init__.py": "V=2\n"}, ["cyc-a"])
        lookup = {
            "cyc-a": {"releases": {"1.0": [file_info(a)]}},
            "cyc-b": {"releases": {"1.0": [file_info(b)]}},
        }
        res = install("cyc-a", lookup)
        assert res["ok"] is True, res
        assert mod._installed_version("cyc-a") == "1.0" and mod._installed_version("cyc-b") == "1.0"

        # c) a callback that lacks shouldStop (old PackageCallback) must not break installs
        c = write_wheel(root, "no-stop", "1.0", {"no_stop/__init__.py": "V=3\n"})
        res = install("no-stop", {"no-stop": {"releases": {"1.0": [file_info(c)]}}}, CbWithoutStop())
        assert res["ok"] is True, res

    with_env(body)


def test_simple_api_fallback() -> None:
    mod._CACHE_JSON.clear()
    calls: list[str] = []

    def fake_http(url: str, accept=None, timeout=25, attempts=2) -> bytes:
        calls.append(url)
        if url.endswith("/json"):
            return json.dumps({"info": {"requires_python": ">=3.8"}}).encode()  # no "releases"
        assert accept and "simple" in accept
        return json.dumps(
            {
                "files": [
                    {
                        "filename": "demo-1.2.0-py3-none-any.whl",
                        "url": "https://files.example/demo-1.2.0-py3-none-any.whl",
                        "hashes": {"sha256": "ab" * 32},
                        "requires-python": ">=3.8",
                        "size": 10,
                    },
                    {"filename": "demo-1.2.0.tar.gz", "url": "x", "hashes": {}},
                ]
            }
        ).encode()

    saved = mod._http_read
    mod._http_read = fake_http
    try:
        data = mod._get_json("demo")
        assert list(data["releases"]) == ["1.2.0"], data
        pick = mod._select_pypi_candidate(data, [])
        assert pick and pick["version"] == "1.2.0" and pick["digests"]["sha256"] == "ab" * 32
    finally:
        mod._http_read = saved
        mod._CACHE_JSON.clear()


# ---------------------------------------------------------------------------
# 4. Script execution
# ---------------------------------------------------------------------------
class RunCb:
    def __init__(self, inputs=None) -> None:
        self.inputs = list(inputs or [])
        self.out: list[tuple[str, str]] = []
        self.events: list[tuple] = []
        self.stop = False
        self.stop_calls = 0

    def shouldStop(self) -> bool:
        self.stop_calls += 1
        return self.stop

    def emitOutput(self, kind, text): self.out.append((kind, text))
    def emitError(self, text): self.events.append(("error", text))
    def emitInput(self, prompt): self.events.append(("input", prompt))
    def requestInput(self, prompt): return self.inputs.pop(0) if self.inputs else ""
    def emitState(self, state): self.events.append(("state", state))
    def emitExit(self, code): self.events.append(("exit", code))


def run(source: str, cb: RunCb, root: Path, name: str = "t.py") -> int:
    path = root / name
    path.write_text(source, encoding="utf-8")
    return mod.run_script(str(path), cb)


def test_run_script_behaviour() -> None:
    with tempfile.TemporaryDirectory(prefix="bayan-run-") as td:
        root = Path(td)
        mod.configure(str(root / "env"))

        # the exact script from the bug report, with an Arabic file name
        cb = RunCb(["علي"])
        code = run('name = input("اكتب اسمك: ")\nprint("أهلاً بك يا " + name)\n', cb, root, "علي.py")
        assert code == 0
        assert "أهلاً بك يا علي" in "".join(t for k, t in cb.out if k == "stdout")
        assert ("input", "اكتب اسمك: ") in cb.events

        # traceback shows the user's frame, not the runner internals
        cb = RunCb()
        assert run("def f():\n    return 1/0\nf()\n", cb, root) == 1
        err = "".join(t for k, t in cb.out if k == "stderr")
        assert "ZeroDivisionError" in err and "bayan_runtime" not in err and "exec(code" not in err, err

        # sys.exit("message") prints the message, exit code 1; sys.exit(3) is silent
        cb = RunCb()
        assert run("import sys\nsys.exit('bye')\n", cb, root) == 1
        assert "bye" in "".join(t for k, t in cb.out if k == "stderr")
        cb = RunCb()
        assert run("import sys\nsys.exit(3)\n", cb, root) == 3
        assert not [t for k, t in cb.out if k == "stderr"]

        # syntax errors are reported, not raised
        cb = RunCb()
        assert run("print('x'\n", cb, root) == 1
        assert "SyntaxError" in "".join(t for k, t in cb.out if k == "stderr")

        # single-line busy loop stays stoppable, and the Java bridge is polled
        # sparingly (old code asked on every opcode)
        cb = RunCb()
        t = threading.Thread(target=lambda: run("while True: pass\n", cb, root))
        t.start()
        time.sleep(0.3)
        polled = cb.stop_calls
        cb.stop = True
        t.join(3)
        assert not t.is_alive(), "single-line loop could not be stopped"
        assert ("exit", 130) in cb.events
        assert polled < 200, f"stop flag polled {polled} times in 0.3s"

        # a plain loop must not be crippled by tracing
        cb = RunCb()
        start = time.monotonic()
        assert run("s = 0\nfor i in range(300000):\n    s += i\n", cb, root) == 0
        assert time.monotonic() - start < 5, "loop is far too slow"

        # callback without shouldStop must not crash the runner
        class NoStop(RunCb):
            def __getattribute__(self, name):
                if name == "shouldStop":
                    raise AttributeError(name)
                return object.__getattribute__(self, name)

        cb = NoStop()
        assert run("print('ok')\n", cb, root) == 0


def main() -> None:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in tests:
        fn()
        print(f"  ok  {fn.__name__}")
    print("Bayan extra tests: PASS")


if __name__ == "__main__":
    main()
