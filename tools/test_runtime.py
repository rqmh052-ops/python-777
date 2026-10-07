from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
import tempfile
import threading
import time
import zipfile
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "bayan_runtime.py"
spec = importlib.util.spec_from_file_location("bayan_runtime_test_target", MODULE_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError("تعذر تحميل bayan_runtime.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class Callback:
    def __init__(self, inputs: list[str] | None = None):
        self.inputs = list(inputs or [])
        self.output: list[tuple[str, str]] = []
        self.events: list[tuple] = []
        self.stop_flag = False

    def shouldStop(self) -> bool:
        return self.stop_flag

    def emitOutput(self, kind: str, text: str) -> None:
        self.output.append((kind, text))

    def emitError(self, text: str) -> None:
        self.events.append(("error", text))

    def emitInput(self, prompt: str) -> None:
        self.events.append(("input", prompt))

    def requestInput(self, prompt: str) -> str | None:
        return self.inputs.pop(0) if self.inputs else ""

    def emitState(self, state: str) -> None:
        self.events.append(("state", state))

    def emitExit(self, code: int) -> None:
        self.events.append(("exit", code))

    def emitPackage(self, *values) -> None:
        self.events.append(("package", *values))


def make_wheel(root: Path, name: str, version: str, code: str, requires: list[str] | None = None) -> Path:
    normalized = name.replace("-", "_")
    dist = f"{normalized}-{version}.dist-info"
    wheel = root / f"{normalized}-{version}-py3-none-any.whl"
    requires_text = "".join(f"Requires-Dist: {r}\n" for r in (requires or []))
    files = {
        f"{normalized}/__init__.py": code,
        f"{dist}/METADATA": (
            "Metadata-Version: 2.1\n"
            f"Name: {name}\n"
            f"Version: {version}\n"
            "Requires-Python: >=3.10\n"
            f"{requires_text}\n"
        ),
        f"{dist}/WHEEL": "Wheel-Version: 1.0\nGenerator: BayanTest\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
        f"{dist}/top_level.txt": f"{normalized}\n",
        f"{dist}/RECORD": "\n".join(f"{path},," for path in [f"{normalized}/__init__.py", f"{dist}/METADATA", f"{dist}/WHEEL", f"{dist}/top_level.txt", f"{dist}/RECORD"]) + "\n",
    }
    with zipfile.ZipFile(wheel, "w", zipfile.ZIP_DEFLATED) as archive:
        for path, text in files.items():
            archive.writestr(path, text)
    return wheel


def wheel_json(wheel: Path, version: str) -> dict:
    digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
    return {
        "filename": wheel.name,
        "url": wheel.as_uri(),
        "size": wheel.stat().st_size,
        "digests": {"sha256": digest},
        "requires_python": ">=3.10",
        "version": version,
    }


def install_site_module_check(env: Path, name: str, expected: int) -> None:
    mod._clear_site_modules()
    sys.modules.pop(name.replace("-", "_"), None)
    imported = __import__(name.replace("-", "_"))
    assert imported.VALUE == expected, (name, getattr(imported, "VALUE", None))


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="bayan-runtime-test-") as td:
        root = Path(td)
        env = root / "env"
        scripts = root / "scripts"
        scripts.mkdir()
        mod.configure(str(env))
        mod._configure_android(35, "arm64-v8a")

        # stdout + input + multiple values through the real execution path.
        script = scripts / "io.py"
        script.write_text(
            'import sys\n'
            'print("Hello Bayan")\n'            'name=input("Name: ")\n'
            'value=sys.stdin.readline().strip()\n'
            'print("Hi", name, value)\n',
            encoding="utf-8",
        )
        cb = Callback(["Ayman", "777"])
        assert mod.run_script(str(script), cb) == 0
        stdout = "".join(text for kind, text in cb.output if kind == "stdout")
        assert "Hello Bayan" in stdout and "Hi Ayman 777" in stdout
        assert ("input", "Name: ") in cb.events
        assert cb.events[-1] == ("state", "finished")

        # Real traceback goes to stderr and does not escape the runner.
        error_script = scripts / "error.py"
        error_script.write_text('print(missing_name)\n', encoding="utf-8")
        err_cb = Callback()
        assert mod.run_script(str(error_script), err_cb) == 1
        stderr = "".join(text for kind, text in err_cb.output if kind == "stderr")
        assert "NameError" in stderr

        # Tight-loop stop is responsive through opcode tracing.
        loop_script = scripts / "loop.py"
        loop_script.write_text("i=0\nwhile True:\n    i += 1\n", encoding="utf-8")
        loop_cb = Callback()
        thread = threading.Thread(target=lambda: mod.run_script(str(loop_script), loop_cb))
        thread.start()
        time.sleep(0.10)
        loop_cb.stop_flag = True
        thread.join(2.0)
        assert not thread.is_alive(), "tight loop was not stopped"
        assert ("exit", 130) in loop_cb.events

        # Build three tiny real wheels and test dependency resolution, cache,
        # repeated installation, and independent removal.
        dep_wheel = make_wheel(root, "bayan-dep", "1.2.0", "VALUE=7\n")
        root_wheel_v1 = make_wheel(
            root,
            "bayan-root",
            "1.0.0",
            "VALUE=42\n",
            ["bayan-dep>=1.0,<2.0"],
        )
        root_wheel_v2_bad = make_wheel(
            root,
            "bayan-root",
            "2.0.0",
            "raise RuntimeError('broken v2')\n",
            ["bayan-dep>=1.0,<2.0"],
        )

        old_get = mod._get_json
        old_chaq = mod._chaquopy_wheel
        lookup = {
            "bayan-dep": {"releases": {"1.2.0": [wheel_json(dep_wheel, "1.2.0")]}},
            "bayan-root": {
                "releases": {
                    "2.0.0": [wheel_json(root_wheel_v2_bad, "2.0.0")],
                    "1.0.0": [wheel_json(root_wheel_v1, "1.0.0")],
                }
            },
        }
        mod._get_json = lambda name, callback=None: lookup[mod._norm_name(name)]
        mod._chaquopy_wheel = lambda *args, **kwargs: None
        try:
            result = json.loads(mod.install_package("bayan-root==1.0.0", Callback(), "j1"))
            assert result["ok"] is True, result
            assert mod._installed_version("bayan-root") == "1.0.0"
            assert mod._installed_version("bayan-dep") == "1.2.0"
            install_site_module_check(env, "bayan_root", 42)

            repeat = json.loads(mod.install_package("bayan-root==1.0.0", Callback(), "j2"))
            assert repeat["ok"] and repeat.get("already") is True, repeat

            failed_update = json.loads(mod.install_package("bayan-root==2.0.0", Callback(), "j3"))
            assert failed_update["ok"] is False, failed_update
            assert mod._installed_version("bayan-root") == "1.0.0"
            install_site_module_check(env, "bayan_root", 42)

            removed = json.loads(mod.remove_package("bayan-root"))
            assert removed["ok"] is True
            assert mod._installed_version("bayan-root") is None
            assert mod._installed_version("bayan-dep") == "1.2.0"
            mod._clear_site_modules()
            sys.modules.pop("bayan_root", None)
            try:
                __import__("bayan_root")
            except ModuleNotFoundError:
                pass
            else:
                raise AssertionError("removed package remained importable")
        finally:
            mod._get_json = old_get
            mod._chaquopy_wheel = old_chaq

    print("Bayan runtime tests: PASS")


if __name__ == "__main__":
    main()
