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

    run_nodes = {"run_script", "_CallbackStream", "_CallbackStdin", "_trace_factory", "_OutputHub"}
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
    assert "tools/verify_apk.py" in wf, "CI must fail when the APK lost the Kotlin callbacks"


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
    def emitMissing(self, payload): self.events.append(("missing", payload))


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


# ---------------------------------------------------------------------------
# 5. R8 safety net, worker-thread behaviour, batching
# ---------------------------------------------------------------------------
def _load_tool(name: str):
    spec_ = importlib.util.spec_from_file_location(f"bayan_tool_{name}", ROOT / "tools" / f"{name}.py")
    assert spec_ and spec_.loader
    m = importlib.util.module_from_spec(spec_)
    spec_.loader.exec_module(m)
    return m


def _run_in_thread(source: str, cb: "RunCb", root: Path, stop_after: float | None = None, limit: float = 8.0):
    """Run a script on a worker thread (like Android) and optionally press Stop."""
    result: dict = {}

    def target() -> None:
        result["code"] = run(source, cb, root)

    t = threading.Thread(target=target, name="Bayan-Python")
    started = time.monotonic()
    t.start()
    if stop_after is not None:
        time.sleep(stop_after)
        cb.stop = True
    t.join(limit)
    assert not t.is_alive(), "script did not finish in time"
    return result.get("code"), time.monotonic() - started


def test_missing_callback_gives_clear_message() -> None:
    class Stripped:  # what an R8-minified build looks like to Python
        pass

    with tempfile.TemporaryDirectory(prefix="bayan-r8-") as td:
        root = Path(td)
        mod.configure(str(root / "env"))
        (root / "t.py").write_text("print(1)\n", encoding="utf-8")
        for call in (
            lambda: mod.run_script(str(root / "t.py"), Stripped()),
            lambda: mod.install_package("requests", Stripped(), "job"),
        ):
            try:
                call()
            except RuntimeError as exc:
                assert "R8" in str(exc) and "no-shrink" in str(exc), str(exc)
            else:
                raise AssertionError("a stripped callback must be reported, not ignored")


def test_keep_rules_and_apk_check() -> None:
    prep = _load_tool("prepare_android")
    with tempfile.TemporaryDirectory(prefix="bayan-keep-") as td:
        app = Path(td)
        prep.write_proguard_rules(app)
        rules = (app / "proguard-rules.pro").read_text(encoding="utf-8")
    pkg = re.search(r"^package\s+([\w.]+)", KOTLIN.read_text(encoding="utf-8"), re.M).group(1)
    assert f"{pkg}.BayanPythonBridge" in rules and "-keep" in rules, rules
    assert f"{pkg}.LogStore" in rules, "2.5D1: LogStore needs the usual keep rule"

    verify = _load_tool("verify_apk")
    good = b"\x00".join(n.encode() for n in verify.REQUIRED)
    with tempfile.TemporaryDirectory(prefix="bayan-apk-") as td:
        ok_apk, bad_apk = Path(td) / "ok.apk", Path(td) / "bad.apk"
        with zipfile.ZipFile(ok_apk, "w") as z:
            z.writestr("classes.dex", b"dex\n035\x00" + good)
        with zipfile.ZipFile(bad_apk, "w") as z:
            z.writestr("classes.dex", b"dex\n035\x00" + good.replace(b"emitState", b"a"))
        assert verify.missing_names(ok_apk) == []
        assert "emitState" in verify.missing_names(bad_apk)


def test_worker_thread_asyncio_and_signals() -> None:
    script = (
        "import asyncio, signal, threading\n"
        "assert threading.current_thread() is not threading.main_thread()\n"
        "signal.signal(signal.SIGTERM, lambda *a: None)\n"
        "async def main():\n"
        "    loop = asyncio.get_running_loop()\n"
        "    loop.add_signal_handler(signal.SIGINT, lambda: None)\n"
        "    await asyncio.sleep(0.05)\n"
        "    return 'asyncio-ok'\n"
        "loop = asyncio.get_event_loop()\n"
        "print(loop.run_until_complete(main()))\n"
        "print(asyncio.run(main()))\n"
    )
    with tempfile.TemporaryDirectory(prefix="bayan-aio-") as td:
        root = Path(td)
        mod.configure(str(root / "env"))
        cb = RunCb()
        code, _ = _run_in_thread(script, cb, root)
        text = "".join(t for k, t in cb.out)
        err = "".join(t for k, t in cb.out if k == "stderr")
        assert code == 0 and text.count("asyncio-ok") == 2, (code, text, err)
        # shims are removed again
        assert not getattr(mod.time.sleep, "__name__", "") == "bayan_sleep"


def test_stop_interrupts_sleep_and_idle_asyncio() -> None:
    with tempfile.TemporaryDirectory(prefix="bayan-stop-") as td:
        root = Path(td)
        mod.configure(str(root / "env"))
        for source in (
            "import time\nprint('start', flush=True)\ntime.sleep(60)\n",
            "import asyncio\nasync def main():\n    await asyncio.sleep(3600)\nasyncio.run(main())\n",
            "import asyncio\nasync def main():\n    await asyncio.Event().wait()\nasyncio.get_event_loop().run_until_complete(main())\n",
            # the python-telegram-bot run_polling() pattern
            "import asyncio, signal\nloop = asyncio.get_event_loop()\nloop.add_signal_handler(signal.SIGINT, loop.stop)\ntry:\n    loop.run_forever()\nfinally:\n    loop.close()\n",
        ):
            cb = RunCb()
            code, took = _run_in_thread(source, cb, root, stop_after=0.4, limit=6)
            assert code == 130 and ("exit", 130) in cb.events, (source, code, cb.events)
            assert took < 3, f"Stop took {took:.1f}s for: {source!r}"


def test_output_is_batched_and_ordered() -> None:
    with tempfile.TemporaryDirectory(prefix="bayan-out-") as td:
        root = Path(td)
        mod.configure(str(root / "env"))
        cb = RunCb()
        script = (
            "import sys\n"
            "for i in range(20000):\n"
            "    print(i)\n"
            "print('E1', file=sys.stderr)\n"
            "print('after')\n"
        )
        assert run(script, cb, root) == 0
        assert len(cb.out) < 400, f"{len(cb.out)} Java calls for 20000 prints"
        stdout = "".join(t for k, t in cb.out if k == "stdout")
        assert stdout.splitlines()[:3] == ["0", "1", "2"] and stdout.endswith("19999\nafter\n")
        kinds = [k for k, _ in cb.out]
        assert kinds[-3:] == ["stdout", "stderr", "stdout"] or kinds[-2:] == ["stderr", "stdout"], kinds[-4:]

        # output reaches the UI while the script is still sleeping (watchdog flush)
        cb = RunCb()
        done: dict = {}
        t = threading.Thread(target=lambda: done.setdefault("c", run("import time\nprint('early')\ntime.sleep(1.5)\n", cb, root)))
        t.start()
        time.sleep(0.5)
        assert "early" in "".join(x for k, x in cb.out), "output was held back until the script ended"
        t.join(5)

        # prompts are flushed before the input request
        cb = RunCb(["x"])
        assert run("print('before')\ninput('? ')\n", cb, root) == 0
        assert "before" in "".join(x for k, x in cb.out)


def test_script_environment_details() -> None:
    with tempfile.TemporaryDirectory(prefix="bayan-env-") as td:
        root = Path(td)
        mod.configure(str(root / "env"))
        cb = RunCb()
        script = (
            "import sys\n"
            "sys.stdout.reconfigure(encoding='utf-8')\n"
            "sys.stdout.buffer.write('مرحبا\\n'.encode('utf-8'))\n"
            "print(sys.argv[0].endswith('t.py'), len(sys.argv))\n"
        )
        assert run(script, cb, root) == 0
        text = "".join(t for k, t in cb.out)
        assert "مرحبا" in text and "True 1" in text, text
        assert sys.argv[0] != str(root / "t.py"), "sys.argv must be restored"

        # a non-daemon thread keeps the run alive (as CPython does) and Stop still works
        cb = RunCb()
        script = (
            "import threading, time\n"
            "def late():\n"
            "    time.sleep(0.4)\n"
            "    print('late-thread')\n"
            "threading.Thread(target=late).start()\n"
            "print('main-done')\n"
        )
        code, took = _run_in_thread(script, cb, root)
        assert code == 0 and "late-thread" in "".join(t for k, t in cb.out) and took >= 0.4

        cb = RunCb()
        script = "import threading, time\nthreading.Thread(target=lambda: [time.sleep(0.05) for _ in iter(int, 1)]).start()\n"
        code, took = _run_in_thread(script, cb, root, stop_after=0.4, limit=6)
        assert code == 130 and took < 3, (code, took)
        assert "StopRequested" not in "".join(t for k, t in cb.out), "Stop must not print a traceback from user threads"

        # daemon threads die with the run, like CPython exiting (no zombie bots)
        cb = RunCb()
        script = (
            "import threading, time\n"
            "t = threading.Thread(target=lambda: [time.sleep(0.02) for _ in iter(int, 1)], daemon=True, name='bayan-daemon-test')\n"
            "t.start()\n"
        )
        assert run(script, cb, root) == 0
        time.sleep(0.3)
        assert not [th for th in threading.enumerate() if th.name == "bayan-daemon-test"], "daemon thread outlived the run"


# ---------------------------------------------------------------------------
# 6. Missing-library cards (F2), availability check, progress events (F3)
# ---------------------------------------------------------------------------
def test_required_lists_match_kotlin_and_verify() -> None:
    """A callback Python needs must exist in Kotlin AND be checked after R8 (verify_apk)."""
    kt = KOTLIN.read_text(encoding="utf-8")
    run_methods = kotlin_class_methods(kt, "RunCallback")
    pkg_methods = kotlin_class_methods(kt, "PackageCallback")
    verify = _load_tool("verify_apk")
    for name in mod._RUN_CALLBACK_REQUIRED:
        assert name in run_methods, f"RunCallback.{name} missing in MainActivity.kt"
        assert name in verify.REQUIRED, f"{name} missing from tools/verify_apk.py REQUIRED"
    for name in mod._PACKAGE_CALLBACK_REQUIRED:
        assert name in pkg_methods, f"PackageCallback.{name} missing in MainActivity.kt"
        assert name in verify.REQUIRED, f"{name} missing from tools/verify_apk.py REQUIRED"
    rules = (ROOT / "tools" / "prepare_android.py").read_text(encoding="utf-8")
    assert "BayanPythonBridge$*" in rules, "proguard rule must cover the inner callback classes"


def test_import_name_to_package_name() -> None:
    table = {
        "cv2": "opencv-python", "PIL": "Pillow", "bs4": "beautifulsoup4", "yaml": "PyYAML",
        "telegram": "python-telegram-bot", "telebot": "pyTelegramBotAPI", "dotenv": "python-dotenv",
        "sklearn": "scikit-learn", "dateutil": "python-dateutil", "Crypto": "pycryptodome",
        "serial": "pyserial", "jwt": "PyJWT",
    }
    assert mod._IMPORT_TO_DIST == table


def _missing_of(source: str, root: Path, files: dict[str, str] | None = None) -> tuple[int, list[dict], str]:
    for name, text in (files or {}).items():
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
    cb = RunCb()
    code = run(source, cb, root, "main script.py")
    payloads = [json.loads(v) for k, v in cb.events if k == "missing"]
    err = "".join(t for k, t in cb.out if k == "stderr")
    return code, (payloads[0] if payloads else []), err


def test_missing_libraries_cards() -> None:
    with tempfile.TemporaryDirectory(prefix="bayan-missing-") as td:
        root = Path(td) / "مجلد بمسافات"
        root.mkdir()
        mod.configure(str(Path(td) / "env"))
        # an import name whose PyPI name differs (like cv2 -> opencv-python), with a fake name
        # so the test does not depend on what happens to be installed in this Python
        mod._IMPORT_TO_DIST["zzbayan_mapped"] = "zz-mapped-dist"

        # three missing libraries at once, the failing one first; stdlib, local files,
        # relative imports and try/except ImportError (that did not fail) are ignored
        source = (
            "import os, json\n"
            "import helper_local\n"
            "import zzbayan_alpha.sub\n"
            "from zzbayan_beta import thing\n"
            "try:\n"
            "    import zzbayan_optional\n"
            "except ImportError:\n"
            "    zzbayan_optional = None\n"
            "import zzbayan_mapped\n"
            "from . import sibling\n"
        )
        code, missing, err = _missing_of(source, root, {"helper_local.py": "X = 1\n"})
        assert code == 1 and "ModuleNotFoundError" in err, err
        names = [m["package"] for m in missing]
        assert names[0] == "zzbayan_alpha" and missing[0]["failed"] is True, missing
        assert set(names) == {"zzbayan_alpha", "zzbayan_beta", "zz-mapped-dist"}, missing
        assert next(m for m in missing if m["package"] == "zz-mapped-dist")["module"] == "zzbayan_mapped"
        assert all(m["failed"] is False for m in missing[1:])

        # an optional import that IS the one that failed is shown
        code, missing, _ = _missing_of(
            "try:\n    import zzbayan_gamma\nexcept ImportError:\n    raise\n", root
        )
        assert [m["package"] for m in missing] == ["zzbayan_gamma"], missing

        # other errors never produce cards, and neither does a clean run
        cb = RunCb()
        run("raise ValueError('x')\n", cb, root, "other.py")
        assert not [1 for k, _ in cb.events if k == "missing"]
        cb = RunCb()
        run("print('ok')\n", cb, root, "clean.py")
        assert not [1 for k, _ in cb.events if k == "missing"]

        # a missing submodule of an importable library is not a missing library
        (root / "pkgdir").mkdir(exist_ok=True)
        (root / "pkgdir" / "__init__.py").write_text("", encoding="utf-8")
        cb = RunCb()
        run("import pkgdir.nothing_here\n", cb, root, "sub.py")
        assert not [1 for k, _ in cb.events if k == "missing"]
        mod._IMPORT_TO_DIST.pop("zzbayan_mapped", None)


def test_availability_check() -> None:
    saved = (mod._latest_compatible_for, mod._chaquopy_wheel)
    try:
        def fake(name: str):
            if name == "good":
                return {"version": "1.0", "size": 5, "compatible": True}
            if name == "native-only":
                return {"version": None, "size": 0, "compatible": False}
            if name == "ghost":
                raise ValueError("not found")
            raise RuntimeError("offline")

        mod._latest_compatible_for = fake
        mod._chaquopy_wheel = lambda name, *a, **k: None
        res = {r["name"]: r for r in json.loads(mod.check_availability(json.dumps(["good", "native-only", "ghost", "net", "good"])))}
        assert set(res) == {"good", "native-only", "ghost", "net"}
        assert res["good"]["available"] is True and res["good"]["version"] == "1.0"
        assert res["native-only"]["available"] is False and res["native-only"]["reason"]
        assert res["ghost"]["available"] is False
        assert res["net"]["available"] is None, "a network error must not claim the library is unavailable"
        assert mod.check_availability("not json") == "[]"
    finally:
        mod._latest_compatible_for, mod._chaquopy_wheel = saved


def test_wheel_events_for_progress_bar() -> None:
    def body(root: Path) -> None:
        w = write_wheel(root, "evt-lib", "1.0.0", {"evt_lib/__init__.py": "V = 1\n"})
        info = file_info(w)
        info["size"] = w.stat().st_size
        cb = Cb()
        res = install("evt-lib", {"evt-lib": {"releases": {"1.0.0": [info]}}}, cb)
        assert res["ok"] is True, res
        stages = [e[0] for e in cb.events]
        assert "wheel" in stages or "wheel_cached" in stages, stages
        first = next(e for e in cb.events if e[0] in ("wheel", "wheel_cached"))
        assert first[1] == info["size"], first
        assert stages.index(first[0]) < stages.index("dependencies") < stages.index("done")

    with_env(body)


# ---------------------------------------------------------------------------
# Build 2A: tracebacks without Chaquopy noise, companion libraries
# ---------------------------------------------------------------------------
def _chaquopy_like(fn_name: str, filename: str, message: str = "No module named 'zzbayan_none'"):
    """A function whose frame looks like the ones Chaquopy adds to import errors."""
    ns: dict = {}
    exec(compile(f"def hook():\n    raise ModuleNotFoundError({message!r}, name='zzbayan_none')\n", filename, "exec"), ns)
    hook = ns["hook"]
    hook.__code__ = hook.__code__.replace(co_name=fn_name, co_qualname=fn_name)
    return hook


def _printed_traceback(call) -> str:
    import io

    buf = io.StringIO()
    try:
        call()
    except BaseException as exc:  # noqa: BLE001 - this is exactly what the runner does
        mod._print_user_traceback(exc, buf)
    return buf.getvalue()


def test_traceback_hides_chaquopy_frames() -> None:
    hook = _chaquopy_like("java.chaquopy.import_override", "import.pxi")
    user = compile("hook()\n", "/data/Bayan 777/ن.py", "exec")
    text = _printed_traceback(lambda: exec(user, {"hook": hook}))
    assert "import.pxi" not in text and "java.chaquopy" not in text, text
    assert 'ن.py", line 1' in text and "ModuleNotFoundError: No module named" in text, text

    # either signal alone is enough (file name OR function name)
    by_file = _printed_traceback(lambda: exec(user, {"hook": _chaquopy_like("other_name", "/x/y/import.pxi")}))
    by_name = _printed_traceback(lambda: exec(user, {"hook": _chaquopy_like("java.chaquopy.anything", "other.py")}))
    # (the printed source line of this very test mentions the names, so look at the frame headers)
    assert 'import.pxi", line' not in by_file and ", in other_name" not in by_file, by_file
    assert ", in java.chaquopy" not in by_name and 'other.py", line' not in by_name, by_name
    assert "ModuleNotFoundError" in by_file and "ModuleNotFoundError" in by_name

    # chained exceptions are cleaned too, and the chain text is kept
    chained = compile(
        "try:\n    hook()\nexcept ModuleNotFoundError as e:\n    raise RuntimeError('wrapped') from e\n",
        "/data/Bayan 777/chain.py", "exec")
    text = _printed_traceback(lambda: exec(chained, {"hook": hook}))
    assert "java.chaquopy" not in text and "import.pxi" not in text, text
    assert "RuntimeError: wrapped" in text and "direct cause" in text, text

    # a user frame in site-packages or a user function with a similar name stays
    keep = _chaquopy_like("chaquopy_helper", "my_import.pxi_notes.py")
    text = _printed_traceback(lambda: exec(user, {"hook": keep}))
    assert ", in chaquopy_helper" in text, text


def test_other_errors_keep_their_traceback_exactly() -> None:
    import io
    import traceback as tb_module

    def boom() -> None:
        exec(compile("print(zzbayan_missing_name)\n", "/data/Bayan 777/e.py", "exec"), {})

    caught: BaseException | None = None
    try:
        boom()
    except BaseException as exc:  # noqa: BLE001
        caught = exc
    assert caught is not None
    buf = io.StringIO()
    mod._print_user_traceback(caught, buf)
    expected = "".join(tb_module.format_exception(type(caught), caught, caught.__traceback__))
    assert buf.getvalue() == expected and "NameError" in expected, (buf.getvalue(), expected)

    syntax = _printed_traceback(lambda: compile("x = (\n", "/data/Bayan 777/s.py", "exec"))
    assert "SyntaxError" in syntax and "s.py" in syntax, syntax


def _marker_site_lookup(root: Path, spec: list[tuple[str, str, list[str]]]) -> dict:
    lookup: dict = {}
    for name, version, requires in spec:
        wheel = write_wheel(root, name, version, {f"{name.replace('-', '_')}/__init__.py": "V = 1\n"}, requires)
        lookup.setdefault(name, {"releases": {}})["releases"][version] = [file_info(wheel)]
    return lookup


def _has_marker(norm: str) -> bool:
    found = mod._distribution_record(norm)
    return bool(found and (found[0] / "REQUESTED").is_file())


def _packages_by_name() -> dict[str, dict]:
    return {p["name"]: p for p in mod._current_packages()}


def test_requested_marker_and_companion_fields() -> None:
    def body(root: Path) -> None:
        lookup = _marker_site_lookup(root, [
            # the markers/extras below must be ignored, or the plan would ask for names missing from the lookup
            ("mk-root", "1.0", ["mk-a", "mk-b>=1", 'mk-extra; extra == "socks"', 'mk-win; sys_platform == "win32"']),
            ("mk-a", "1.0", ["mk-c"]),
            ("mk-b", "1.0", []),
            ("mk-c", "1.0", []),
        ])
        res = install("mk-root", lookup)
        assert res["ok"] is True, res
        assert _has_marker("mk-root")
        assert not any(_has_marker(n) for n in ("mk-a", "mk-b", "mk-c")), "companions must not be marked"
        pk = _packages_by_name()
        assert {n: p["requested"] for n, p in pk.items()} == {"mk-root": True, "mk-a": False, "mk-b": False, "mk-c": False}
        assert pk["mk-root"]["requires"] == ["mk-a", "mk-b"], pk["mk-root"]
        assert pk["mk-root"]["requiredBy"] == []
        assert pk["mk-a"]["requiredBy"] == ["mk-root"] and pk["mk-a"]["requires"] == ["mk-c"]
        assert pk["mk-c"]["requiredBy"] == ["mk-a"]
        json.dumps(mod._current_packages())  # the channel carries it as JSON

        # asking for a companion explicitly later makes it a requested library too
        again = install("mk-a", lookup)
        assert again["ok"] and again.get("already") is True, again
        assert _has_marker("mk-a")
        assert _packages_by_name()["mk-a"]["requested"] is True
        assert _packages_by_name()["mk-c"]["requested"] is False

    with_env(body)


def test_pre_marker_libraries_are_classified_by_dependencies() -> None:
    def body(root: Path) -> None:
        lookup = _marker_site_lookup(root, [
            ("lg-root", "1.0", ["lg-dep"]), ("lg-dep", "1.0", []),
            ("cy-a", "1.0", ["cy-b"]), ("cy-b", "1.0", ["cy-a"]),
            ("cy-top", "1.0", ["cy-a"]),
        ])

        def strip_markers() -> None:
            for marker in mod._SITE.glob("*.dist-info/REQUESTED"):
                marker.unlink()

        assert install("lg-root", lookup)["ok"]
        strip_markers()  # what an install made before this feature looks like
        pk = _packages_by_name()
        assert pk["lg-root"]["requested"] is True and pk["lg-dep"]["requested"] is False, pk

        # a dependency cycle nobody else uses must stay visible (and removable)
        assert install("cy-a", lookup)["ok"]
        strip_markers()
        pk = _packages_by_name()
        assert pk["cy-a"]["requested"] is True and pk["cy-b"]["requested"] is True, pk

        # the same cycle reached from a real root is just companions of that root
        assert install("cy-top", lookup)["ok"]
        strip_markers()
        pk = _packages_by_name()
        assert pk["cy-top"]["requested"] is True
        assert pk["cy-a"]["requested"] is False and pk["cy-b"]["requested"] is False, pk

        # a dist-info without METADATA is ignored
        ghost = mod._SITE / "ghost_lib-1.0.dist-info"
        ghost.mkdir()
        (ghost / "RECORD").write_text("", encoding="utf-8")
        assert "ghost_lib" not in {n.replace("-", "_") for n in _packages_by_name()}

        # removing the root takes the whole cycle with it (no infinite loop)
        out = json.loads(mod.remove_package("cy-top"))
        assert out["ok"], out
        assert {c["name"] for c in out["alsoRemoved"]} == {"cy-a", "cy-b"}, out

    with_env(body)


def test_remove_takes_orphaned_companions_only() -> None:
    def body(root: Path) -> None:
        lookup = _marker_site_lookup(root, [
            ("rm-top1", "1.0", ["rm-shared", "rm-only1"]),
            ("rm-only1", "1.0", ["rm-deep1"]),
            ("rm-deep1", "1.0", []),
            ("rm-shared", "1.0", []),
            ("rm-top2", "1.0", ["rm-shared"]),
        ])
        assert install("rm-top1", lookup)["ok"] and install("rm-top2", lookup)["ok"]

        out = json.loads(mod.remove_package("rm-top1"))
        assert out["ok"], out
        assert sorted(c["name"] for c in out["alsoRemoved"]) == ["rm-deep1", "rm-only1"], out
        assert set(_packages_by_name()) == {"rm-top2", "rm-shared"}, "a companion another library needs must stay"
        assert not (mod._SITE / "rm_only1").exists() and not (mod._SITE / "rm_deep1").exists()

        out = json.loads(mod.remove_package("rm-top2"))
        assert out["ok"] and [c["name"] for c in out["alsoRemoved"]] == ["rm-shared"], out
        assert mod._current_packages() == []
        assert not list(mod._SITE.glob("*.dist-info")), "the marker must not keep a dist-info folder alive"

        missing = json.loads(mod.remove_package("rm-top1"))
        assert missing["ok"] is False

    with_env(body)


def test_explicitly_requested_companion_survives_removal() -> None:
    def body(root: Path) -> None:
        lookup = _marker_site_lookup(root, [
            ("ex-root", "1.0", ["ex-a", "ex-b"]),
            ("ex-a", "1.0", ["ex-c"]),
            ("ex-b", "1.0", []),
            ("ex-c", "1.0", []),
        ])
        assert install("ex-root", lookup)["ok"]
        assert install("ex-a", lookup)["ok"]  # the user asks for ex-a on its own as well
        out = json.loads(mod.remove_package("ex-root"))
        assert out["ok"] and [c["name"] for c in out["alsoRemoved"]] == ["ex-b"], out
        pk = _packages_by_name()
        assert set(pk) == {"ex-a", "ex-c"}, pk
        assert pk["ex-a"]["requested"] is True and pk["ex-c"]["requested"] is False

    with_env(body)


def test_marker_does_not_outlive_the_library() -> None:
    def body(root: Path) -> None:
        lookup = _marker_site_lookup(root, [
            ("st-root", "1.0", []),
            ("st-holder", "1.0", ["st-root"]),
        ])
        assert install("st-root", lookup)["ok"] and _has_marker("st-root")
        assert json.loads(mod.remove_package("st-root"))["ok"]
        assert not list(mod._SITE.glob("*.dist-info/REQUESTED")), "stale marker left behind"
        # now it only arrives as a companion: it must not look user-requested
        assert install("st-holder", lookup)["ok"]
        pk = _packages_by_name()
        assert pk["st-holder"]["requested"] is True and pk["st-root"]["requested"] is False, pk
        assert not _has_marker("st-root")

    with_env(body)


def test_marker_survives_upgrade_and_failed_upgrade() -> None:
    def body(root: Path) -> None:
        bad = write_wheel(root, "up-root", "2.0", {"up_root/__init__.py": "raise RuntimeError('broken')\n"}, ["up-dep>=2"])
        good_v1 = write_wheel(root, "up-root", "1.0", {"up_root/__init__.py": "V = 1\n"}, ["up-dep<2"])
        good_v3 = write_wheel(root, "up-root", "3.0", {"up_root/__init__.py": "V = 3\n"}, ["up-dep>=2"])
        dep1 = write_wheel(root, "up-dep", "1.0", {"up_dep/__init__.py": "V = 1\n"})
        dep2 = write_wheel(root, "up-dep", "2.0", {"up_dep/__init__.py": "V = 2\n"})
        lookup = {
            "up-root": {"releases": {"1.0": [file_info(good_v1)], "2.0": [file_info(bad)], "3.0": [file_info(good_v3)]}},
            "up-dep": {"releases": {"1.0": [file_info(dep1)], "2.0": [file_info(dep2)]}},
        }
        assert install("up-root==1.0", lookup)["ok"]
        assert _has_marker("up-root") and not _has_marker("up-dep")

        failed = install("up-root==2.0", lookup)  # raises on import -> rolled back
        assert failed["ok"] is False, failed
        assert mod._installed_version("up-root") == "1.0"
        assert _has_marker("up-root"), "rollback must give the marker back"
        assert not _has_marker("up-dep")

        assert install("up-dep==1.0", lookup)["ok"]  # the user also asks for the dependency itself
        assert _has_marker("up-dep")
        assert install("up-root==3.0", lookup)["ok"]
        assert mod._installed_version("up-root") == "3.0" and mod._installed_version("up-dep") == "2.0"
        assert _has_marker("up-root") and _has_marker("up-dep"), "upgrades keep the marker"

    with_env(body)


def test_kotlin_sends_list_fields_to_dart() -> None:
    """packages.list now carries arrays (requiresBy/requires); Flutter's codec rejects org.json.JSONArray."""
    kt = KOTLIN.read_text(encoding="utf-8")
    assert "is org.json.JSONArray" in kt and "fun jsonValue" in kt, "nested JSON arrays must become Lists"
    assert "map[key] = jsonValue(obj.opt(key))" in kt


# ---------------------------------------------------------------------------
# 8. Background work and permissions (build 2B)
# ---------------------------------------------------------------------------
SAMPLE_MANIFEST = """<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="py_runner"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher">
        <activity android:name=".MainActivity" android:exported="true" />
        <meta-data android:name="flutterEmbedding" android:value="2" />
    </application>
</manifest>
"""


def test_launcher_icon_installed_without_white_background() -> None:
    """The app icon is generated at build time from icon.png (the only icon file in the project),
    replaces Flutter's default one, has transparent corners (no white backdrop), includes an
    adaptive icon, and leftover ic_launcher.* files never cause duplicate resources."""
    import xml.dom.minidom as minidom

    from PIL import Image, ImageDraw

    prep = _load_tool("prepare_android")
    assert (ROOT / "icon.png").is_file(), "icon.png in the project root is the only icon file needed"
    assert not (ROOT / "android_res").exists(), "no pre-built icon folders: the build generates them"
    with tempfile.TemporaryDirectory(prefix="bayan-icon-") as td:
        res = Path(td) / "res"
        (res / "mipmap-hdpi").mkdir(parents=True)
        (res / "mipmap-hdpi" / "ic_launcher.webp").write_bytes(b"old")
        (res / "mipmap-hdpi" / "ic_launcher.png").write_bytes(b"old")
        copied = prep.install_launcher_icons(res)
        copied_again = prep.install_launcher_icons(res)
        assert copied == copied_again, "installing twice is idempotent"
        assert not (res / "mipmap-hdpi" / "ic_launcher.webp").exists(), "stale webp would clash with the png"
        for density, px in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
            img = Image.open(res / f"mipmap-{density}" / "ic_launcher.png").convert("RGBA")
            assert img.size == (px, px), (density, img.size)
            assert img.getpixel((0, 0))[3] == 0 and img.getpixel((px - 1, px - 1))[3] == 0, "corners are transparent"
            assert img.getpixel((px // 2, px // 2))[3] == 255
            # no white fringe: the first/last opaque pixels of the middle row are the blue border
            opaque = [x for x in range(px) if img.getpixel((x, px // 2))[3] > 200]
            for x in (opaque[0], opaque[-1]):
                r, g, b, a = img.getpixel((x, px // 2))
                assert b > 150 and r < 120, (density, x, (r, g, b, a))
        fg = Image.open(res / "drawable-nodpi" / "ic_launcher_foreground.png").convert("RGBA")
        assert fg.size == (432, 432) and fg.getpixel((0, 0))[3] == 0
        # the tile sits inside the 66dp safe zone: 72..360 of 432px
        xs = [x for x in range(432) if fg.getpixel((x, 216))[3] > 0]
        assert min(xs) >= 70 and max(xs) <= 362, (min(xs), max(xs))
        adaptive_xml = (res / "mipmap-anydpi-v26" / "ic_launcher.xml").read_text(encoding="utf-8")
        assert minidom.parseString(adaptive_xml.encode("utf-8")).documentElement.tagName == "adaptive-icon"
        assert "@drawable/ic_launcher_foreground" in adaptive_xml
        color = minidom.parse(str(res / "values" / "ic_launcher_background.xml"))
        assert re.fullmatch(r"#[0-9A-F]{6}", color.getElementsByTagName("color")[0].firstChild.data)

    # the original artwork as the user sends it (white / light-grey checkerboard backdrop)
    # is cleaned automatically, so only icon.png has to be uploaded
    with tempfile.TemporaryDirectory(prefix="bayan-icon-dirty-") as td:
        src = Path(td) / "dirty.png"
        im = Image.new("RGB", (400, 400), (253, 253, 253))
        d = ImageDraw.Draw(im)
        for gy in range(20):
            for gx in range(20):
                if (gx + gy) % 2:
                    d.rectangle((gx * 20, gy * 20, gx * 20 + 19, gy * 20 + 19), fill=(236, 236, 235))
        d.rounded_rectangle((30, 30, 369, 369), radius=60, fill=(0, 100, 250))
        d.rounded_rectangle((50, 50, 349, 349), radius=45, fill=(8, 30, 110))
        d.rectangle((150, 180, 250, 220), fill=(255, 255, 255))  # white lettering inside the tile
        im.save(src)
        master = prep.prepare_icon_master(src)
        w = master.size[0]
        assert master.size == (w, w)
        assert master.getpixel((0, 0))[3] == 0 and master.getpixel((w - 1, w - 1))[3] == 0
        centre = master.getpixel((w // 2, w // 2))
        assert centre[3] == 255 and centre[0] > 200, "white lettering inside the tile is kept"
        res2 = Path(td) / "res"
        prep.install_launcher_icons(res2, src)
        assert (res2 / "mipmap-xxxhdpi" / "ic_launcher.png").is_file()


def test_background_manifest_and_icon() -> None:
    """The foreground service is declared as specialUse (with the Play subtype property) and the
    permissions it needs exist. Patching twice must not duplicate anything."""
    import xml.dom.minidom as minidom

    prep = _load_tool("prepare_android")
    with tempfile.TemporaryDirectory(prefix="bayan-manifest-") as td:
        root = Path(td)
        manifest = root / "app" / "src" / "main" / "AndroidManifest.xml"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(SAMPLE_MANIFEST, encoding="utf-8")
        prep.ANDROID = root
        prep.patch_manifest()
        prep.patch_manifest()
        icon = prep.write_notification_icon(root / "app")

        text = manifest.read_text(encoding="utf-8")
        doc = minidom.parseString(text.encode("utf-8"))
        perms = [n.getAttribute("android:name") for n in doc.getElementsByTagName("uses-permission")]
        for name in (
            "FOREGROUND_SERVICE",
            "FOREGROUND_SERVICE_SPECIAL_USE",
            "POST_NOTIFICATIONS",
            "WAKE_LOCK",
            "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
        ):
            assert perms.count(f"android.permission.{name}") == 1, (name, perms)

        services = doc.getElementsByTagName("service")
        assert len(services) == 1, "the service must be declared exactly once"
        svc = services[0]
        pkg = re.search(r"^package\s+([\w.]+)", KOTLIN.read_text(encoding="utf-8"), re.M).group(1)
        assert svc.getAttribute("android:name") == f"{pkg}.BayanScriptService"
        assert svc.getAttribute("android:foregroundServiceType") == "specialUse"
        assert svc.getAttribute("android:exported") == "false"
        props = {n.getAttribute("android:name"): n.getAttribute("android:value") for n in svc.getElementsByTagName("property")}
        assert props.get("android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"), props
        assert svc.parentNode.tagName == "application", "service must live inside <application>"

        minidom.parseString(icon.read_bytes())  # well-formed vector drawable
        assert icon.name == "ic_bayan_notify.xml" and icon.parent.name == "drawable"


def _kotlin_function_body(source: str, name: str) -> str:
    m = re.search(rf"\bfun\s+{name}\s*\([^)]*\)[^{{=]*\{{", source)
    assert m, f"fun {name} not found"
    depth, i = 1, m.end()
    while depth and i < len(source):
        depth += {"{": 1, "}": -1}.get(source[i], 0)
        i += 1
    return source[m.end() : i]


def test_background_kotlin_shape() -> None:
    """Closing the screen must not stop scripts; the bridge outlives MainActivity; the service is specialUse."""
    kt = KOTLIN.read_text(encoding="utf-8")
    assert re.search(r"class\s+BayanPythonBridge\s+private\s+constructor", kt), "bridge must be a process-wide object"
    assert "fun get(context: Context)" in kt and "fun peek()" in kt

    on_destroy = _kotlin_function_body(kt, "onDestroy")
    activity_part = kt[kt.index("class MainActivity") : kt.index("class EventRing")]
    for forbidden in ("stopAll", "stopped = true", ".close()", "shutdownNow"):
        assert forbidden not in activity_part, f"MainActivity must only detach the UI ({forbidden})"
    assert "detach(" in on_destroy, "onDestroy must detach the UI from the bridge"
    assert "shutdownNow" not in kt, "executors must live as long as the process"
    assert "closed" not in re.sub(r"//.*", "", kt), "the old `closed` flag would cancel installs when the UI closes"

    # PackageCallback.shouldStop no longer follows the UI
    pkg = kt[kt.index("inner class PackageCallback") :]
    assert re.search(r"fun shouldStop\(\): Boolean = false", pkg)

    svc = kt[kt.index("class BayanScriptService") : kt.index("class BayanSystem")]
    assert "FOREGROUND_SERVICE_TYPE_SPECIAL_USE" in svc
    assert "START_NOT_STICKY" in svc
    assert "ACTION_STOP_ALL" in svc and "stopAll()" in svc
    assert "PARTIAL_WAKE_LOCK" in svc and "release()" in svc
    assert "FLAG_IMMUTABLE" in svc, "PendingIntents must be immutable on Android 12+"
    assert "STOP_FOREGROUND_REMOVE" in svc
    # the service must ask the bridge, not keep its own copy of the run list
    assert "activeRuns()" in svc
    # WifiLock only where it still does something (Android 9 and older)
    assert "VERSION_CODES.Q" in svc and "WIFI_MODE_FULL_HIGH_PERF" in svc


def test_event_ring_limits_are_in_the_spec() -> None:
    kt = KOTLIN.read_text(encoding="utf-8")
    m = re.search(r"class EventRing\(([^)]*)\)", kt)
    assert m, "EventRing missing"
    assert "maxEvents: Int = 2000" in m.group(1) and "maxChars: Int = 512 * 1024" in m.group(1)


LOGS_METHODS = {"logs.size", "logs.page", "logs.clear", "logs.move", "logs.trash", "logs.untrash", "logs.purge"}


def _dart_invoked_methods(dart: str, class_name: str) -> set[str]:
    m = re.search(rf"\bclass\s+{class_name}\b[^{{]*\{{", dart)
    assert m, f"{class_name} not found in the Dart sources"
    depth, i = 1, m.end()
    while depth and i < len(dart):
        depth += {"{": 1, "}": -1}.get(dart[i], 0)
        i += 1
    body = dart[m.end() : i]
    return set(re.findall(r"invokeMethod<[^>]*>\(\s*'([\w.]+)'", body))


def _kotlin_when_methods(kt: str, class_name: str) -> set[str]:
    start = re.search(rf"\bclass\s+{class_name}\b[^{{]*\{{", kt)
    assert start, class_name
    depth, i = 1, start.end()
    while depth and i < len(kt):
        depth += {"{": 1, "}": -1}.get(kt[i], 0)
        i += 1
    body = kt[start.end() : i]
    return set(re.findall(r'^\s*"([\w.]+)"\s*->', body, re.M))


def test_dart_kotlin_method_channels_agree() -> None:
    """Every method Dart invokes must have a branch in Kotlin (a typo here only fails on the phone)."""
    kt = KOTLIN.read_text(encoding="utf-8")
    dart = (ROOT / "python_runtime.dart").read_text(encoding="utf-8")
    for dart_class, kotlin_class, channel in (
        ("BayanPythonRuntime", "BayanPythonBridge", "bayan/python"),
        ("BayanSystem", "BayanSystem", "bayan/system"),
    ):
        called = _dart_invoked_methods(dart, dart_class)
        handled = _kotlin_when_methods(kt, kotlin_class)
        assert called, f"no invokeMethod calls found in {dart_class}"
        assert called <= handled, f"{dart_class} calls {sorted(called - handled)} but Kotlin only handles {sorted(handled)}"
        assert f"MethodChannel('{channel}')" in dart.replace('"', "'"), channel
        assert f'"{channel}"' in kt, channel
        if dart_class == "BayanPythonRuntime":
            # 2.5D1: the persistent-log methods must exist on both sides, under exactly these names
            assert LOGS_METHODS <= called, f"Dart is missing wrappers for {sorted(LOGS_METHODS - called)}"
            assert LOGS_METHODS <= handled, f"Kotlin is missing branches for {sorted(LOGS_METHODS - handled)}"
            assert {m for m in called if m.startswith("logs.")} == LOGS_METHODS


def test_dart_sources_are_balanced() -> None:
    """No Dart SDK in CI before `flutter analyze`: catch missing brackets early and cheaply."""
    bal = _load_tool("dart_balance")
    for name in ("main.dart", "store.dart", "python_runtime.dart", "script_runner.dart"):
        errors = bal.check((ROOT / name).read_text(encoding="utf-8"))
        assert not errors, f"{name}: {errors[:5]}"
    assert bal.check("void f() { var x = [1, 2; }"), "the checker must reject unbalanced code"
    assert not bal.check("void f() { var s = '${a({1: 2})}'; // )\n}")


def test_dart_permissions_screen_wiring() -> None:
    """The drawer entry, welcome flag and the screen are connected (a renamed identifier breaks analyze)."""
    main = (ROOT / "main.dart").read_text(encoding="utf-8")
    store = (ROOT / "store.dart").read_text(encoding="utf-8")
    rt = (ROOT / "python_runtime.dart").read_text(encoding="utf-8")
    assert "class PermissionsScreen" in main and "PermissionsScreen(welcome: true)" in main
    assert re.search(r"AppDrawer\([^)]*onPermissions: _openPermissions", main, re.S)
    assert "required this.onPermissions" in main
    assert "'فحص الصلاحيات'" in main
    assert "getFlag(_welcomeFlag)" in main and "setFlag(_welcomeFlag, true)" in main
    assert "bool getFlag(String key)" in store and "Future<void> setFlag(" in store
    assert "package:permission_handler/permission_handler.dart" in rt
    for member in ("status()", "requestBattery()", "openAutoStart()", "requestNotifications()"):
        assert member in rt, member
        assert f"bayanSystem.{member.split('(')[0]}" in main, member
    # every icon used must be one Flutter ships (spot check of the new ones)
    for icon in ("Icons.verified_user_outlined", "Icons.notifications_none", "Icons.battery_charging_full", "Icons.play_circle_outline"):
        assert icon in main, icon


def test_sessions_plan_2_1g_invariants() -> None:
    """Plan 2.1G: sessions outlive the output screen, keyed by script path, numbered, bounded."""
    kt = KOTLIN.read_text(encoding="utf-8")
    rt = (ROOT / "python_runtime.dart").read_text(encoding="utf-8")
    runner = (ROOT / "script_runner.dart").read_text(encoding="utf-8")
    main_dart = (ROOT / "main.dart").read_text(encoding="utf-8")

    handled = _kotlin_when_methods(kt, "BayanPythonBridge")
    for method in ("runs.list", "runs.attach", "runs.stopAll", "runs.move", "runs.discard"):
        assert method in handled, method
    for dart_fn in ("runsList", "runsAttach", "runsStopAll", "runsMove", "runsDiscard"):
        assert dart_fn in rt, dart_fn
    assert "'textHash'" in rt and "textHash" in runner

    assert "replayActiveRuns" not in kt, "events come from runs.attach only (no double replay)"
    assert "sessions.clear()" not in kt and "sessions.remove(runId)" not in kt
    assert "sessions[scriptPath] = session" in kt, "sessions are keyed by the script path"
    assert "MAX_FINISHED_RUNS = 10" in kt
    assert '"seq" to' in kt and '"scriptPath" to scriptPath' in kt
    stop_all = _kotlin_function_body(kt, "stopAll")
    assert "!it.finished" in stop_all, "stopAll must not touch finished sessions"

    dispose = re.search(r"Future<void> dispose\(\) async \{(.*?)\n  \}\n", runner, re.S)
    assert dispose and "stop(" not in dispose.group(1), "leaving the output screen must not stop the script"
    assert "class RunHub" in runner and "class RunSlot" in runner
    assert "إيقاف والانتقال" not in main_dart
    assert "attachRunId:" in main_dart and "claimRunSlot(" in main_dart


# ---------------------------------------------------------------------------
# Plan 2.2G: output screen, editor button, tiles, rename/delete (cheap text guards)
# ---------------------------------------------------------------------------
def _dart_block(src: str, header: str) -> str:
    """Body of the first function-body {...} after `header`.

    Braces inside the parameter list (named parameters like `{bool x = true}`) are skipped:
    the body starts at the first `{` found outside any parentheses. Brace matching is enough
    for our sources (string interpolations are balanced).
    """
    start = src.index(header)
    paren = 0
    open_at = -1
    for j in range(start, len(src)):
        ch = src[j]
        if ch == "(":
            paren += 1
        elif ch == ")":
            paren -= 1
        elif ch == "{" and paren == 0:
            open_at = j
            break
    assert open_at >= 0, f"no body after {header!r}"
    depth = 0
    for j in range(open_at, len(src)):
        ch = src[j]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return src[open_at + 1 : j]
    raise AssertionError(f"unbalanced block after {header!r}")


def _fnv_fingerprint(text: str, *, signed: bool = False) -> str:
    """Python mirror of textFingerprint() in script_runner.dart (FNV-1a 64 + length)."""
    data = text.encode("utf-8")
    h = 0xCBF29CE484222325
    for b in data:
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    if signed and h >= 1 << 63:  # Dart ints are signed 64-bit: same bits, negative value
        h -= 1 << 64
    return f"{len(data)}-{((h >> 32) & 0xFFFFFFFF):08x}{(h & 0xFFFFFFFF):08x}"


def test_plan_2_2g_fingerprint_matches_dart_source() -> None:
    runner = (ROOT / "script_runner.dart").read_text(encoding="utf-8")
    body = _dart_block(runner, "String textFingerprint(String text)")
    assert "0xcbf29ce484222325" in body and "0x100000001b3" in body, "standard FNV-1a 64 constants"
    assert "utf8.encode(text)" in body and "bytes.length" in body
    assert "toRadixString(16)" in body and "padLeft(8, '0')" in body, "hex from two 32-bit halves (no minus sign)"
    assert "sha" not in runner.lower().split("class scriptrunner")[0], "no SHA/crypto dependency"
    # published FNV-1a 64 test vectors
    assert _fnv_fingerprint("a") == "1-af63dc4c8601ec8c"
    assert _fnv_fingerprint("foobar") == "6-85944171f73967e8"
    assert _fnv_fingerprint("") == "0-cbf29ce484222325"
    # Dart's signed arithmetic must format identically (no '-' from negative values)
    for text in ("", "a", "print('بيان')\n", "x = 1\r\ny = 2", "é" * 300, "سطر\n" * 500):
        assert _fnv_fingerprint(text) == _fnv_fingerprint(text, signed=True)
        assert "-" not in _fnv_fingerprint(text).split("-", 1)[1]
    # one character apart -> different, and reverting -> equal again
    base = "while True:\n    print(1)\n"
    assert _fnv_fingerprint(base) != _fnv_fingerprint(base + " ")
    assert _fnv_fingerprint(base) == _fnv_fingerprint("while True:\n    print(1)\n")


def test_plan_2_2g_started_event_carries_text_hash() -> None:
    """Without this the editor shows «تشغيل» right after a run until runs.list is re-read."""
    kt = KOTLIN.read_text(encoding="utf-8")
    rt = (ROOT / "python_runtime.dart").read_text(encoding="utf-8")
    runner = (ROOT / "script_runner.dart").read_text(encoding="utf-8")
    run_branch = kt[kt.index('"run" -> {') : kt.index('"sendInput" -> {')]
    assert 'call.argument<String>("textHash")' in run_branch
    started = run_branch[run_branch.index('"type" to "started"') :][:400]
    assert '"textHash" to textHash' in started, "started event must include the fingerprint"
    assert "String? get textHash" in rt
    on_event = _dart_block(runner, "void _onEvent(BayanEvent e)")
    assert "textHash: e.textHash" in on_event


def test_plan_2_2g_output_screen_keeps_script_alive() -> None:
    main_dart = (ROOT / "main.dart").read_text(encoding="utf-8")
    runner = (ROOT / "script_runner.dart").read_text(encoding="utf-8")
    assert "final String? attachRunId;" in main_dart and "attach: true" not in main_dart
    enter = _dart_block(main_dart, "Future<void> _enterSession(String runId)")
    assert "_runner.attach(runId)" in enter and "_runner.start(" not in enter, "enter mode never starts a script"
    assert "الأقدم غير متوفر في الذاكرة" in main_dart
    out_state = main_dart[main_dart.index("class _OutputScreenState") :]
    out_dispose = _dart_block(out_state, "void dispose()")
    out_build = _dart_block(out_state, "Widget build(BuildContext context)")
    for name, body in (("dispose", out_dispose), ("build/back", out_build)):
        assert "stop(" not in body and "_stop" not in body and "runsStopAll" not in body, f"{name} must not stop the script"
    assert "onBack: () => Navigator.pop(context)" in out_build
    # tapping an error frame goes straight to the editor (no confirmation dialog)
    assert "showDialog" not in _dart_block(out_state, "Future<void> _openFrame(FrameRef frame)")
    assert "إيقاف والانتقال" not in main_dart
    # «آخر تشغيل» is recorded by RunHub only (even with the output screen closed)
    assert "markRun" not in main_dart and "store.markRun" in runner


def test_plan_2_2g_editor_button_and_run_gate() -> None:
    main_dart = (ROOT / "main.dart").read_text(encoding="utf-8")
    editor = main_dart[main_dart.index("class _ScriptScreenState") : main_dart.index("class Line {")]
    assert "Duration(milliseconds: 300)" in _dart_block(editor, "void _scheduleHash()")
    assert "_scheduleHash();" in _dart_block(editor, "void _onChanged()")
    assert "_hashTimer?.cancel();" in _dart_block(editor, "void dispose()")
    enter = _dart_block(editor, "RunInfo? _enterableRun()")
    assert "textHash" in enter and "_hashValue == saved" in enter
    open_output = _dart_block(editor, "Future<void> _openOutput()")
    assert open_output.index("_refreshHash();") < open_output.index("_enterableRun()"), "decide on the current text"
    assert "attachRunId: session.runId" in open_output and "claimRunSlot(context, widget.script)" in open_output
    assert "_canEnter ? 'دخول' : 'تشغيل'" in editor
    gate = _dart_block(main_dart, "Future<bool> claimRunSlot(")
    assert "إيقاف النسخة القديمة وتشغيل الجديدة؟" in gate and "سكربت آخر يعمل" in gate
    assert "confirmOwnOldRun" in gate
    restart = _dart_block(main_dart, "Future<void> _restart()")
    assert "confirmOwnOldRun: false" in restart, "the restart button already is the user's decision to stop"


def test_plan_2_2g_tiles_and_management() -> None:
    main_dart = (ROOT / "main.dart").read_text(encoding="utf-8")
    store = (ROOT / "store.dart").read_text(encoding="utf-8")
    tile = main_dart[main_dart.index("class ScriptTile") : main_dart.index("String fmtElapsed")]
    for text in ("يعمل منذ", "ينتظر إدخال", "valueListenable: runHub.clock"):
        assert text in tile, text
    # الخطأ تكفيه النقطة الحمراء: لا سطر «انتهى بكود N» في البطاقة ولا في الإخراج
    assert "انتهى بكود" not in tile and "info.exitCode" not in tile
    assert "انتهى بكود" not in re.sub(r"//[^\n]*", "", main_dart), "no exit-code text anywhere in the UI"
    # الاتفاق الجديد: لا «آخر تعديل» ولا «آخر تشغيل» في بطاقة السكربت (الحالة الحية فقط)
    for text in ("آخر تعديل", "آخر تشغيل", "لم يُشغّل بعد"):
        assert text not in tile, text
    dot = _dart_block(main_dart, "static Color colorOf(RunStatus? s)")
    assert re.search(r"RunStatus\.running:\s*return C\.ok", dot)
    assert re.search(r"RunStatus\.waiting:\s*return C\.warn", dot)
    assert re.search(r"RunStatus\.error:\s*return C\.error", dot)
    guard = _dart_block(main_dart, "bool _blockedWhileRunning(")
    assert "أوقف السكربت أولًا" in guard and "isLive" in guard
    rename = _dart_block(main_dart, "Future<void> renameScript(")
    delete = _dart_block(main_dart, "Future<void> deleteScript(")
    dup = _dart_block(main_dart, "Future<void> duplicateScript(")
    assert rename.lstrip().startswith("if (_blockedWhileRunning(context, s)) return;")
    assert delete.lstrip().startswith("if (_blockedWhileRunning(context, s)) return;")
    assert "runHub.moved(oldPath, r.path)" in rename and "runHub.discarded(deletedPath)" in delete
    # re-checked after the name dialog (a run could start meanwhile), before touching the file
    assert rename.count("_blockedWhileRunning(context, s)") == 2
    assert rename.index("_blockedWhileRunning(context, s)", 60) < rename.index("store.rename(")
    assert rename.rindex("_blockedWhileRunning(context, s)") < rename.index("store.rename(")
    assert "runHub" not in dup, "duplicating never copies a session"
    assert "runHub" not in store and "RunHub" not in store, "store.dart is not part of this build"


def test_plan_2_2g_kotlin_run_does_not_wipe_sessions() -> None:
    kt = KOTLIN.read_text(encoding="utf-8")
    run_branch = kt[kt.index('"run" -> {') : kt.index('"sendInput" -> {')]
    assert "clear()" not in run_branch and ".remove(" not in run_branch, "starting a script keeps other sessions"
    assert "sessions[scriptPath] = session" in run_branch
    assert "MAX_FINISHED_RUNS = 10" in kt


# ---------------------------------------------------------------------------
# 2.5D1: persistent output log (LogStore)
# ---------------------------------------------------------------------------
LOGS_SIGNATURES = {
    "logs.size": {"scriptPath"},
    "logs.page": {"scriptPath", "before", "maxBytes", "epoch"},
    "logs.clear": {"scriptPath"},
    "logs.move": {"from", "to"},
    "logs.trash": {"scriptPath"},
    "logs.untrash": {"scriptPath", "restoreAs"},
    "logs.purge": {"scriptPath"},
}
FILE_API_TOKENS = ("FileOutputStream", "FileInputStream", "RandomAccessFile", "renameTo", "ByteArrayOutputStream", "listFiles", "appendText", "readBytes", "writeBytes")


def _logstore_source(kt: str) -> str:
    start = kt.index("class LogStore(")
    return kt[start : kt.index("class BayanPythonBridge private constructor")]


def _kotlin_branch(kt: str, method: str) -> str:
    start = kt.index(f'"{method}" -> {{')
    nxt = [kt.index(m, start + 1) for m in ('            "logs.', '            "packages.list"', "            else ->") if m in kt[start + 1 :]]
    return kt[start : min(nxt)] if nxt else kt[start:]


def test_logs_channel_signatures_match_between_dart_and_kotlin() -> None:
    """Same method names AND same argument names on both sides (2.5D2 builds on these exact signatures)."""
    kt = KOTLIN.read_text(encoding="utf-8")
    dart = (ROOT / "python_runtime.dart").read_text(encoding="utf-8")
    assert set(LOGS_SIGNATURES) == LOGS_METHODS
    for method, expected in LOGS_SIGNATURES.items():
        branch = _kotlin_branch(kt, method)
        kt_args = set(re.findall(r'call\.argument<\w+>\("(\w+)"\)', branch))
        assert kt_args == expected, f"{method}: Kotlin reads {sorted(kt_args)}, expected {sorted(expected)}"

        at = dart.index(f"'{method}'")
        body = dart[at : dart.index("\n  }\n", at)]
        dart_args = set(re.findall(r"'(\w+)':", body))
        assert dart_args == expected, f"{method}: Dart sends {sorted(dart_args)}, expected {sorted(expected)}"
    # logs.page reply fields are read by LogPage.fromJson under the same names
    page_branch = _logstore_source(kt)
    for field in ("text", "start", "end", "size", "hasMore", "epoch", "stale"):
        assert f'"{field}" to' in page_branch, f"Kotlin does not send {field}"
        assert f"'{field}'" in dart[dart.index("class LogPage") : dart.index("class BayanPythonRuntime")], f"LogPage does not read {field}"


def test_log_disk_work_is_off_the_main_thread() -> None:
    kt = KOTLIN.read_text(encoding="utf-8")
    store = _logstore_source(kt)

    # one background writer thread owns every file operation
    assert "Executors.newSingleThreadScheduledExecutor" in store
    assert '"Bayan-LogWriter"' in store and "isDaemon = true" in store

    # the entry points called from the main thread only queue in memory
    for fn in ("enqueue", "addEvent", "startRun", "endRun", "record"):
        body = _kotlin_function_body(store, fn)
        for token in FILE_API_TOKENS + ("File(", ".delete(", ".exists(", ".length()", ".mkdirs("):
            assert token not in body, f"LogStore.{fn} runs on the caller's thread and must not touch files ({token})"

    # every public file operation goes through the writer thread (io { ... })
    for fn in ("size", "page", "clear", "move", "trash", "untrash", "purge"):
        m = re.search(rf"\bfun\s+{fn}\s*\(", store)
        assert m, fn
        assert "io(ok, err)" in store[m.start() : m.start() + 600], f"LogStore.{fn} must run through io(...)"
    io_at = store.index("private fun <T> io(")
    io_body = store[io_at : io_at + 700]
    assert "worker.execute" in io_body
    assert "flushPending()" in io_body, "readers must see the newest events"

    # nothing outside LogStore (the bridge, the service, MainActivity) opens or writes log files itself
    outside = re.sub(r"^import .*$", "", kt.replace(store, ""), flags=re.M)
    for token in FILE_API_TOKENS:
        assert token not in outside, f"{token} used outside LogStore"

    # the bridge only calls the asynchronous API: result is delivered through complete()/fail()
    for method in LOGS_METHODS:
        branch = _kotlin_branch(kt, method)
        assert re.search(r"logs\.\w+\(", branch), method
        assert "complete(result, it)" in branch and "fail(result," in branch, method


def test_log_file_key_is_the_script_key_used_for_pins_and_last_run() -> None:
    kt = KOTLIN.read_text(encoding="utf-8")
    store = _logstore_source(kt)
    st = (ROOT / "store.dart").read_text(encoding="utf-8")
    dart = (ROOT / "python_runtime.dart").read_text(encoding="utf-8")

    # store.dart: pins and last-run are keyed by the lower-cased file name
    assert "String _base(String path) => path.substring(path.lastIndexOf('/') + 1);" in st
    assert len(re.findall(r"_base\(\w+\.path\)\.toLowerCase\(\)", st)) >= 3
    assert "s.name.toLowerCase()" in st
    # LogStore: the same derivation, in one place
    assert "fun keyOf(scriptPath: String): String = scriptPath.substringAfterLast('/').lowercase()" in store
    # every entry point derives its key with keyOf (no second scheme)
    assert store.count("keyOf(") >= 12
    # file name = key + ".jsonl" (and ".trash" / ".tmp" are suffixes of that name)
    assert 'const val FILE_EXT = ".jsonl"' in store and "return safe + FILE_EXT" in store
    assert "fileNameOf(key) + TRASH_EXT" in store
    # logs live in the app's internal files dir under /logs, not inside "Bayan 777"
    assert 'File(context.filesDir, "logs")' in kt
    assert "Bayan 777" not in store
    # Dart never builds log file names
    assert ".jsonl" not in dart


def test_log_format_and_limits_match_the_spec() -> None:
    kt = KOTLIN.read_text(encoding="utf-8")
    store = _logstore_source(kt)
    for const in (
        "MAX_BYTES = 20L * 1024 * 1024",
        "TARGET_BYTES = 16L * 1024 * 1024",
        "FLUSH_BYTES = 32 * 1024",
        "FLUSH_DELAY_MS = 1000L",
        'TRIM_NOTE = "… حُذف الأقدم"',
        'TRASH_EXT = ".trash"',
    ):
        assert const in store, const
    # the three line shapes, with their exact field names
    assert 'START_PREFIX = "{\\"run\\":"' in store
    assert '"\\",\\"start\\":"' in store and '",\\"auto\\":"' in store
    assert '"{\\"t\\":"' in store and '",\\"k\\":\\""' in store and '",\\"s\\":\\""' in store
    assert '"{\\"end\\":\\""' in store and '"\\",\\"t\\":"' in store and '",\\"code\\":"' in store
    # event kinds
    record = _kotlin_function_body(store, "record")
    for needle in ('"stdout" -> addEvent(scriptPath, t, "o", text)', '"stderr", "error" -> addEvent(scriptPath, t, "e", text)', '"input" -> addEvent(scriptPath, t, "i", text)', '"started" ->', '"exit" ->'):
        assert needle in record, needle
    assert '"auto"' not in record and "startRun(scriptPath, runId, startedAt, false)" in record, "auto is for build 3 only"
    # lone surrogates survive the JSON round trip; control characters are escaped
    assert "Character.isHighSurrogate" in store and "Character.isLowSurrogate" in store and "appendUnicodeEscape" in store
    # append-only: the start line is never rewritten when the run ends
    assert "FileOutputStream(file, true)" in store
    # trimming keeps whole lines and writes a replacement file, never edits in place
    trim = _kotlin_function_body(store, "trimNow")
    assert "'\\n'" in trim and "tempFor(key)" in trim and "renameTo" in trim and "TRIM_NOTE" in trim
    assert "act.startLine" in trim, "the running run keeps its start line when its oldest lines are cut"
    # reading: chunks from the end, never the whole file
    page = _kotlin_function_body(store, "pageNow")
    assert "readFully" in page and "readText" not in store and "readBytes" not in store
    # a line longer than the window must widen it (never return an empty chunk that leaves `before` unchanged)
    assert "for (i in 0 until bytes.size - 1)" in page and "window *= 2" in page
    # duplicates: one end line per run, and the pending buffer is flushed on run end
    assert "current.runId != item.runId" in store
    assert "worker.execute { flushPending() }" in _kotlin_function_body(store, "endRun")


def test_log_untrash_can_restore_to_conflict_free_restored_name() -> None:
    kt = KOTLIN.read_text(encoding="utf-8")
    dart = (ROOT / "python_runtime.dart").read_text(encoding="utf-8")
    store = _logstore_source(kt)
    body = _kotlin_function_body(store, "untrashNow")
    assert "trashFor(key)" in body and "fileFor(restoreKey)" in body
    assert "if (!held.exists() || file.exists()) return false" in body
    assert 'call.argument<String>("restoreAs")' in _kotlin_branch(kt, "logs.untrash")
    assert "'restoreAs': restoreAs" in dart


def test_bridge_logs_every_event_once_and_independently_of_the_ui() -> None:
    kt = KOTLIN.read_text(encoding="utf-8")
    emit = _kotlin_function_body(kt, "emit")
    # the single recording point sits in the same main-thread block that numbers and stores events,
    # before (and regardless of) delivery to the UI sink
    assert kt.count("logs.record(") == 1 and "logs.record(" in emit
    assert emit.index("session.ring.add(out)") < emit.index("logs.record(") < emit.index("eventSink?.success(out)")
    assert "val now = System.currentTimeMillis()" in emit
    # the in-memory store from 2C is untouched
    assert "val ring = EventRing()" in kt and "session.ring.add(out)" in emit and "fun snapshot()" in kt
    # typed input is logged as typed, before any later output
    send = kt[kt.index('"sendInput" -> {') : kt.index('"stop" -> {')]
    assert 'logs.addEvent(session.scriptPath, System.currentTimeMillis(), "i", value)' in send
    assert send.index("session.input.offer(value)") < send.index("logs.addEvent(")
    # end-of-run safety net is posted (keeps its order behind queued events); duplicates are dropped by LogStore
    run = kt[kt.index('"run" -> {') : kt.index('"sendInput" -> {')]
    assert "logs.endRun(session.scriptPath, runId" in run and "main.post {" in run
    # the store is created with the bridge (it outlives MainActivity) and cleans leftovers at start
    assert re.search(r'private val logs = LogStore\(File\(context\.filesDir, "logs"\)\)\.also \{ it\.start\(\) \}', kt)
    start = _kotlin_function_body(_logstore_source(kt), "start")
    assert "TRASH_EXT" in start and "TEMP_EXT" in start and "try {" in start and "catch (t: Throwable)" in start
    assert "FILE_EXT" not in start, "regular logs must never be deleted at startup"
    # MainActivity itself still only attaches/detaches
    activity = kt[kt.index("class MainActivity") : kt.index("class EventRing")]
    assert "logs" not in activity


def test_plan_2d_log_screen_and_lifecycle_wiring() -> None:
    """2D exposes the persisted log and keeps it aligned with rename/delete/undo."""
    main = (ROOT / "main.dart").read_text(encoding="utf-8")
    runtime = (ROOT / "python_runtime.dart").read_text(encoding="utf-8")
    assert "class LogScreen extends StatefulWidget" in main
    assert "LogScreen(script: s)" in main and "label: 'سجل الإخراج'" in main
    for needle in ("logsSize", "logsPage", "logsClear", "logsMove", "logsTrash", "logsUntrash", "logsPurge"):
        assert needle in runtime, f"missing Dart logs wrapper: {needle}"
    assert "bayanPython.logsMove(from: oldPath, to: r.path)" in main
    assert "bayanPython.logsTrash(deletedPath)" in main
    assert "bayanPython.logsUntrash(" in main and "restoreAs: r.path" in main
    assert "controller.closed.then" in main and "bayanPython.logsPurge(deletedPath)" in main
    assert "if (!logRestored)" in main, "failed log restore must clean up the temporary trash log"
    assert "تمت استعادة الملف لكن تعذّر استعادة سجل الإخراج" in main
    assert "تعذّرت استعادة الملف" in main, "log failure must not be misreported as file-restore failure"
    assert "مسح الشاشة" in main and "مسح السجل" in main
    assert "SelectionArea(" in main and "arSelectionContextMenu" in main
    assert "appendOutputEventLines(_lines, text, kind)" in main
    assert "_copyLimit = 400000" in main and "maxBytes: 1024 * 1024" in main


def test_fixes_md_documents_build_2_5d1() -> None:
    fixes = (ROOT / "FIXES.md").read_text(encoding="utf-8")
    assert "# البناء 2.5D1" in fixes
    for needle in ("LogStore", "logs.page", "JSONL", "Bayan-LogWriter", "نتائج الفحوص وقت مرحلة 2.5D1"):
        assert needle in fixes, needle


def test_fixes_md_documents_build_2d() -> None:
    fixes = (ROOT / "FIXES.md").read_text(encoding="utf-8")
    assert "# البناء 2د" in fixes
    for needle in ("LogScreen", "400,000", "20 MB", "مسح الشاشة", "SelectionArea", "قتل التطبيق"):
        assert needle in fixes, needle


def test_fixes_md_documents_build_2c() -> None:
    fixes = (ROOT / "FIXES.md").read_text(encoding="utf-8")
    assert "# البناء 2ج" in fixes
    for needle in ("attachRunId", "textHash", "أوقف السكربت أولًا", "FNV"):
        assert needle in fixes, needle


def main() -> None:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in tests:
        fn()
        print(f"  ok  {fn.__name__}")
    print("Bayan extra tests: PASS")


if __name__ == "__main__":
    main()
