from __future__ import annotations

import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / "android"

# لا نفرض إصدارات AGP أو Gradle: نترك ما يولّده flutter create للإصدار المثبّت
# من Flutter (هذا ما كان يسبب الأعطال). Chaquopy 17.0 يدعم AGP من 7.3 إلى 9.2.
MIN_KOTLIN = "2.2.20"  # أقل إصدار Kotlin يقبله Flutter
CHAQUOPY = "17.0.0"
PYTHON = "3.13"
ABIS = ["arm64-v8a"]
COMPILE_SDK = 37  # permission_handler_android يتطلب 37
APP_PACKAGE = "com.bynux.app"


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


def _vt(v: str) -> tuple:
    return tuple(int(x) for x in re.findall(r"\d+", v)[:3])


def ensure_min_kotlin(text: str) -> str:
    """يرفع إصدار Kotlin في settings إذا كان أقل من الحد الأدنى، ولا ينزّله أبدًا."""
    pattern = r'(id\s*\(?\s*["\']org\.jetbrains\.kotlin\.android["\']\s*\)?\s+version\s+["\'])([^"\']+)(["\'])'

    def fix(m: re.Match) -> str:
        current = m.group(2)
        if _vt(current) >= _vt(MIN_KOTLIN):
            return m.group(0)
        return m.group(1) + MIN_KOTLIN + m.group(3)

    return re.sub(pattern, fix, text, count=1)


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
    text = ensure_min_kotlin(text)
    if "org.jetbrains.kotlin.android" not in text and "kotlin-android" not in text:
        # Kotlin مضمّن في AGP 9 بإصدار قد يكون أقل من حد Flutter؛ التصريح بالإضافة
        # (بدون تطبيقها) هو الطريقة الرسمية لرفع إصدار Kotlin المضمّن.
        kotlin_line = (
            f'id("org.jetbrains.kotlin.android") version "{MIN_KOTLIN}" apply false'
            if kts
            else f"id 'org.jetbrains.kotlin.android' version '{MIN_KOTLIN}' apply false"
        )
        text = add_to_plugins(text, kotlin_line)
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
    if kts:
        text = re.sub(r'namespace\s*=\s*"[^"]+"', f'namespace = "{APP_PACKAGE}"', text, count=1)
        text = re.sub(r'applicationId\s*=\s*"[^"]+"', f'applicationId = "{APP_PACKAGE}"', text, count=1)
    else:
        text = re.sub(r"namespace\s*[= ]\s*[\"'][^\"']+[\"']", f'namespace "{APP_PACKAGE}"', text, count=1)
        text = re.sub(r"applicationId\s*(?:=\s*)?[\"'][^\"']+[\"']", f'applicationId "{APP_PACKAGE}"', text, count=1)
    if "com.chaquo.python" not in text:
        m = re.search(r"plugins\s*\{(?P<body>[\s\S]*?)\n\}", text)
        if not m:
            raise RuntimeError("تعذر العثور على plugins block في app build file")
        line = '    id("com.chaquo.python")' if kts else "    id 'com.chaquo.python'"
        text = text[: m.end(1)] + "\n" + line + text[m.end(1) :]

    # بعض الإضافات (permission_handler_android) تتطلب compileSdk 37 بينما Flutter يولّد 36.
    text = re.sub(r"compileSdk\s*=\s*[^\n]+", f"compileSdk = {COMPILE_SDK}", text, count=1)
    text = re.sub(r"compileSdkVersion\s+[^\n]+", f"compileSdkVersion {COMPILE_SDK}", text, count=1)

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

    # Flutter يضيف ABIs إضافية (مثل armeabi-v7a) لنسخة debug، وChaquopy مع Python 3.13
    # يدعم arm64-v8a و x86_64 فقط، فيفشل التهيئة حتى لو بنينا release فقط.
    # finalizeDsl آخر نقطة قبل قفل الإعدادات، فنفرض الـ ABI على كل الـ buildTypes.
    if "finalizeDsl" not in text:
        if kts:
            text += """
androidComponents {
    finalizeDsl { dsl ->
        dsl.defaultConfig.ndk {
            println("BAYAN-ABI before defaultConfig: $abiFilters")
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
        dsl.buildTypes.configureEach {
            val typeName = name
            ndk {
                println("BAYAN-ABI before $typeName: $abiFilters")
                abiFilters.clear()
                abiFilters.add("arm64-v8a")
                println("BAYAN-ABI after $typeName: $abiFilters")
            }
        }
    }
}
"""
        else:
            text += """
androidComponents {
    finalizeDsl { dsl ->
        dsl.defaultConfig.ndk {
            abiFilters.clear()
            abiFilters.add('arm64-v8a')
        }
        dsl.buildTypes.configureEach {
            ndk {
                abiFilters.clear()
                abiFilters.add('arm64-v8a')
            }
        }
    }
}
"""

    # مفتاح توقيع ثابت اختياري من GitHub Secrets. عند غياب الأسرار يستمر البناء
    # بمفتاح Flutter الافتراضي، لكن تسجيل جوجل لن يكون ثابتاً بين البناءات.
    if "bynuxRelease" not in text:
        if kts:
            text += """

android {
    signingConfigs {
        create("bynuxRelease") {
            val keyPath = System.getenv("BYNUX_KEYSTORE_PATH")
            if (!keyPath.isNullOrBlank()) {
                storeFile = file(keyPath)
                storePassword = System.getenv("BYNUX_KEYSTORE_PASSWORD")
                keyAlias = "bynux"
                keyPassword = System.getenv("BYNUX_KEYSTORE_PASSWORD")
            }
        }
    }
    buildTypes {
        getByName("release") {
            val keyPath = System.getenv("BYNUX_KEYSTORE_PATH")
            if (!keyPath.isNullOrBlank()) {
                signingConfig = signingConfigs.getByName("bynuxRelease")
            }
        }
    }
}
"""
        else:
            text += """

android {
    signingConfigs {
        bynuxRelease {
            def keyPath = System.getenv("BYNUX_KEYSTORE_PATH")
            if (keyPath != null && !keyPath.trim().isEmpty()) {
                storeFile file(keyPath)
                storePassword System.getenv("BYNUX_KEYSTORE_PASSWORD")
                keyAlias "bynux"
                keyPassword System.getenv("BYNUX_KEYSTORE_PASSWORD")
            }
        }
    }
    buildTypes {
        release {
            def keyPath = System.getenv("BYNUX_KEYSTORE_PATH")
            if (keyPath != null && !keyPath.trim().isEmpty()) {
                signingConfig signingConfigs.bynuxRelease
            }
        }
    }
}
"""
    path.write_text(text, encoding="utf-8")


def write_proguard_rules(app_dir: Path) -> None:
    """قواعد keep لكلاسات Kotlin التي يستدعيها بايثون بالاسم (reflection).

    R8 لا يرى إلا استدعاءات Kotlin، فيحذف emitState/emitPackage... ويعيد تسمية
    RunCallback إلى y0. Flutter يضيف android/app/proguard-rules.pro تلقائيًا إلى
    بناء release عندما يكون R8 فعّالًا، وهذه شبكة أمان فوق --no-shrink.
    """
    rules = f"""# Generated by tools/prepare_android.py - do not edit by hand.
# Python (Chaquopy) calls these Kotlin classes by NAME through reflection.
# R8 only sees Kotlin callers, so without these rules it deletes the methods and
# renames the classes ("'y0' object has no attribute 'emitState'").
-keep class {APP_PACKAGE}.BayanPythonBridge {{ *; }}
-keep class {APP_PACKAGE}.BayanPythonBridge$* {{ *; }}
-keep class {APP_PACKAGE}.BayanScriptService {{ *; }}
-keep class {APP_PACKAGE}.BayanSystem {{ *; }}
-keep class {APP_PACKAGE}.EventRing {{ *; }}
-keep class {APP_PACKAGE}.LogStore {{ *; }}
-keep class {APP_PACKAGE}.LogStore$* {{ *; }}
-keepattributes InnerClasses,EnclosingMethod,Signature,*Annotation*
-keep class com.chaquo.python.** {{ *; }}
-dontwarn com.chaquo.python.**
-dontwarn org.jetbrains.annotations.**
"""
    app_dir.mkdir(parents=True, exist_ok=True)
    (app_dir / "proguard-rules.pro").write_text(rules, encoding="utf-8")


def patch_gradle_properties() -> None:
    """AGP 9.1 يوصي بحد أقصى compileSdk 36؛ هذا يكتم التحذير ويسمح بـ 37."""
    path = ANDROID / "gradle.properties"
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    key = "android.suppressUnsupportedCompileSdk"
    if key not in text:
        if text and not text.endswith("\n"):
            text += "\n"
        text += f"{key}={COMPILE_SDK}\n"
        path.write_text(text, encoding="utf-8")


def report_versions() -> None:
    """يطبع الإصدارات الفعلية التي ولّدها Flutter (للتشخيص في سجل البناء)."""
    for name in ("settings.gradle.kts", "settings.gradle"):
        f = ANDROID / name
        if f.exists():
            t = f.read_text(encoding="utf-8")
            for plugin in ("com.android.application", "org.jetbrains.kotlin.android"):
                m = re.search(re.escape(plugin) + r"[\"')\s]+version\s+[\"']([^\"']+)", t)
                print(f"  {plugin}: {m.group(1) if m else 'غير مُعرَّف (مضمّن في AGP)'}")
    w = ANDROID / "gradle" / "wrapper" / "gradle-wrapper.properties"
    if w.exists():
        m = re.search(r"gradle-([\d.]+)-", w.read_text(encoding="utf-8"))
        print(f"  gradle: {m.group(1) if m else '?'}")


# العمل في الخلفية (البناء 2ب). كلها أذونات عادية تُمنح تلقائيًا عدا POST_NOTIFICATIONS (أندرويد 13+)
# التي تُطلب من المستخدم في شاشة الترحيب.
BACKGROUND_PERMISSIONS = [
    '<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>',
    '<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE"/>',
    '<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>',
    '<uses-permission android:name="android.permission.WAKE_LOCK"/>',
    '<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>',
]

SERVICE_NAME = "BayanScriptService"
SPECIAL_USE_SUBTYPE = (
    "Keeps Python scripts that the user started manually (for example Telegram bots) "
    "running in the background until the user stops them"
)


def service_block() -> str:
    # الاسم كاملًا (لا ".BayanScriptService") حتى لا يعتمد على namespace الذي يولّده flutter create
    return f"""
        <service
            android:name="{APP_PACKAGE}.{SERVICE_NAME}"
            android:exported="false"
            android:foregroundServiceType="specialUse">
            <property
                android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
                android:value="{SPECIAL_USE_SUBTYPE}" />
        </service>
"""


def add_script_service(text: str) -> str:
    """يضيف تعريف الخدمة الأمامية (specialUse) داخل <application>. آمن عند التكرار."""
    if SERVICE_NAME in text:
        return text
    end = text.rfind("</application>")
    if end < 0:
        raise RuntimeError("</application> مفقود في AndroidManifest.xml")
    return text[:end] + service_block() + "    " + text[end:]


NOTIFICATION_ICON = """<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:pathData="M5,7 L11,12 L5,17 M13,17 L19,17"
        android:strokeColor="#FFFFFFFF"
        android:strokeWidth="2.4"
        android:strokeLineCap="round"
        android:strokeLineJoin="round" />
</vector>
"""


def write_notification_icon(app_dir: Path | None = None) -> Path:
    """أيقونة إشعار الخدمة (أبيض على شفاف كما يشترط شريط الحالة). يقرؤها الكود بالاسم ic_bayan_notify."""
    base = app_dir if app_dir is not None else ANDROID / "app"
    target = base / "src" / "main" / "res" / "drawable" / "ic_bayan_notify.xml"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(NOTIFICATION_ICON, encoding="utf-8")
    return target


def patch_manifest() -> None:
    path = ANDROID / "app" / "src" / "main" / "AndroidManifest.xml"
    if not path.exists():
        raise RuntimeError("AndroidManifest.xml مفقود")
    text = path.read_text(encoding="utf-8")
    text = re.sub(r'android:label="[^"]*"', 'android:label="Bynux"', text, count=1)
    application = re.search(r"<application\b", text)
    if not application:
        raise RuntimeError("application tag مفقود")

    permissions = [
        '<uses-permission android:name="android.permission.INTERNET"/>',
        '<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>',
        '<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29"/>',
        '<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>',
    ] + BACKGROUND_PERMISSIONS
    missing = [p for p in permissions if p not in text]
    if missing:
        insert = "\n    " + "\n    ".join(missing) + "\n"
        text = text[: application.start()] + insert + text[application.start() :]

    if "android:requestLegacyExternalStorage=" not in text:
        text = text.replace("<application", '<application android:requestLegacyExternalStorage="true"', 1)
    text = add_script_service(text)
    path.write_text(text, encoding="utf-8")


def install_native_sources() -> None:
    kotlin_root = ANDROID / "app" / "src" / "main" / "kotlin"
    kotlin_root.mkdir(parents=True, exist_ok=True)
    for old in kotlin_root.rglob("MainActivity.kt"):
        old.unlink()
    target = kotlin_root / "com" / "bynux" / "app" / "MainActivity.kt"
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


def print_final_app_build() -> None:
    """يطبع ملف app/build.gradle النهائي في سجل البناء (للتأكد من ABI)."""
    for name in ("build.gradle.kts", "build.gradle"):
        f = ANDROID / "app" / name
        if f.exists():
            print(f"----- final android/app/{name} -----")
            print(f.read_text(encoding="utf-8"))
            print("----- end -----")


def main() -> None:
    if not ANDROID.exists():
        raise SystemExit("android directory is missing; run flutter create first")
    patch_settings()
    patch_app_build()
    write_proguard_rules(ANDROID / "app")
    patch_gradle_properties()
    print_final_app_build()
    report_versions()
    patch_manifest()
    write_notification_icon()
    install_native_sources()
    print("Bayan Android/Chaquopy configuration prepared successfully")
    print(f"Chaquopy={CHAQUOPY}, Python={PYTHON}, ABI={ABIS}")


if __name__ == "__main__":
    main()
