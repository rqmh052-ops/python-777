"""Fail the build when R8 removed what Python calls on the Kotlin side.

Python (Chaquopy) calls RunCallback / PackageCallback methods by *name*.
If R8 renames the classes (RunCallback -> y0) or deletes the methods, every run
and every library install fails at runtime with
"'y0' object has no attribute 'emitState'". The names live in the APK's
classes*.dex string tables, so we can check for them right after the build.

Usage: python tools/verify_apk.py build/app/outputs/flutter-apk/app-release.apk
"""
from __future__ import annotations

import sys
import zipfile
from pathlib import Path

REQUIRED = [
    "emitState",
    "emitPackage",
    "emitOutput",
    "emitInput",
    "emitExit",
    "emitError",
    "emitMissing",
    "requestInput",
    "shouldStop",
    "BayanPythonBridge$RunCallback",
    "BayanPythonBridge$PackageCallback",
    # البناء 2ب: الخدمة الأمامية وقناة النظام (المانيفست يشير إلى الخدمة بالاسم)
    "BayanScriptService",
    "BayanSystem",
]


def missing_names(apk: Path) -> list[str]:
    blobs: list[bytes] = []
    with zipfile.ZipFile(apk) as zf:
        for name in zf.namelist():
            if name.startswith("classes") and name.endswith(".dex"):
                blobs.append(zf.read(name))
    if not blobs:
        return list(REQUIRED)
    data = b"\0".join(blobs)
    return [name for name in REQUIRED if name.encode("utf-8") not in data]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_apk.py <app-release.apk>")
        return 2
    apk = Path(sys.argv[1])
    if not apk.is_file():
        print(f"APK not found: {apk}")
        return 2
    missing = missing_names(apk)
    if missing:
        print("FAIL: these names are missing from the APK (R8 removed or renamed them):")
        for name in missing:
            print(f"  - {name}")
        print("The app would show: AttributeError: 'y0' object has no attribute 'emitState'.")
        print("Check that the build uses --no-shrink and that android/app/proguard-rules.pro exists.")
        return 1
    print(f"OK: all {len(REQUIRED)} Kotlin callback names survived in {apk.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
