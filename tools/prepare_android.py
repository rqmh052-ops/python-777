from __future__ import annotations

import os
import re
import secrets
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
#
# Verified against MainActivity.kt (current source): the only Kotlin objects that
# cross into Python are RunCallback and PackageCallback, and both are *inner classes*
# of BayanPythonBridge (MainActivity.kt: "inner class RunCallback" /
# "inner class PackageCallback" inside BayanPythonBridge), so they are already covered
# by the BayanPythonBridge$* rule below. If a future Kotlin change adds a new class
# instance passed into module.callAttr(...), add an explicit -keep line for it here.
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

# Safe to combine with the keep rules above: renamed/repackaged classes elsewhere in
# the app still get obfuscated (the point of enabling R8), these only make the mapping
# a bit smaller and allow R8 to merge access modifiers for better shrinking.
-repackageclasses ""
-allowaccessmodification
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

QUERIES_BLOCK = """    <queries>
        <intent>
            <action android:name="android.intent.action.SENDTO" />
            <data android:scheme="mailto" />
        </intent>
        <intent>
            <action android:name="android.intent.action.VIEW" />
            <data android:scheme="mailto" />
        </intent>
        <intent>
            <action android:name="android.intent.action.VIEW" />
            <data android:scheme="https" />
        </intent>
        <package android:name="com.whatsapp" />
        <package android:name="com.whatsapp.w4b" />
    </queries>
"""


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


def add_queries_block(text: str) -> str:
    """يضيف <queries> لروابط البريد (mailto) وواتساب (https) على أندرويد 11+. آمن عند التكرار."""
    if "android:scheme=\"mailto\"" in text:
        return text
    if "<queries>" in text:
        idx = text.find("</queries>")
        if idx >= 0:
            extra = (
                '        <intent>\n'
                '            <action android:name="android.intent.action.SENDTO" />\n'
                '            <data android:scheme="mailto" />\n'
                '        </intent>\n'
                '        <intent>\n'
                '            <action android:name="android.intent.action.VIEW" />\n'
                '            <data android:scheme="https" />\n'
                '        </intent>\n'
                '        <package android:name="com.whatsapp" />\n'
                '        <package android:name="com.whatsapp.w4b" />\n'
            )
            return text[:idx] + extra + "    " + text[idx:]
    app_match = re.search(r"<application\b", text)
    if not app_match:
        return text
    return text[: app_match.start()] + QUERIES_BLOCK + text[app_match.start() :]


def patch_main_activity_pip(text: str) -> str:
    """يفعّل Picture-in-Picture الرسمي ويمنع إعادة إنشاء MainActivity عند تصغير/تكبير النافذة."""
    m = re.search(r"<activity\b[^>]*android:name=\"[^\"]*MainActivity\"[^>]*>", text)
    if not m:
        return text
    tag = m.group(0)
    updated = tag
    if 'android:supportsPictureInPicture=' not in updated:
        if updated.endswith("/>"):
            updated = updated[:-2] + ' android:supportsPictureInPicture="true" />'
        else:
            updated = updated[:-1] + ' android:supportsPictureInPicture="true">'
    if 'android:configChanges=' not in updated:
        cfg = (
            'android:configChanges="orientation|keyboardHidden|keyboard|screenSize|'
            'smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"'
        )
        if updated.endswith("/>"):
            updated = updated[:-2] + f" {cfg} />"
        else:
            updated = updated[:-1] + f" {cfg}>"
    return text[: m.start()] + updated + text[m.end() :]


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

    text = add_queries_block(text)

    if "android:requestLegacyExternalStorage=" not in text:
        text = text.replace("<application", '<application android:requestLegacyExternalStorage="true"', 1)

    # تعطيل النسخ الاحتياطي التلقائي لأندرويد كي لا يستعيد حالة الموافقة في SharedPreferences بعد حذف التطبيق وتثبيته.
    if "android:allowBackup=" in text:
        text = re.sub(r'android:allowBackup="[^"]*"', 'android:allowBackup="false"', text, count=1)
    else:
        text = text.replace("<application", '<application android:allowBackup="false"', 1)
    if "android:fullBackupContent=" in text:
        text = re.sub(r'android:fullBackupContent="[^"]*"', 'android:fullBackupContent="false"', text, count=1)
    else:
        text = text.replace("<application", '<application android:fullBackupContent="false"', 1)

    text = patch_main_activity_pip(text)
    text = add_script_service(text)
    path.write_text(text, encoding="utf-8")


# أيقونة التطبيق: ضع صورة باسم icon.png في جذر المشروع فقط، والبناء يولّد كل المقاسات.
# إن كانت الصورة بخلفية بيضاء أو مربعات (شفافية مزيفة) تُزال الخلفية تلقائيًا.
ICON_SOURCE = ROOT / "icon.png"
LEGACY_ICON_SIZES = (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192))
ADAPTIVE_CANVAS = 432  # 108dp عند xxxhdpi
ADAPTIVE_TILE = 288  # 72dp = النافذة المرئية للأيقونة التكيفية
ADAPTIVE_SAFE_RADIUS = 33 * 4  # دائرة المنطقة الآمنة 66dp: لا يقصّها أي قناع من أي شركة مصنّعة


def _remove_backdrop(rgb):
    """يحوّل صورة RGB ذات خلفية بيضاء/رمادية فاتحة إلى RGBA بخلفية شفافة.

    الخلفية = بكسلات فاتحة شبه محايدة متصلة بحافة الصورة (تشمل المربعات والهالة البيضاء).
    الكتابة البيضاء داخل الأيقونة محاطة باللون الأزرق فلا يصلها الملء الفيضي.
    """
    import numpy as np
    from scipy import ndimage as ndi

    a = rgb.astype(np.int16)
    mn, mx = a.min(axis=2), a.max(axis=2)
    candidate = (mn >= 200) & ((mx - mn) <= 24)
    labels, _ = ndi.label(candidate)
    edge = np.unique(np.concatenate([labels[0], labels[-1], labels[:, 0], labels[:, -1]]))
    edge = edge[edge != 0]
    solid = ~np.isin(labels, edge)
    lab2, n2 = ndi.label(solid)
    if n2 > 1:
        sizes = ndi.sum(solid, lab2, range(1, n2 + 1))
        solid = lab2 == (1 + int(np.argmax(sizes)))
    solid = ndi.binary_fill_holes(solid)
    core = ndi.binary_erosion(solid, iterations=2)
    _, (iy, ix) = ndi.distance_transform_edt(~core, return_indices=True)
    colour = np.where(core[..., None], a, a[iy, ix])  # لا هالة بيضاء على الحافة
    alpha = ndi.gaussian_filter(solid.astype(np.float32), 0.9)
    alpha = np.clip((alpha - 0.5) * 2.0 + 0.5, 0, 1)
    alpha = np.where(core, 1.0, alpha) * ndi.binary_dilation(solid, iterations=1)
    return np.dstack([colour.astype(np.uint8), (alpha * 255).round().astype(np.uint8)])


def prepare_icon_master(source: Path):
    """يقرأ الصورة، يزيل الخلفية إن لزم، يقصّها على حدود الأيقونة ويجعلها مربعة (RGBA)."""
    import numpy as np
    from PIL import Image

    img = Image.open(source).convert("RGBA")
    arr = np.array(img)
    corners = [arr[0, 0, 3], arr[0, -1, 3], arr[-1, 0, 3], arr[-1, -1, 3]]
    if min(int(c) for c in corners) >= 250:  # لا شفافية في الزوايا: خلفية مرسومة
        arr = _remove_backdrop(arr[..., :3])
        img = Image.fromarray(arr)
    ys, xs = np.where(np.array(img)[..., 3] > 5)
    if len(xs) == 0:
        raise RuntimeError("icon.png: لم يبقَ أي محتوى بعد إزالة الخلفية")
    img = img.crop((int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1))
    side = max(img.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(img, ((side - img.width) // 2, (side - img.height) // 2))
    return square


def _adaptive_background(master) -> str:
    """لون خلفية الأيقونة التكيفية: متوسط حلقة داخل حافة الأيقونة مباشرة."""
    import numpy as np
    from scipy import ndimage as ndi

    arr = np.array(master)
    side = arr.shape[0]
    solid = arr[..., 3] > 250
    ring = ndi.binary_erosion(solid, iterations=max(1, int(side * 0.055))) ^ ndi.binary_erosion(
        solid, iterations=max(2, int(side * 0.09))
    )
    if not ring.any():
        return "#0B2561"
    r, g, b = arr[ring][:, :3].mean(axis=0).round().astype(int)
    return "#%02X%02X%02X" % (r, g, b)


def _glyph_alpha(master):
    """يستخرج الكتابة البيضاء (بدون الإطار والخلفية) كقناع شفافية 0..1، أو None إن لم يوجد محتوى كافٍ."""
    import numpy as np
    from scipy import ndimage as ndi

    arr = np.array(master).astype(np.float32)
    white = arr[..., :3].min(axis=2)
    alpha = np.clip((white - 130.0) / 70.0, 0.0, 1.0) * (arr[..., 3] / 255.0)
    solid = alpha > 0.5
    lab, n = ndi.label(solid)
    if n == 0:
        return None
    sizes = ndi.sum(solid, lab, range(1, n + 1))
    keep_ids = [i + 1 for i, size in enumerate(sizes) if size >= 0.0001 * solid.size]
    if not keep_ids:
        return None
    keep = ndi.binary_dilation(np.isin(lab, keep_ids), iterations=3)
    alpha = alpha * keep
    if (alpha > 0.5).mean() < 0.01:
        return None
    return alpha


def _enclosing_circle(alpha):
    """أصغر دائرة (تقريبًا) تحيط بكل بكسلات الكتابة: (مركز x, مركز y), نصف القطر."""
    import numpy as np

    ys, xs = np.nonzero(alpha > 0.5)
    pts = np.column_stack([xs, ys]).astype(np.float64)
    try:
        from scipy.spatial import ConvexHull

        pts = pts[ConvexHull(pts).vertices]
    except Exception:
        pass
    centre = pts.mean(axis=0)
    for i in range(1, 2001):
        far = pts[int(np.linalg.norm(pts - centre, axis=1).argmax())]
        centre = centre + (far - centre) / (i + 1)
    return centre, float(np.linalg.norm(pts - centre, axis=1).max())


def _adaptive_background_layer(master, glyph):
    """طبقة خلفية ممتلئة بالكامل (بدون شفافية) بتدرج لوني رأسي مأخوذ من ألوان الأيقونة نفسها."""
    import numpy as np
    from PIL import Image
    from scipy import ndimage as ndi

    arr = np.array(master).astype(np.float32)
    side = arr.shape[0]
    solid = arr[..., 3] > 250
    inter = ndi.binary_erosion(solid, iterations=max(2, int(side * 0.09)))
    if glyph is not None:
        inter &= ~ndi.binary_dilation(glyph > 0.05, iterations=max(3, int(side * 0.014)))
    stops: list[tuple[float, np.ndarray]] = []
    bands = 10
    for i in range(bands):
        y0, y1 = int(i * side / bands), int((i + 1) * side / bands)
        m = inter[y0:y1]
        if m.sum() >= 0.01 * side * side / bands * 10:
            stops.append(((i + 0.5) / bands, arr[y0:y1, :, :3][m].mean(axis=0)))
    if len(stops) < 3:
        r, g, b = (int(v) for v in ImageColor_getrgb(_adaptive_background(master)))
        return Image.new("RGBA", (ADAPTIVE_CANVAS, ADAPTIVE_CANVAS), (r, g, b, 255))
    ts = np.array([t for t, _ in stops])
    cols = np.array([c for _, c in stops])
    # النافذة المرئية للأيقونة هي 72dp من 108dp (من 1/6 إلى 5/6 من اللوحة)
    rows = (np.arange(ADAPTIVE_CANVAS) / (ADAPTIVE_CANVAS - 1) - 1 / 6) / (4 / 6)
    ramp = np.stack([np.interp(rows, ts, cols[:, ch]) for ch in range(3)], axis=1)
    ramp = ndi.gaussian_filter1d(ramp, 6, axis=0, mode="nearest")
    img = np.repeat(ramp[:, None, :], ADAPTIVE_CANVAS, axis=1)
    img = np.dstack([img.round().clip(0, 255).astype(np.uint8), np.full((ADAPTIVE_CANVAS, ADAPTIVE_CANVAS), 255, np.uint8)])
    return Image.fromarray(img, "RGBA")


def ImageColor_getrgb(value: str):
    from PIL import ImageColor

    return ImageColor.getrgb(value)


def build_adaptive_layers(master):
    """يبني طبقات الأيقونة التكيفية (432×432): (أمامية, أحادية اللون, خلفية).

    الأمامية: الكتابة وحدها بدون إطار الأيقونة، داخل دائرة المنطقة الآمنة (66dp)، فلا يقصّها أي قناع.
    الخلفية: ممتلئة بالكامل بلا شفافية ولا شكل مرسوم، والقناع يضعه الجهاز حسب شركته.
    الأحادية: نفس الكتابة بقناع شفافيتها فقط، لأيقونات أندرويد 13+ المتناغمة مع الخلفية.
    إن تعذّر استخراج الكتابة (أيقونة بلا كتابة بيضاء) تُستعمل الصورة كاملة كما في الطريقة القديمة.
    """
    import numpy as np
    from PIL import Image

    canvas = ADAPTIVE_CANVAS
    glyph = _glyph_alpha(master)
    fg = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    if glyph is None:
        tile = master.resize((ADAPTIVE_TILE, ADAPTIVE_TILE), Image.LANCZOS)
        fg.paste(tile, ((canvas - ADAPTIVE_TILE) // 2, (canvas - ADAPTIVE_TILE) // 2))
    else:
        centre, radius = _enclosing_circle(glyph)
        scale = (ADAPTIVE_SAFE_RADIUS * 0.97) / radius
        rgb = np.array(master)[..., :3]
        layer = Image.fromarray(np.dstack([rgb, (glyph * 255).round().astype(np.uint8)]), "RGBA")
        size = max(1, int(round(layer.width * scale)))
        layer = layer.resize((size, size), Image.LANCZOS)
        ox = int(round(canvas / 2 - centre[0] * scale))
        oy = int(round(canvas / 2 - centre[1] * scale))
        fg.paste(layer, (ox, oy))
    mono = Image.new("RGBA", (canvas, canvas), (255, 255, 255, 0))
    mono.putalpha(fg.getchannel("A"))
    bg = _adaptive_background_layer(master, glyph)
    return fg, mono, bg


def install_launcher_icons(res_dir: Path | None = None, source: Path | None = None) -> list[str]:
    """يولّد أيقونة التطبيق من icon.png داخل مشروع أندرويد المولَّد (بدون أي ملفات جاهزة).

    flutter create يضع أيقونة Flutter الافتراضية؛ نحذف أي ic_launcher* قديمة أولًا حتى لا يحدث
    تعارض موارد (مثل ic_launcher.webp بجانب ic_launcher.png)، ثم نكتب: mipmap-*/ic_launcher.png
    للأجهزة القديمة + أيقونة adaptive (mipmap-anydpi-v26) بزوايا شفافة وبلا أي خلفية بيضاء.
    """
    from PIL import Image

    src = source if source is not None else ICON_SOURCE
    if not src.is_file():
        raise RuntimeError(f"{src.name} غير موجود في جذر المشروع: أيقونة التطبيق مفقودة")
    target = res_dir if res_dir is not None else ANDROID / "app" / "src" / "main" / "res"
    target.mkdir(parents=True, exist_ok=True)
    for old in list(target.glob("mipmap-*/ic_launcher*")) + list(target.glob("drawable*/ic_launcher*")):
        if old.is_file():
            old.unlink()
    for old in target.glob("values*/ic_launcher_background*"):
        if old.is_file():
            old.unlink()

    master = prepare_icon_master(src)
    written: list[str] = []

    def write(rel: str, data: str | None = None, image=None) -> None:
        path = target / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if image is not None:
            image.save(path, optimize=True)
        else:
            path.write_text(data or "", encoding="utf-8")
        written.append(rel)

    for density, px in LEGACY_ICON_SIZES:
        write(f"mipmap-{density}/ic_launcher.png", image=master.resize((px, px), Image.LANCZOS))
    fg, mono, bg = build_adaptive_layers(master)
    write("drawable-nodpi/ic_launcher_foreground.png", image=fg)
    write("drawable-nodpi/ic_launcher_monochrome.png", image=mono)
    write("drawable-nodpi/ic_launcher_bg.png", image=bg.convert("RGB"))
    write(
        "mipmap-anydpi-v26/ic_launcher.xml",
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@drawable/ic_launcher_bg"/>\n'
        '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
        '    <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>\n'
        "</adaptive-icon>\n",
    )
    write(
        "values/ic_launcher_background.xml",
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        f'    <color name="ic_launcher_background">{_adaptive_background(master)}</color>\n'
        "</resources>\n",
    )
    return sorted(written)


def write_integrity_data() -> None:
    """يولّد BayanIntegrityData.kt: SHA-256 لشهادة التوقيع (من BYNUX_CERT_SHA256) مقسّمًا ومعمّى بـ XOR.

    بدون keystore (توقيع debug) تغيب القيمة فيُعطَّل الفحص مع سطر في السجل.
    """
    target = ANDROID / "app" / "src" / "main" / "kotlin" / "com" / "bynux" / "app" / "BayanIntegrityData.kt"
    target.parent.mkdir(parents=True, exist_ok=True)
    raw = os.environ.get("BYNUX_CERT_SHA256", "").strip().replace(":", "").lower()
    if re.fullmatch(r"[0-9a-f]{64}", raw):
        digest = bytes.fromhex(raw)
        key = secrets.token_bytes(32)
        masked = bytes(a ^ b for a, b in zip(digest, key))
        enabled = "true"
        a_list = ", ".join(str(b) for b in masked)
        k_list = ", ".join(str(b) for b in key)
        print("Signature integrity check: ENABLED (expected certificate injected, XOR-masked)")
    else:
        enabled = "false"
        a_list = ", ".join(["0"] * 32)
        k_list = ", ".join(["0"] * 32)
        print("Signature integrity check: DISABLED (no release keystore -> debug signing)")
    target.write_text(
        f"package {APP_PACKAGE}\n\n"
        "// Generated by tools/prepare_android.py - do not edit by hand.\n"
        "internal object BayanIntegrityData {\n"
        f"    const val ENABLED: Boolean = {enabled}\n"
        f"    val A: IntArray = intArrayOf({a_list})\n"
        f"    val K: IntArray = intArrayOf({k_list})\n"
        "}\n",
        encoding="utf-8",
    )


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
    write_integrity_data()

    py_root = ANDROID / "app" / "src" / "main" / "python"
    py_root.mkdir(parents=True, exist_ok=True)
    source_py = ROOT / "bayan_runtime.py"
    if not source_py.exists():
        raise RuntimeError("bayan_runtime.py غير موجود")
    # المرحلة 4 (تجريبية، تُفعَّل فقط بمدخل cython=true): إن وُجد .so مجمَّع نستعمله بدل المصدر،
    # ولا يبقى bayan_runtime.py في الـ APK. بدون المتغير يبقى السلوك القديم (pyc) كما هو.
    cython_so = os.environ.get("BYNUX_CYTHON_SO", "").strip()
    if cython_so:
        so = Path(cython_so)
        if not so.is_file():
            raise RuntimeError(f"BYNUX_CYTHON_SO غير موجود: {so}")
        for stale in py_root.glob("bayan_runtime*"):
            stale.unlink()
        shutil.copy2(so, py_root / so.name)
        print(f"Cython module installed instead of bayan_runtime.py: {so.name}")
    else:
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
    icons = install_launcher_icons()
    print(f"Launcher icon installed ({len(icons)} files)")
    install_native_sources()
    print("Bayan Android/Chaquopy configuration prepared successfully")
    print(f"Chaquopy={CHAQUOPY}, Python={PYTHON}, ABI={ABIS}")


if __name__ == "__main__":
    main()
