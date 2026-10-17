"""Runtime execution and package manager for Bayan.

This module is bundled as app code by Chaquopy, but all writable state lives
under the private Bayan environment configured by the Android bridge.
"""

from __future__ import annotations

import _thread
import ast
import builtins
import csv
import hashlib
import importlib
import importlib.util
import io
import json
import os
import re
import shutil
import signal
import sys
import tempfile
import threading
import time
import traceback
from concurrent.futures import ThreadPoolExecutor
import urllib.error
import urllib.parse
import urllib.request
import weakref
import zipfile
from email.parser import Parser
from pathlib import Path
from typing import Any

PYTHON_VERSION = f"{sys.version_info.major}.{sys.version_info.minor}"
# PEP 376: an empty file inside <name>.dist-info that marks a distribution the
# user asked for (as opposed to one pulled in automatically as a dependency).
REQUESTED_NAME = "REQUESTED"
PYPI_JSON = "https://pypi.org/pypi/{name}/json"
PYPI_SIMPLE = "https://pypi.org/simple/{name}/"
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


def _should_stop(callback: Any) -> bool:
    """Ask the Android bridge whether the user pressed stop (never raises)."""
    try:
        return bool(callback.shouldStop())
    except AttributeError:
        return False


# Methods that Python calls on the Kotlin callback objects. If R8 renames or
# deletes them in a release build, every run fails with the cryptic
# "'y0' object has no attribute 'emitState'". Checking up front turns that
# into a message that says what is wrong and how to fix it.
_RUN_CALLBACK_REQUIRED = ("emitOutput", "emitError", "emitInput", "requestInput", "emitState", "emitExit", "emitMissing")
_PACKAGE_CALLBACK_REQUIRED = ("emitPackage",)

_CALLBACK_HINT = (
    "نسخة التطبيق المثبّتة ناقصة: دوال Kotlin التي يستدعيها بايثون ({names}) غير موجودة داخل الـ APK. "
    "السبب المعتاد أن R8 حذفها أو غيّر أسماءها في بناء release. "
    "أعد بناء التطبيق بعد تطبيق إصلاح R8 (--no-shrink وملف proguard-rules.pro)، "
    "ثم احذف النسخة القديمة من الهاتف وثبّت الجديدة."
)


def _missing_callback_methods(callback: Any, names: tuple[str, ...]) -> list[str]:
    missing: list[str] = []
    for name in names:
        try:
            getattr(callback, name)
        except AttributeError:
            missing.append(name)
        except Exception:
            pass
    return missing


def _require_callback_api(callback: Any, names: tuple[str, ...]) -> None:
    missing = _missing_callback_methods(callback, names)
    if missing:
        raise RuntimeError(_CALLBACK_HINT.format(names=", ".join(missing)))


class _OutputHub:
    """Collects stdout/stderr writes and hands them to Java in batches.

    One Java call plus one Flutter message per write() made a plain
    `for i in range(100000): print(i)` freeze the screen. Batches keep the
    original order of stdout and stderr.
    """

    FLUSH_CHARS = 4096

    def __init__(self, callback: Any):
        self.callback = callback
        self._lock = threading.Lock()
        self._parts: list[tuple[str, str]] = []
        self._size = 0

    def write(self, kind: str, text: str) -> None:
        with self._lock:
            self._parts.append((kind, text))
            self._size += len(text)
            if self._size >= self.FLUSH_CHARS:
                self._flush_locked()

    def flush(self) -> None:
        with self._lock:
            self._flush_locked()

    def _flush_locked(self) -> None:
        if not self._parts:
            return
        parts, self._parts, self._size = self._parts, [], 0
        grouped: list[tuple[str, list[str]]] = []
        for kind, text in parts:
            if grouped and grouped[-1][0] == kind:
                grouped[-1][1].append(text)
            else:
                grouped.append((kind, [text]))
        for kind, chunks in grouped:
            self.callback.emitOutput(kind, "".join(chunks))


class _BufferShim:
    """`sys.stdout.buffer` for scripts that write bytes."""

    def __init__(self, stream: Any):
        self._stream = stream

    def write(self, data: Any) -> int:
        if isinstance(data, (bytes, bytearray, memoryview)):
            self._stream.write(bytes(data).decode("utf-8", errors="replace"))
        else:
            self._stream.write(str(data))
        return len(data)

    def flush(self) -> None:
        self._stream.flush()

    def isatty(self) -> bool:
        return False


class _CallbackStream(io.TextIOBase):
    errors = "replace"
    line_buffering = False

    def __init__(self, callback: Any, kind: str, hub: "_OutputHub | None" = None):
        super().__init__()
        self.callback = callback
        self.kind = kind
        self.hub = hub

    def write(self, s: str) -> int:
        if s:
            if self.hub is not None:
                self.hub.write(self.kind, s)
            else:
                self.callback.emitOutput(self.kind, s)
        return len(s)

    def flush(self) -> None:
        if self.hub is not None:
            self.hub.flush()

    def reconfigure(self, **_kwargs: Any) -> None:
        # Scripts written for Windows often call sys.stdout.reconfigure(encoding="utf-8").
        return None

    @property
    def buffer(self) -> _BufferShim:
        return _BufferShim(self)

    def isatty(self) -> bool:
        return False

    @property
    def encoding(self) -> str:
        return "utf-8"


class _CallbackStdin(io.TextIOBase):
    def __init__(self, callback: Any, hub: "_OutputHub | None" = None):
        super().__init__()
        self.callback = callback
        self.hub = hub

    def ask(self, prompt: str = "") -> str:
        """input(prompt): show the prompt, wait for the user's line (stop-aware)."""
        if _should_stop(self.callback):
            raise StopRequested()
        if self.hub is not None:
            self.hub.flush()
        self.callback.emitInput(str(prompt))
        value = self.callback.requestInput(str(prompt))
        if value is None or _should_stop(self.callback):
            raise StopRequested()
        return str(value)

    def readline(self, size: int = -1) -> str:
        return self.ask("") + "\n"

    def read(self, size: int = -1) -> str:
        return self.readline(size)

    def isatty(self) -> bool:
        return False

    @property
    def encoding(self) -> str:
        return "utf-8"


_STOP_POLL_SECONDS = 0.05


def _trace_factory(callback: Any):
    """Line tracer that checks the stop flag at most every 50 ms.

    Every call into `callback` crosses into Java (slow), so asking on every
    line/opcode made ordinary loops crawl. A backward jump inside a loop still
    fires a "line" event, so even `while True: pass` stays stoppable.
    """
    state = {"last": 0.0, "dead": False}
    clock = time.monotonic

    def trace(frame, event, arg):
        if state["dead"]:
            # The run is over: threads the script left behind stop at their next line,
            # like daemon threads dying when CPython exits.
            raise StopRequested()
        now = clock()
        if now - state["last"] >= _STOP_POLL_SECONDS:
            state["last"] = now
            if _should_stop(callback):
                raise StopRequested()
        return trace

    trace.kill = lambda: state.__setitem__("dead", True)  # type: ignore[attr-defined]
    return trace


_RUNNING_LOOPS: "weakref.WeakSet[Any]" = weakref.WeakSet()


def _noop() -> None:
    return None


def _wake_loops() -> None:
    """Kick asyncio loops that sit idle inside select() so the tracer can run."""
    try:
        loops = list(_RUNNING_LOOPS)
    except Exception:
        return
    for loop in loops:
        try:
            loop.call_soon_threadsafe(_noop)
        except Exception:
            pass


class _Watchdog:
    """Helper thread for one script run.

    * flushes buffered output every 30 ms, so text appears while the script sleeps;
    * once Stop is pressed, wakes idle asyncio loops (a bot waiting for Telegram
      never executes a Python line, so the line tracer alone cannot stop it).

    Started with _thread, not threading: the script's tracer never touches it and
    it never shows up in threading.enumerate().
    """

    INTERVAL = 0.03

    def __init__(self, callback: Any, hub: _OutputHub):
        self.callback = callback
        self.hub = hub
        self._done = threading.Event()

    def start(self) -> None:
        _thread.start_new_thread(self._run, ())

    def finish(self) -> None:
        self._done.set()

    def _run(self) -> None:
        while not self._done.wait(self.INTERVAL):
            try:
                self.hub.flush()
                if _should_stop(self.callback):
                    _wake_loops()
            except Exception:
                pass


# ---------------------------------------------------------------------------
# Several scripts at the same time (one interpreter, one thread per script)
# ---------------------------------------------------------------------------
#
# Python has ONE sys.stdout, ONE builtins.input, ONE time.sleep ... per process.
# Instead of swapping those per run (which breaks as soon as two scripts overlap),
# they are replaced ONCE by small routers while at least one script runs. A router
# looks at the calling thread, finds the run that owns it, and forwards to that
# run's own output hub / input callback / stop flag. Threads started by a script
# inherit its run (threading.Thread.start is wrapped), so print() from a worker
# thread of script A never lands in script B's console.
#
# Still shared by all scripts (process-wide in CPython, cannot be split):
# the working directory, os.environ, sys.modules and the GIL.

_RUN_LOCAL = threading.local()
_RUNTIME_LOCK = threading.RLock()
_ACTIVE_RUNS: list["_RunContext"] = []
_RUNTIME_STATE: dict[str, Any] = {"patches": None, "path": None, "cwd": None, "paths": {}}


class _RunContext:
    """Everything that belongs to ONE running script."""

    def __init__(self, path: Path, callback: Any):
        self.path = path
        self.dir = str(path.parent)
        self.callback = callback
        self.hub = _OutputHub(callback)
        self.out = _CallbackStream(callback, "stdout", self.hub)
        self.err = _CallbackStream(callback, "stderr", self.hub)
        self.stdin = _CallbackStdin(callback, self.hub)
        self.trace = _trace_factory(callback)
        self.argv: list[str] = [str(path)]
        self.threads: list[threading.Thread] = []
        self.loop: Any = None
        self.finished = False

    def make_loop(self) -> None:
        """Like the main thread of CPython: asyncio.get_event_loop() just works."""
        try:
            import asyncio
        except Exception:
            return
        try:
            asyncio.get_running_loop()
        except RuntimeError:
            try:
                self.loop = asyncio.new_event_loop()
                asyncio.set_event_loop(self.loop)
            except Exception:
                self.loop = None

    def drop_loop(self) -> None:
        loop, self.loop = self.loop, None
        if loop is None:
            return
        try:
            import asyncio

            asyncio.set_event_loop(None)
        except Exception:
            pass
        try:
            if not loop.is_closed():
                loop.close()
        except Exception:
            pass


def _thread_ctx() -> "_RunContext | None":
    """The run that owns the calling thread (None for threads Bayan does not know)."""
    return getattr(_RUN_LOCAL, "ctx", None)


def _route_ctx() -> "_RunContext | None":
    """Owner of the calling thread; unknown threads fall back to the newest running script."""
    ctx = getattr(_RUN_LOCAL, "ctx", None)
    if ctx is not None:
        return ctx
    with _RUNTIME_LOCK:
        return _ACTIVE_RUNS[-1] if _ACTIVE_RUNS else None


class _RoutedStream(io.TextIOBase):
    """sys.stdout / sys.stderr while scripts run: forwards to the calling script's console."""

    errors = "replace"
    line_buffering = False

    def __init__(self, kind: str, original: Any):
        super().__init__()
        self.kind = kind
        self.original = original

    def _target(self) -> "_CallbackStream | None":
        ctx = _route_ctx()
        if ctx is None or ctx.finished:
            return None  # a script that already ended: drop late output
        return ctx.out if self.kind == "stdout" else ctx.err

    def write(self, s: str) -> int:
        target = self._target()
        if target is not None and s:
            target.write(s)
        return len(s)

    def flush(self) -> None:
        target = self._target()
        if target is not None:
            target.flush()

    def reconfigure(self, **_kwargs: Any) -> None:
        return None

    @property
    def buffer(self) -> _BufferShim:
        return _BufferShim(self)

    def isatty(self) -> bool:
        return False

    @property
    def encoding(self) -> str:
        return "utf-8"


class _RoutedStdin(io.TextIOBase):
    def readline(self, size: int = -1) -> str:
        ctx = _route_ctx()
        if ctx is None or ctx.finished:
            return ""
        return ctx.stdin.readline(size)

    def read(self, size: int = -1) -> str:
        return self.readline(size)

    def isatty(self) -> bool:
        return False

    @property
    def encoding(self) -> str:
        return "utf-8"


def _argv_delegate(name: str):
    def method(self, *args: Any, **kwargs: Any) -> Any:
        return getattr(self._current(), name)(*args, **kwargs)

    method.__name__ = name
    return method


class _ArgvProxy(list):
    """sys.argv that answers with the calling script's own argv."""

    _base: list

    def _current(self) -> list:
        ctx = _route_ctx()
        return ctx.argv if ctx is not None else self._base


for _name in (
    "__getitem__", "__setitem__", "__delitem__", "__iter__", "__len__", "__contains__",
    "__reversed__", "__eq__", "__ne__", "__repr__", "__str__", "append", "extend",
    "insert", "pop", "remove", "index", "count", "copy", "sort", "reverse", "clear",
):
    setattr(_ArgvProxy, _name, _argv_delegate(_name))
del _name


def _make_argv_proxy(base: list) -> _ArgvProxy:
    proxy = _ArgvProxy()
    proxy._base = list(base)
    list.extend(proxy, base)  # C code that reads the raw storage still sees something sensible
    return proxy


class _GlobalPatches:
    """The process-wide hooks. Installed with the first running script, removed after the last."""

    def __init__(self) -> None:
        self._undo: list[tuple[Any, str, Any]] = []
        self._saved_argv: Any = None

    def _patch(self, owner: Any, name: str, value: Any) -> None:
        self._undo.append((owner, name, getattr(owner, name)))
        setattr(owner, name, value)

    def install(self) -> None:
        self._saved_argv = getattr(sys, "argv", [""])
        self._patch(sys, "stdout", _RoutedStream("stdout", sys.stdout))
        self._patch(sys, "stderr", _RoutedStream("stderr", sys.stderr))
        self._patch(sys, "stdin", _RoutedStdin())
        self._patch(sys, "argv", _make_argv_proxy(self._saved_argv))

        orig_input = builtins.input

        def bayan_input(prompt: Any = "") -> str:
            ctx = _route_ctx()
            if ctx is None or ctx.finished:
                return orig_input(prompt)
            return ctx.stdin.ask(str(prompt))

        self._patch(builtins, "input", bayan_input)

        real_sleep = time.sleep

        def bayan_sleep(seconds: Any) -> None:
            ctx = _thread_ctx()
            try:
                remaining = float(seconds)
            except (TypeError, ValueError):
                return real_sleep(seconds)  # let Python raise its usual error
            if remaining == 0 or ctx is None:
                return real_sleep(seconds)
            if remaining < 0:
                raise ValueError("sleep length must be non-negative")
            callback = ctx.callback
            deadline = time.monotonic() + remaining
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    return None
                real_sleep(min(left, 0.1))
                if _should_stop(callback):
                    raise StopRequested()

        self._patch(time, "sleep", bayan_sleep)

        # signal.signal() only works on the main thread; scripts run on worker threads
        # (python-telegram-bot's run_polling() calls it), so outside it becomes a no-op.
        orig_signal = signal.signal

        def bayan_signal(signalnum: Any, handler: Any) -> Any:
            try:
                return orig_signal(signalnum, handler)
            except ValueError:
                if threading.current_thread() is threading.main_thread():
                    raise
                return signal.SIG_DFL

        self._patch(signal, "signal", bayan_signal)

        # A thread that dies because Stop was pressed (or because its script ended)
        # must not print a "StopRequested" traceback. Installed once and kept.
        if not getattr(threading.excepthook, "_bayan", False):
            orig_excepthook = threading.excepthook

            def bayan_excepthook(args: Any) -> None:
                if args.exc_type is not None and issubclass(args.exc_type, StopRequested):
                    return
                orig_excepthook(args)

            bayan_excepthook._bayan = True  # type: ignore[attr-defined]
            threading.excepthook = bayan_excepthook

        # Threads a script starts belong to that script: same console, same Stop button.
        orig_start = threading.Thread.start

        def bayan_start(thread: Any, *args: Any, **kwargs: Any) -> Any:
            ctx = _thread_ctx()
            if ctx is not None and not ctx.finished and not hasattr(thread, "_bayan_ctx"):
                thread._bayan_ctx = ctx
                ctx.threads.append(thread)
                inner = thread.run

                def run() -> Any:
                    _RUN_LOCAL.ctx = ctx
                    try:
                        sys.settrace(ctx.trace)
                    except Exception:
                        pass
                    return inner()

                thread.run = run
            return orig_start(thread, *args, **kwargs)

        self._patch(threading.Thread, "start", bayan_start)

        try:
            import asyncio
            from asyncio import base_events
        except Exception:
            return

        loop_cls = base_events.BaseEventLoop
        orig_run_forever = loop_cls.run_forever

        def run_forever(loop: Any) -> Any:
            _RUNNING_LOOPS.add(loop)
            try:
                return orig_run_forever(loop)
            finally:
                _RUNNING_LOOPS.discard(loop)

        self._patch(loop_cls, "run_forever", run_forever)

        unix_cls = getattr(getattr(asyncio, "unix_events", None), "_UnixSelectorEventLoop", None)
        if unix_cls is not None:
            orig_add = unix_cls.add_signal_handler
            orig_remove = unix_cls.remove_signal_handler

            def add_signal_handler(loop: Any, sig: Any, cb: Any, *args: Any) -> Any:
                try:
                    return orig_add(loop, sig, cb, *args)
                except (RuntimeError, ValueError, OSError):
                    if threading.current_thread() is threading.main_thread():
                        raise
                    return None

            def remove_signal_handler(loop: Any, sig: Any) -> Any:
                try:
                    return orig_remove(loop, sig)
                except (RuntimeError, ValueError, OSError):
                    if threading.current_thread() is threading.main_thread():
                        raise
                    return False

            self._patch(unix_cls, "add_signal_handler", add_signal_handler)
            self._patch(unix_cls, "remove_signal_handler", remove_signal_handler)

    def restore(self) -> None:
        while self._undo:
            owner, name, value = self._undo.pop()
            try:
                setattr(owner, name, value)
            except Exception:
                pass


def _acquire_runtime(ctx: _RunContext, site: str) -> None:
    """Register a starting script. The first one installs the hooks and remembers cwd/sys.path."""
    with _RUNTIME_LOCK:
        state = _RUNTIME_STATE
        if not _ACTIVE_RUNS:
            patches = _GlobalPatches()
            patches.install()
            state["patches"] = patches
            state["path"] = list(sys.path)
            state["cwd"] = Path.cwd()
            state["paths"] = {}
        _ACTIVE_RUNS.append(ctx)
        counts: dict[str, int] = state["paths"]
        for entry in (ctx.dir, site):
            counts[entry] = counts.get(entry, 0) + 1
        sys.path[:] = [ctx.dir, site] + [p for p in sys.path if p not in {ctx.dir, site}]
        os.chdir(ctx.dir)
        # raw storage of the argv proxy follows the newest script (the proxy itself routes per thread)
        try:
            list.__setitem__(sys.argv, slice(None), ctx.argv)
        except Exception:
            pass


def _release_runtime(ctx: _RunContext, site: str) -> None:
    with _RUNTIME_LOCK:
        state = _RUNTIME_STATE
        if ctx in _ACTIVE_RUNS:
            _ACTIVE_RUNS.remove(ctx)
        counts: dict[str, int] = state["paths"]
        saved_path: list[str] = state["path"] or []
        for entry in (ctx.dir, site):
            counts[entry] = counts.get(entry, 1) - 1
            if counts[entry] <= 0:
                counts.pop(entry, None)
                if entry not in saved_path and entry in sys.path:
                    sys.path.remove(entry)
        if _ACTIVE_RUNS:
            try:
                os.chdir(_ACTIVE_RUNS[-1].dir)
            except Exception:
                pass
            return
        patches = state["patches"]
        state["patches"] = None
        if patches is not None:
            patches.restore()
        sys.path[:] = saved_path
        try:
            os.chdir(state["cwd"] or Path.cwd())
        except Exception:
            pass
        state["path"] = None
        state["cwd"] = None
        state["paths"] = {}


def active_run_count() -> int:
    with _RUNTIME_LOCK:
        return len(_ACTIVE_RUNS)


def _join_user_threads(ctx: _RunContext, callback: Any) -> None:
    """Like CPython at exit: wait for non-daemon threads THIS script started."""
    me = threading.current_thread()
    while True:
        alive = [t for t in list(ctx.threads) if t is not me and not t.daemon and t.is_alive()]
        # Ask about Stop AFTER listing the threads and BEFORE returning. A thread that
        # dies because Stop was pressed (StopRequested) can vanish between two polls;
        # with the old order the list came back empty and the run ended with 0
        # instead of 130. The flag never goes back to False during a run, so if a
        # thread died because of Stop, this poll is guaranteed to see it.
        if _should_stop(callback):
            raise StopRequested()
        if not alive:
            return
        alive[0].join(0.1)


def _reap_user_threads(ctx: _RunContext, timeout: float) -> None:
    """After the run: give THIS script's leftover threads a moment to notice they must stop."""
    me = threading.current_thread()
    deadline = time.monotonic() + timeout
    for t in list(ctx.threads):
        if t is me:
            continue
        left = deadline - time.monotonic()
        if left <= 0:
            break
        try:
            t.join(left)
        except Exception:
            pass
    ctx.threads.clear()


def _run_exit_code(value: Any) -> int:
    if value is None:
        return 0
    if isinstance(value, int):
        return int(value)
    try:
        return int(str(value))
    except Exception:
        return 1


def _is_internal_frame(frame: Any) -> bool:
    """Frames that belong to Chaquopy's import machinery, not to the user's code.

    Example of the noise they add to a ModuleNotFoundError traceback:
        File "import.pxi", line 60, in java.chaquopy.import_override
    """
    filename = str(getattr(frame, "filename", "") or "").replace("\\", "/")
    name = str(getattr(frame, "name", "") or "")
    return filename.rsplit("/", 1)[-1] == "import.pxi" or name.startswith("java.chaquopy")


def _drop_internal_frames(te: traceback.TracebackException, seen: set[int]) -> None:
    """Remove internal frames from `te` and from every chained exception."""
    if id(te) in seen:
        return
    seen.add(id(te))
    te.stack[:] = [f for f in te.stack if not _is_internal_frame(f)]
    for child in (te.__cause__, te.__context__):
        if child is not None:
            _drop_internal_frames(child, seen)
    for child in getattr(te, "exceptions", None) or ():
        _drop_internal_frames(child, seen)


def _print_user_traceback(exc: BaseException, file: Any) -> None:
    """Print a traceback without the runner's own or Chaquopy's internal frames."""
    tb = exc.__traceback__
    while tb is not None and tb.tb_frame.f_globals is globals():
        tb = tb.tb_next
    try:
        te = traceback.TracebackException(type(exc), exc, tb)
        _drop_internal_frames(te, set())
        file.write("".join(te.format()))
        return
    except Exception:
        pass
    try:
        traceback.print_exception(type(exc), exc, tb, file=file)
    except Exception:
        file.write(f"{type(exc).__name__}: {exc}\n")


# ---------------------------------------------------------------------------
# Missing-library detection (cards under the error in the output screen)
# ---------------------------------------------------------------------------

# import name -> name on PyPI, for the cases where they differ.
_IMPORT_TO_DIST = {
    "cv2": "opencv-python",
    "PIL": "Pillow",
    "bs4": "beautifulsoup4",
    "yaml": "PyYAML",
    "telegram": "python-telegram-bot",
    "telebot": "pyTelegramBotAPI",
    "dotenv": "python-dotenv",
    "sklearn": "scikit-learn",
    "dateutil": "python-dateutil",
    "Crypto": "pycryptodome",
    "serial": "pyserial",
    "jwt": "PyJWT",
}

_TRY_NODES = tuple(t for t in (ast.Try, getattr(ast, "TryStar", None)) if t is not None)
# An import inside `try: ... except <one of these>` is optional by design.
_IMPORT_GUARD_NAMES = {"ImportError", "ModuleNotFoundError", "Exception", "BaseException"}


def _handler_names(node: ast.expr | None) -> set[str]:
    if node is None:  # bare `except:`
        return {"BaseException"}
    items = node.elts if isinstance(node, ast.Tuple) else [node]
    names: set[str] = set()
    for item in items:
        if isinstance(item, ast.Name):
            names.add(item.id)
        elif isinstance(item, ast.Attribute):
            names.add(item.attr)
    return names


def _scan_imports(source: str) -> list[tuple[str, bool]]:
    """Return (top-level module, inside try/except ImportError) for every absolute import."""
    try:
        tree = ast.parse(source)
    except Exception:
        return []
    found: list[tuple[str, bool]] = []

    def visit(node: ast.AST, guarded: bool) -> None:
        if isinstance(node, ast.Import):
            for alias in node.names:
                found.append((alias.name.split(".")[0], guarded))
        elif isinstance(node, ast.ImportFrom):
            if node.level == 0 and node.module:  # relative imports are local files
                found.append((node.module.split(".")[0], guarded))
        if _TRY_NODES and isinstance(node, _TRY_NODES):
            catches = any(_handler_names(h.type) & _IMPORT_GUARD_NAMES for h in node.handlers)
            for child in node.body:
                visit(child, guarded or catches)
            for handler in node.handlers:
                for child in handler.body:
                    visit(child, guarded)
            for child in list(node.orelse) + list(node.finalbody):
                visit(child, guarded)
            return
        for child in ast.iter_child_nodes(node):
            visit(child, guarded)

    try:
        visit(tree, False)
    except RecursionError:
        pass
    return found


def _missing_libraries(path: Path, source: str, exc: BaseException) -> list[dict[str, Any]]:
    """Libraries the script needs but cannot import, the failing one first.

    Only used when the run ended with ModuleNotFoundError, so that when three
    libraries are missing the user sees three cards at once instead of fixing
    them one failed run at a time.
    """
    stdlib = set(getattr(sys, "stdlib_module_names", ())) | {"__future__"}
    script_dir = path.parent
    failed = (getattr(exc, "name", None) or "").split(".")[0]
    candidates: list[tuple[str, bool]] = []
    if failed:
        candidates.append((failed, True))
    for root, guarded in _scan_imports(source):
        if guarded and root != failed:
            continue  # optional import that did not fail
        candidates.append((root, root == failed))

    out: list[dict[str, Any]] = []
    seen_roots: set[str] = set()
    seen_dists: set[str] = set()
    for root, is_failed in candidates:
        if not root or root in seen_roots:
            continue
        seen_roots.add(root)
        if root in stdlib:
            continue
        if (script_dir / f"{root}.py").is_file() or (script_dir / root).is_dir():
            continue  # a local module next to the script
        try:
            if importlib.util.find_spec(root) is not None:
                continue  # importable (a submodule may be what is missing, not the library)
        except Exception:
            continue
        dist = _IMPORT_TO_DIST.get(root, root)
        norm = _norm_name(dist)
        if norm in seen_dists:
            continue
        try:
            if _installed_version(norm):
                continue  # installing it again would not help
        except Exception:
            pass
        seen_dists.add(norm)
        out.append({"module": root, "package": dist, "failed": is_failed})
    return out


def run_script(script_path: str, callback: Any) -> int:
    """Execute one user script. Several can run at the same time, each on its own thread."""
    _, _, site, _ = _require_config()
    _require_callback_api(callback, _RUN_CALLBACK_REQUIRED)
    path = Path(script_path).resolve()
    if not path.is_file():
        callback.emitError(f"الملف غير موجود: {path}")
        callback.emitExit(1)
        return 1

    ctx = _RunContext(path, callback)
    hub, err = ctx.hub, ctx.err
    site_str = str(site)
    old_trace = sys.gettrace()
    watchdog = _Watchdog(callback, hub)
    exit_code = 0
    source = ""
    missing_payload = ""
    acquired = False
    watchdog.start()
    callback.emitState("running")

    try:
        _RUN_LOCAL.ctx = ctx
        _acquire_runtime(ctx, site_str)
        acquired = True
        ctx.make_loop()
        sys.settrace(ctx.trace)

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
        _join_user_threads(ctx, callback)
        exit_code = 0
    except StopRequested:
        exit_code = 130
        callback.emitState("stopped")
    except SystemExit as exc:
        exit_code = _run_exit_code(exc.code)
        if isinstance(exc.code, str) and exc.code:
            # Same as CPython: sys.exit("message") prints the message to stderr.
            err.write(exc.code + "\n")
    except BaseException as exc:
        exit_code = 1
        _print_user_traceback(exc, err)
        if isinstance(exc, ModuleNotFoundError):
            try:
                missing = _missing_libraries(path, source, exc)
                if missing:
                    missing_payload = json.dumps(missing, ensure_ascii=False)
            except Exception:
                missing_payload = ""
    finally:
        try:
            sys.settrace(old_trace)
        except Exception:
            pass
        try:
            ctx.trace.kill()
            _reap_user_threads(ctx, 1.0)
        except Exception:
            pass
        ctx.drop_loop()
        try:
            hub.flush()
        except Exception:
            pass
        ctx.finished = True
        _RUN_LOCAL.ctx = None
        if acquired:
            try:
                _release_runtime(ctx, site_str)
            except Exception:
                pass
        importlib.invalidate_caches()
        if missing_payload:
            try:
                callback.emitMissing(missing_payload)
            except Exception:
                pass
        watchdog.finish()
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
    # Extras such as requests[socks] are optional features; ignore the brackets.
    remainder = re.sub(r"^\s*\[[^\]]*\]", "", remainder).strip()
    if remainder:
        remainder = remainder.replace("(", "").replace(")", "")
        for part in re.split(r",\s*", remainder):
            m = re.match(r"^(===|==|!=|<=|>=|<|>|~=)\s*([A-Za-z0-9!+._*-]+)$", part.strip())
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
    v = v.lstrip("v")
    m = re.match(r"^([0-9]+(?:\.[0-9]+)*)(.*)$", v)
    if not m:
        # Same 5-field shape as below so tuples are always comparable.
        return (epoch, (0,), 3, 0, 0)
    release = tuple(int(x) for x in m.group(1).split("."))
    # 1.0 == 1.0.0: drop trailing zeros so comparisons follow PEP 440.
    while len(release) > 1 and release[-1] == 0:
        release = release[:-1]
    tail = m.group(2)
    pre_rank = 3
    pre_num = 0
    post = 0
    if tail:
        # dev releases sort before every pre-release of the same version.
        if re.search(r"(?:^|[._-])dev", tail):
            pre_rank = -1
        pm = re.search(r"(?:^|[._-])(a|alpha|b|beta|c|rc|pre|preview)[._-]?([0-9]*)", tail)
        if pm:
            pre_tag = pm.group(1)
            pre_rank = {"a": 0, "alpha": 0, "b": 1, "beta": 1, "c": 2, "rc": 2, "pre": 2, "preview": 2}[pre_tag]
            pre_num = int(pm.group(2) or 0)
        postm = re.search(r"(?:post|rev|r)[._-]?([0-9]+)", tail)
        if postm:
            post = int(postm.group(1)) + 1
    return (epoch, release, pre_rank, pre_num, post)


def _is_prerelease(v: str) -> bool:
    """True for alpha/beta/rc/dev versions (pip skips these by default)."""
    parts = _version_parts(v)
    return parts[2] != 3


def _cmp_version(a: str, b: str) -> int:
    pa, pb = _version_parts(a), _version_parts(b)
    if pa < pb:
        return -1
    if pa > pb:
        return 1
    return 0


def _wildcard_match(version: str, wanted: str) -> bool:
    """PEP 440 prefix matching for `==1.2.*` / `!=1.2.*`."""
    prefix = wanted[:-2].lower()
    version = version.lower().split("+", 1)[0]
    return version == prefix or version.startswith(prefix + ".")


def _satisfies(version: str, constraints: list[tuple[str, str]]) -> bool:
    for op, wanted in constraints:
        if wanted.endswith(".*") and op in {"==", "!="}:
            matches = _wildcard_match(version, wanted)
            if (op == "==" and not matches) or (op == "!=" and matches):
                return False
            continue
        if op == "===":
            if version.strip().lower() != wanted.strip().lower():
                return False
            continue
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
        return {
            "arm64-v8a": "aarch64",
            "armeabi-v7a": "armv7l",
            "x86_64": "x86_64",
            "x86": "i686",
        }.get(os.environ.get("BAYAN_ABI", "arm64-v8a"), "aarch64")
    if name == "platform_system":
        return "Android"
    if name == "os_name":
        return "posix"
    if name == "implementation_name":
        return "cpython"
    if name in {"platform_python_implementation", "python_implementation"}:
        return "CPython"
    if name == "implementation_version":
        return f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
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


def _http_read(url: str, accept: str | None = None, timeout: float = 25, attempts: int = 2) -> bytes:
    """GET with one retry for transient server/network errors."""
    headers = {"User-Agent": "Bayan-Python/1.0"}
    if accept:
        headers["Accept"] = accept
    last: Exception | None = None
    for attempt in range(attempts):
        req = urllib.request.Request(urllib.parse.urldefrag(url)[0], headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            if exc.code in (500, 502, 503, 504) and attempt + 1 < attempts:
                last = exc
                time.sleep(0.6)
                continue
            raise
        except OSError as exc:  # URLError, timeouts, connection resets
            last = exc
            if attempt + 1 < attempts:
                time.sleep(0.6)
                continue
            raise
    assert last is not None
    raise last


def _pypi_simple_releases(key: str) -> dict[str, list[dict[str, Any]]]:
    """Release/file list from PyPI's Simple API (PEP 691 JSON).

    PyPI documents the legacy `releases` key of /pypi/<name>/json as deprecated
    and possibly removed in future, so this is used as the fallback.
    """
    url = PYPI_SIMPLE.format(name=urllib.parse.quote(key, safe=""))
    raw = _http_read(url, accept="application/vnd.pypi.simple.v1+json")
    data = json.loads(raw.decode("utf-8"))
    releases: dict[str, list[dict[str, Any]]] = {}
    for item in data.get("files") or []:
        filename = item.get("filename", "")
        info = _parse_wheel_filename(filename)
        if not info:
            continue
        releases.setdefault(info["version"], []).append(
            {
                "filename": filename,
                "url": item.get("url"),
                "digests": {"sha256": (item.get("hashes") or {}).get("sha256")},
                "requires_python": item.get("requires-python"),
                "size": item.get("size") or 0,
                "yanked": bool(item.get("yanked")),
            }
        )
    return releases


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
    try:
        data = json.loads(_http_read(url).decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise ValueError("لم يتم العثور على مكتبة بهذا الاسم")
        raise RuntimeError(f"PyPI HTTP {exc.code}")
    except urllib.error.URLError as exc:
        raise RuntimeError(f"تعذر الاتصال بـPyPI: {exc.reason}")
    except OSError as exc:
        raise RuntimeError(f"تعذر الاتصال بـPyPI: {exc}")
    if not data.get("releases"):
        try:
            data["releases"] = _pypi_simple_releases(key)
        except Exception:
            data["releases"] = {}
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
    # name-version(-build)?-python-abi-platform. Chaquopy wheels always carry a
    # build tag (e.g. PyYAML-6.0.2-0-cp313-cp313-android_21_arm64_v8a.whl); the
    # old code read that build tag ("0") as the version.
    parts = filename[:-4].split("-")
    if len(parts) not in (5, 6):
        return None
    py_tag, abi_tag, platform_tag = parts[-3], parts[-2], parts[-1]
    version = parts[1]
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
    current_cp = f"cp{sys.version_info.major}{sys.version_info.minor}"
    py_tags = py.split(".")
    py_ok = bool({"py3", f"py{sys.version_info.major}", current_cp} & set(py_tags))
    if not py_ok and info["abi"] == "abi3":
        # Stable-ABI wheels built for an older CPython run on newer ones too.
        for tag in py_tags:
            m_abi = re.match(r"^cp3(\d+)$", tag)
            if m_abi and int(m_abi.group(1)) <= sys.version_info.minor:
                py_ok = True
    if not py_ok:
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


def _chaquopy_wheel(name: str, constraints: list[tuple[str, str]] | None = None) -> dict[str, Any] | None:
    url = CHAQUOPY_INDEX.format(name=urllib.parse.quote(_norm_name(name), safe=""))
    try:
        text = _http_read(url).decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise RuntimeError(f"Chaquopy wheel index HTTP {exc.code}")
    except urllib.error.URLError as exc:
        raise RuntimeError(f"تعذر الاتصال بمستودع Chaquopy: {exc.reason}")
    except OSError as exc:
        raise RuntimeError(f"تعذر الاتصال بمستودع Chaquopy: {exc}")
    hrefs = re.findall(r'href=["\']([^"\']+)["\']', text, flags=re.I)
    items: list[dict[str, Any]] = []
    for href in hrefs:
        base, _, fragment = href.partition("#")
        filename = urllib.parse.unquote(base.rsplit("/", 1)[-1])
        info = _parse_wheel_filename(filename)
        if not info or not _wheel_compatible(filename):
            continue
        if constraints and not _satisfies(info["version"], constraints):
            continue
        sha = fragment[len("sha256="):] if fragment.startswith("sha256=") else None
        items.append(
            {
                "filename": filename,
                "url": urllib.parse.urljoin(url, base),
                "digests": {"sha256": sha} if sha else {},
                "requires_python": None,
                "source": "chaquopy",
                "version": info["version"],
            }
        )
    if not items:
        return None
    stable = [i for i in items if not _is_prerelease(i["version"])]
    pool = stable or items
    pool.sort(key=lambda x: _version_parts(x["version"]), reverse=True)
    return pool[0]


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


def _select_pypi_candidate(data: dict[str, Any], constraints: list[tuple[str, str]]) -> dict[str, Any] | None:
    """Newest release with a wheel this device can run.

    Like pip: skips yanked files and pre-releases unless nothing else fits.
    """
    releases = data.get("releases") or {}
    info_requires = (data.get("info") or {}).get("requires_python")
    versions = sorted(releases.keys(), key=_version_parts, reverse=True)
    for allow_pre in (False, True):
        for version in versions:
            if not allow_pre and _is_prerelease(version):
                continue
            if constraints and not _satisfies(version, constraints):
                continue
            files = [
                f
                for f in releases.get(version, [])
                if not f.get("yanked")
                and _wheel_compatible(f.get("filename", ""))
                and _requires_python_ok(f.get("requires_python") or info_requires)
            ]
            if not files:
                continue
            # A platform-specific Android wheel beats a generic one.
            files.sort(key=lambda f: 0 if "android" in f.get("filename", "") else 1)
            candidate = dict(files[0])
            candidate["version"] = version
            candidate["source"] = "pypi"
            return candidate
    return None


def _obtain_wheel(name: str, constraints: list[tuple[str, str]], callback: Any | None = None) -> tuple[Path, dict[str, Any]]:
    data = _get_json(name, callback)
    releases = data.get("releases") or {}
    # Search PyPI first for a compatible pure-Python or Android-specific wheel.
    candidate = _select_pypi_candidate(data, constraints)

    # If PyPI has no Android-compatible native wheel, use Chaquopy's Android wheel repo.
    if candidate is None:
        candidate = _chaquopy_wheel(name, constraints)
        if candidate is not None and constraints and not _satisfies(candidate["version"], constraints):
            candidate = None

    if candidate is None:
        raise ValueError("لا توجد wheel متوافقة مع Python/Android/ABI الحاليين لهذا الإصدار")

    version = candidate["version"]
    filename = candidate["filename"]
    sha = (candidate.get("digests") or {}).get("sha256")
    path = _wheel_cache_path(name, version, filename, sha)
    try:
        wheel_size = int(candidate.get("size") or 0)
    except (TypeError, ValueError):
        wheel_size = 0
    if path.is_file() and path.stat().st_size > 0:
        if sha:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            if digest.lower() != sha.lower():
                path.unlink()
            else:
                if callback is not None:
                    callback.emitPackage("wheel_cached", path.stat().st_size, 0, path.name)
                return path, candidate
        else:
            try:
                with zipfile.ZipFile(path) as zf:
                    zf.testzip()
                if callback is not None:
                    callback.emitPackage("wheel_cached", path.stat().st_size, 0, path.name)
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
        # Tells the UI the size of this wheel before it downloads, so the
        # progress bar can weigh all wheels of one install against each other.
        callback.emitPackage("wheel", wheel_size, 0, path.name)
        callback.emitPackage("download_start", 0, 0, path.name)
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
    # Dependency cycles are legal in the wild (pip tolerates them): a package
    # that is already being planned further up the chain is simply skipped.
    if norm in visiting:
        return
    planned = next((meta for _, meta, _, _ in plan if _norm_name(meta["name"]) == norm), None)
    if planned is not None and _satisfies(planned["version"], constraints):
        return
    visiting.add(norm)
    try:
        wheel_path, _source = _obtain_wheel(norm, constraints, callback)
        metadata, reqs, top = _read_metadata_from_wheel(wheel_path)
        actual_norm = _norm_name(metadata["name"] or norm)
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
    finally:
        visiting.discard(norm)


def _relocate_member(safe: str) -> str | None:
    """Map a wheel member to its path under site-packages.

    `<name>-<ver>.data/purelib|platlib/...` is installed straight into
    site-packages. Scripts, headers and other data have no meaning for Bayan's
    runtime, so they are skipped instead of failing the whole installation.
    """
    first, _, rest = safe.partition("/")
    if first.endswith(".data"):
        if rest.startswith(("purelib/", "platlib/")):
            return rest.split("/", 1)[1] if "/" in rest else None
        return None
    return safe


def _top_level_from_files(files: list[str]) -> list[str]:
    """Importable top-level names found in the installed files.

    Many modern wheels (hatchling, flit, uv, ...) ship no top_level.txt.
    """
    names: list[str] = []
    for rel in files:
        first, sep, _rest = rel.partition("/")
        if first.endswith((".dist-info", ".data")) or first == "__pycache__":
            continue
        if sep:
            candidate = first
        elif rel.endswith(".py"):
            candidate = rel[:-3]
        elif ".so" in rel:
            candidate = rel.split(".", 1)[0]
        else:
            continue
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", candidate) and candidate not in names:
            names.append(candidate)
    return names


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
            relocated = _relocate_member(safe)
            if relocated is None:
                continue
            safe = relocated
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
                relocated = _relocate_member(safe) if safe else None
                if relocated:
                    out.append(relocated)
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
    # The PEP 376 REQUESTED marker is not listed in RECORD, so it is moved to the
    # rollback storage explicitly. Otherwise it would outlive the library and
    # make a later automatic (companion) install of it look user-requested.
    marker = dist_info / REQUESTED_NAME
    if marker.is_file() or marker.is_symlink():
        try:
            marker_rel = marker.relative_to(site).as_posix()
        except ValueError:
            marker_rel = ""
        if marker_rel and marker_rel not in backed:
            marker_backup = backup_root / marker_rel
            marker_backup.parent.mkdir(parents=True, exist_ok=True)
            os.replace(marker, marker_backup)
            backed.add(marker_rel)
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


def _dist_requires(parsed: Any) -> set[str]:
    """Normalised names of the dependencies a distribution needs right now.

    Uses the same marker evaluation as the install plan; extras are ignored (a
    requirement behind `extra == ...` is never installed, so it never counts).
    """
    out: set[str] = set()
    for raw in parsed.get_all("Requires-Dist") or []:
        try:
            parts = _req_parts(raw)
        except Exception:
            continue
        if parts is not None and parts[0]:
            out.add(parts[0])
    return out


def _scan_distributions() -> dict[str, dict[str, Any]]:
    """Every installed distribution with a readable METADATA, keyed by normalised name.

    A dist-info without METADATA (or without Name/Version) is ignored. If two
    dist-info folders carry the same name the first one wins, like
    `_distribution_record`.
    """
    _, _, site, _ = _require_config()
    entries: dict[str, dict[str, Any]] = {}
    for dist in sorted(site.glob("*.dist-info"), key=lambda p: p.name.lower()):
        meta_file = dist / "METADATA"
        if not meta_file.is_file():
            continue
        try:
            parsed = Parser().parsestr(meta_file.read_text("utf-8", errors="replace"))
            name = parsed.get("Name", "").strip()
            version = parsed.get("Version", "").strip()
            if not name or not version:
                continue
            norm = _norm_name(name)
            if norm in entries:
                continue
            entries[norm] = {
                "name": name,
                "version": version,
                "dist": dist,
                "explicit": (dist / REQUESTED_NAME).is_file(),
                "requires": _dist_requires(parsed),
            }
        except Exception:
            continue
    return entries


def _reachable(start: Any, entries: dict[str, dict[str, Any]], excluded: set[str] | None = None) -> set[str]:
    """Distributions reachable from `start` through installed dependencies (cycle-safe)."""
    skip = excluded or set()
    seen: set[str] = set()
    stack = [n for n in start if n in entries and n not in skip]
    while stack:
        node = stack.pop()
        if node in seen:
            continue
        seen.add(node)
        for dep in entries[node]["requires"]:
            if dep in entries and dep not in skip and dep not in seen:
                stack.append(dep)
    return seen


def _classify_requested(entries: dict[str, dict[str, Any]]) -> dict[str, bool]:
    """norm -> True if the user asked for it, False if it is only a companion.

    A distribution counts as requested when it carries the REQUESTED marker, or
    when no other installed distribution needs it (libraries installed before
    the marker existed). Everything else that is reachable from those is a
    companion. An unmarked group that only needs itself (a dependency cycle
    nobody else uses) is treated as requested, so it never becomes invisible.
    """
    needed_by: dict[str, set[str]] = {n: set() for n in entries}
    for norm, entry in entries.items():
        for dep in entry["requires"]:
            if dep in entries and dep != norm:
                needed_by[dep].add(norm)
    roots = {n for n, e in entries.items() if e["explicit"] or not needed_by[n]}
    reach = _reachable(roots, entries)
    return {n: (n in roots) or (n not in reach) for n in entries}


def _removal_set(norm: str, entries: dict[str, dict[str, Any]], requested: dict[str, bool]) -> list[str]:
    """`norm` first, then the companions nothing else needs once it is gone."""
    removed = {norm}
    keep_roots = [n for n in entries if n not in removed and requested.get(n, True)]
    alive = _reachable(keep_roots, entries, removed)
    orphans = sorted(n for n in entries if n not in removed and n not in alive and not requested.get(n, True))
    return [norm, *orphans]


def _current_packages() -> list[dict[str, Any]]:
    _, _, site, _ = _require_config()
    entries = _scan_distributions()
    requested = _classify_requested(entries)
    needed_by: dict[str, set[str]] = {n: set() for n in entries}
    for norm, entry in entries.items():
        for dep in entry["requires"]:
            if dep in entries and dep != norm:
                needed_by[dep].add(norm)
    out: list[dict[str, Any]] = []
    for norm, entry in entries.items():
        size = 0
        for rel in _record_paths(entry["dist"]):
            p = site / rel
            try:
                if p.is_file():
                    size += p.stat().st_size
            except OSError:
                pass
        out.append({
            "name": entry["name"],
            "version": entry["version"],
            "size": size,
            "requested": requested[norm],
            "requiredBy": sorted((entries[n]["name"] for n in needed_by[norm]), key=str.lower),
            "requires": sorted((entries[d]["name"] for d in entry["requires"] if d in entries and d != norm), key=str.lower),
        })
    out.sort(key=lambda item: item["name"].lower())
    return out


def list_installed() -> str:
    return json.dumps(_current_packages(), ensure_ascii=False)


def _latest_compatible_for(name: str) -> dict[str, Any]:
    data = _get_json(name)
    found = _select_pypi_candidate(data, [])
    if found:
        return {"version": found["version"], "size": found.get("size") or 0, "compatible": True}
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


def _availability_for(name: str) -> dict[str, Any]:
    """Is there a build of this library that runs on this Android/Python? (available: None = unknown)"""
    try:
        info = _latest_compatible_for(name)
    except ValueError:
        # Not on PyPI under this name; Chaquopy's repository may still have it.
        try:
            native = _chaquopy_wheel(name)
        except Exception:
            native = None
        if native:
            return {"name": name, "available": True, "version": native["version"], "reason": ""}
        return {"name": name, "available": False, "version": None, "reason": "المكتبة غير موجودة في PyPI"}
    except Exception as exc:
        return {"name": name, "available": None, "version": None, "reason": str(exc)}
    if info.get("compatible"):
        return {"name": name, "available": True, "version": info.get("version"), "reason": ""}
    return {"name": name, "available": False, "version": None, "reason": "لا توجد نسخة منها تعمل على أندرويد"}


def check_availability(names_json: str) -> str:
    """Availability of several libraries, looked up in parallel (PyPI first, then Chaquopy)."""
    try:
        raw = json.loads(names_json)
    except Exception:
        raw = []
    names: list[str] = []
    for item in raw if isinstance(raw, list) else []:
        text = str(item).strip()
        if text and text not in names:
            names.append(text)
    names = names[:12]
    if not names:
        return "[]"
    with ThreadPoolExecutor(max_workers=min(4, len(names))) as pool:
        results = list(pool.map(_availability_for, names))
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
    _require_callback_api(callback, _PACKAGE_CALLBACK_REQUIRED)
    with _PACKAGE_LOCK:
        callback.emitPackage("start", 0, 0, "بدء التثبيت")
        root_norm, root_constraints = _parse_spec(spec)
        plan: list[tuple[Path, dict[str, Any], list[str], list[str]]] = []
        _plan_package(root_norm, root_constraints, callback, plan, set())
        if not plan:
            installed = _installed_version(root_norm)
            # Already there (maybe pulled in earlier as a companion): the user
            # asked for it explicitly now, so it becomes a requested library.
            found_root = _distribution_record(root_norm)
            if found_root is not None:
                try:
                    (found_root[0] / REQUESTED_NAME).write_text("", encoding="utf-8")
                except OSError:
                    pass
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
        primary_top: list[str] = []
        try:
            callback.emitPackage("dependencies", 0, len(plan), f"تم العثور على {len(plan)} حزمة")
            for index, (wheel_path, metadata, reqs, top) in enumerate(plan, 1):
                norm = _norm_name(metadata["name"])
                callback.emitPackage("verify", index - 1, len(plan), f"التحقق من {metadata['name']} {metadata['version']}")
                # Remove older distribution contents into rollback storage.
                old = _distribution_record(norm)
                # Only the library the user asked for gets the marker, plus any
                # library that already had it (an upgrade must not lose it).
                want_marker = norm == primary_name or bool(old and (old[0] / REQUESTED_NAME).is_file())
                if old and old[1]["version"] != metadata["version"]:
                    _remove_distribution_files(old[0], site, backup_root, backed)
                stage = install_root / re.sub(r"[^A-Za-z0-9_.-]+", "_", f"{norm}-{metadata['version']}")
                files, dist_rel = _extract_wheel(wheel_path, stage)
                if want_marker:
                    marker_rel = f"{dist_rel}/{REQUESTED_NAME}"
                    (stage / marker_rel).write_text("", encoding="utf-8")
                    if marker_rel not in files:
                        files.append(marker_rel)
                callback.emitPackage("install", index - 1, len(plan), f"تثبيت {metadata['name']} {metadata['version']}")
                _install_from_staging(stage, files, site, backup_root, backed, installed_now)
                if norm == primary_name:
                    primary_version = metadata["version"]
                    primary_top = list(top) or _top_level_from_files(files)
                # Drop cached modules from the shared site-packages tree so updates
                # become visible to the next import in the same Python process.
                _clear_site_modules()
                if _should_stop(callback):
                    raise RuntimeError("تم إيقاف التثبيت")

            # Verify the primary distribution by importing a top-level module.
            _clear_site_modules()
            primary = next((item for item in plan if _norm_name(item[1]["name"]) == primary_name), None)
            if primary is None:
                raise RuntimeError("لم تكتمل خطة تثبيت المكتبة المطلوبة")
            top_levels = primary_top or primary[3] or [primary_name.replace("-", "_")]
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
    """Remove a library together with the companions that nothing else needs.

    A companion stays if another installed library still needs it, or if the user
    asked for it explicitly. Everything happens in one transaction: if any file
    cannot be moved, the files already moved are put back.
    """
    with _PACKAGE_LOCK:
        norm, _ = _parse_spec(name)
        entries = _scan_distributions()
        found = entries.get(norm)
        if not found:
            return json.dumps({"ok": False, "error": "المكتبة غير مثبتة"}, ensure_ascii=False)
        _, _, site, cache = _require_config()
        requested = _classify_requested(entries)
        order = _removal_set(norm, entries, requested)
        transaction = Path(tempfile.mkdtemp(prefix="rm-", dir=str(cache / "tmp")))
        backup = transaction / "backup"
        backed: set[str] = set()
        try:
            for victim in order:
                _remove_distribution_files(entries[victim]["dist"], site, backup, backed)
            _cleanup_empty_dirs(site)
            companions = [{"name": entries[n]["name"], "version": entries[n]["version"]} for n in order[1:]]
            _store_metadata({"ok": True, "name": found["name"], "version": found["version"], "removed": True, "alsoRemoved": companions})
            return json.dumps(
                {"ok": True, "name": found["name"], "version": found["version"], "alsoRemoved": companions},
                ensure_ascii=False,
            )
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
