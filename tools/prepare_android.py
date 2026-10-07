from __future__ import annotations

import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / "android"

AGP = "9.2.0"
KOTLIN = "2.2.10"
GRADLE = "9.4.1"
CHAQUOPY = "17.0.0"
PYTHON = "3.13"
ABIS = ["arm64-v8a"]


def patch_plugin_version(text: str, plugin: str, version: str) -> str:
    patterns = [
        rf'(id\("{re.escape(plugin)}"\)\s+version\s+")([^"]+)("\s+apply\s+false)',
        rf"(id\s+[\"']{re.escape(plugin)}[\"']\s+version\s+[\"'])([^\"']+)([\"']\s+apply\s+false)",
    ]
    for pattern in patterns:
        new, count = re.subn(pattern, rf"\g<1>{version}\g<3>", text, count=1)
        if count:
            return new
    return text


def add_to_plugins(text: str, line: str) -> str:
    if "com.chaquo.python" in text:
        return text
    m = re.search(r"plugins\s*\{(?P<body>[\s\S]*?)\n\}", text)
    if not m:
        raise RuntimeError("تعذر العثور على plugins block في settings.gradle")
    body = m.group("body")
    indent = "    "
    return text[: m.end(1)] + f"\n{indent}{line}" + text[m.end(1) :]


def patch_settings() -> None:
    path = ANDROID / "settings.gradle.kts"
    kts = path.exists()
    if not kts:
        path = ANDROID / "settings.gradle"
    if not path.exists():
        raise RuntimeError("Flutter لم ينشئ settings.gradle(.kts)")

    text = path.read_text(encoding="utf-8")
    text = patch_plugin_version(text, "com.android.application", AGP)
    text = patch_plugin_version(text, "org.jetbrains.kotlin.android", KOTLIN)
    text = patch_plugin_version(text, "kotlin-android", KOTLIN)
    chaq_line = (
        'id("com.chaquo.python") version "' + CHAQUOPY + '" apply false'
        if kts
        else "id 'com.chaquo.python' version '" + CHAQUOPY + "' apply false"
    )
    text = add_to_plugins(text, chaq_line)
    path.write_text(text, encoding="utf-8")


def patch_app_build() -> None:
    path = ANDROID / "app" / "build.gradle.kts"
    kts = path.exists()
    if not kts:
        path = ANDROID / "app" / "build.gradle"
    if not path.exists():
        raise RuntimeError("Flutter لم ينشئ app/build.gradle(.kts)")

    text = path.read_text(encoding="utf-8")
    text = re.sub(r'(?m)^(\s*)id\("kotlin-android"\)', r'\1id("org.jetbrains.kotlin.android")', text)
    text = re.sub(r"(?m)^(\s*)id [\"']kotlin-android[\"']", r"\1id 'org.jetbrains.kotlin.android'", text)

    if "com.chaquo.python" not in text:
        m = re.search(r"plugins\s*\{(?P<body>[\s\S]*?)\n\}", text)
        if not m:
            raise RuntimeError("تعذر العثور على plugins block في app build file")
        line = '    id("com.chaquo.python")' if kts else "    id 'com.chaquo.python'"
        text = text[: m.end(1)] + "\n" + line + text[m.end(1) :]

    if kts:
        text = re.sub(r"minSdk\s*=\s*[^\n]+", "minSdk = 24", text, count=1)
        text = re.sub(r"minSdkVersion\s+[^\n]+", "minSdkVersion 24", text, count=1)
        ndk_block = 'ndk {\n            abiFilters += listOf("arm64-v8a")\n        }'
        if 'abiFilters += listOf("arm64-v8a")' not in text:
            m = re.search(r"(defaultConfig\s*\{)([\s\S]*?)(\n\s*\})", text)
            if not m:
                raise RuntimeError("تعذر العثور على defaultConfig في app build file")
            body = m.group(2)
            insertion = "\n        " + ndk_block
            text = text[: m.end(2)] + insertion + text[m.end(2) :]
        chaq = '''\n\nchaquopy {\n    defaultConfig {\n        version = "3.13"\n        buildPython("python")\n    }\n}'''
    else:
        text = re.sub(r"minSdkVersion\s+[^\n]+", "minSdkVersion 24", text, count=1)
        text = re.sub(r"minSdk\s*=\s*[^\n]+", "minSdk 24", text, count=1)
        ndk_block = 'ndk {\n            abiFilters "arm64-v8a"\n        }'
        if 'abiFilters "arm64-v8a"' not in text:
            m = re.search(r"(defaultConfig\s*\{)([\s\S]*?)(\n\s*\})", text)
            if not m:
                raise RuntimeError("تعذر العثور على defaultConfig في app build file")
            text = text[: m.end(2)] + "\n        " + ndk_block + text[m.end(2) :]
        chaq = '''\n\nchaquopy {\n    defaultConfig {\n        version "3.13"\n        buildPython "python"\n    }\n}'''

    if "chaquopy {" not in text:
        dependency = re.search(r"\n\s*dependencies\s*\{", text)
        if dependency:
            text = text[: dependency.start()] + chaq + text[dependency.start() :]
        else:
            text += chaq + "\n"

    path.write_text(text, encoding="utf-8")


def patch_wrapper() -> None:
    path = ANDROID / "gradle" / "wrapper" / "gradle-wrapper.properties"
    if not path.exists():
        raise RuntimeError("Flutter لم ينشئ Gradle wrapper")
    text = path.read_text(encoding="utf-8")
    text = re.sub(
        r"distributionUrl=.*",
        f"distributionUrl=https\\://services.gradle.org/distributions/gradle-{GRADLE}-all.zip",
        text,
        count=1,
    )
    path.write_text(text, encoding="utf-8")


def patch_manifest() -> None:
    path = ANDROID / "app" / "src" / "main" / "AndroidManifest.xml"
    if not path.exists():
        raise RuntimeError("AndroidManifest.xml مفقود")
    text = path.read_text(encoding="utf-8")
    text = re.sub(r'android:label="[^"]*"', 'android:label="مشغّل بايثون"', text, count=1)
    application = re.search(r"<application\b", text)
    if not application:
        raise RuntimeError("application tag مفقود")

    permissions = [
        '<uses-permission android:name="android.permission.INTERNET"/>',
        '<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>',
        '<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29"/>',
        '<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>',
    ]
    missing = [p for p in permissions if p not in text]
    if missing:
        insert = "\n    " + "\n    ".join(missing) + "\n"
        text = text[: application.start()] + insert + text[application.start() :]

    if "android:requestLegacyExternalStorage=" not in text:
        text = text.replace("<application", '<application android:requestLegacyExternalStorage="true"', 1)
    path.write_text(text, encoding="utf-8")


def install_native_sources() -> None:
    kotlin_root = ANDROID / "app" / "src" / "main" / "kotlin"
    kotlin_root.mkdir(parents=True, exist_ok=True)
    for old in kotlin_root.rglob("MainActivity.kt"):
        old.unlink()
    target = kotlin_root / "dev" / "pyrunner" / "py_runner" / "MainActivity.kt"
    target.parent.mkdir(parents=True, exist_ok=True)
    source = ROOT / "MainActivity.kt"
    if not source.exists():
        raise RuntimeError("MainActivity.kt غير موجود في جذر المشروع")
    shutil.copy2(source, target)

    py_root = ANDROID / "app" / "src" / "main" / "python"
    py_root.mkdir(parents=True, exist_ok=True)
    source_py = ROOT / "bayan_runtime.py"
    if not source_py.exists():
        raise RuntimeError("bayan_runtime.py غير موجود")
    shutil.copy2(source_py, py_root / "bayan_runtime.py")


def main() -> None:
    if not ANDROID.exists():
        raise SystemExit("android directory is missing; run flutter create first")
    patch_settings()
    patch_app_build()
    patch_wrapper()
    patch_manifest()
    install_native_sources()
    print("Bayan Android/Chaquopy configuration prepared successfully")
    print(f"Chaquopy={CHAQUOPY}, Python={PYTHON}, AGP={AGP}, Gradle={GRADLE}, ABI={ABIS}")


if __name__ == "__main__":
    main()
