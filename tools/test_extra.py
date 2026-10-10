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


def main() -> None:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in tests:
        fn()
        print(f"  ok  {fn.__name__}")
    print("Bayan extra tests: PASS")


if __name__ == "__main__":
    main()
