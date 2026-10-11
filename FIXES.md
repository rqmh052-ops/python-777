# ما تم إصلاحه (Bayan Python Runner)

## السبب الجذري للمشكلة
بناء release في Flutter يشغّل R8 افتراضيًا. R8 غيّر اسم الكلاس `RunCallback` إلى `y0`
وحذف دوال `emitState` و`emitPackage` لأن بايثون وحده يستدعيها (عبر Chaquopy) ولا يراها R8.
النتيجة: كل سكربت وكل تثبيت مكتبة يفشل بـ `'y0' object has no attribute ...`.

الحل: `--no-shrink` في `.github/workflows/build.yml`.

## أخطاء أخرى كانت ستظهر بعد حل R8
1. `PackageCallback` لا يحتوي `shouldStop()` بينما `install_package` يستدعيها -> يفشل التثبيت ويتراجع بعد أول wheel. (MainActivity.kt)
2. تحليل اسم ملف wheel كان يقرأ build tag (`-0-`) على أنه الإصدار -> ظهور "أحدث نسخة: 0" لـ PyYAML، وفشل تثبيت حزم Chaquopy الأصلية.
3. اختيار إصدارات تجريبية (rc/beta) وملفات yanked بدل الإصدار المستقر.
4. أي wheel فيها `.data/scripts` كانت تُفشل التثبيت كاملًا.
5. اعتماد دائري بين حزمتين كان يُفشل التثبيت، وخطأ `KeyError` محتمل في `_plan_package`.
6. اختبار import بعد التثبيت يفشل مع الحزم التي لا تحتوي `top_level.txt`.
7. شروط `platform_machine` و`platform_python_implementation` في marker كانت خاطئة فتُهمل اعتمادات مطلوبة.
8. دعم `==1.2.*` و`requests[extras]` و`abi3` وتصفية قيود النسخ في مستودع Chaquopy والتحقق من sha256 له.
9. مفتاح `releases` في PyPI JSON مُهمَل رسميًا: أضفت بديلًا عبر Simple API (PEP 691) + إعادة محاولة واحدة للشبكة.
10. السكربتات كانت بطيئة جدًا (استدعاء Java عند كل opcode). صار الفحص كل 50ms كحد أدنى، والإيقاف ما زال يعمل حتى مع `while True: pass`.
11. التتبّع (traceback) كان يعرض أسطر المشغّل الداخلية، و`sys.exit("رسالة")` كان لا يطبع الرسالة.
12. سباق "هناك سكربت آخر يعمل" عند إعادة التشغيل السريع (Kotlin) وأحداث قديمة بنفس runId (Dart).
13. رسائل الخطأ في الواجهة صارت تعرض النص الحقيقي بدل `PlatformException(...)`، وسقف 5000 سطر للإخراج.

## اختبارات جديدة (تعمل في CI قبل البناء)
`tools/test_extra.py` يتضمن اختبار "عقد" يقارن كل دالة يستدعيها بايثون بما هو موجود فعلًا في Kotlin،
وهذا يكشف مباشرة مشكلتي `emitState` و`shouldStop`.

## التطبيق من الهاتف
ارفع الملفات إلى المستودع بنفس مساراتها:
- `.github/workflows/build.yml`
- `MainActivity.kt`, `bayan_runtime.py`, `main.dart`, `script_runner.dart`
- `tools/test_extra.py` (جديد)
ثم شغّل Build من تبويب Actions وثبّت الـ APK الجديد (أزل القديم أولًا).


---

# الجولة الثانية (فحص شامل بعد ظهور الخطأ `'y0' object has no attribute 'emitState'` مرة أخرى)

## لماذا يظهر الخطأ حتى مع وجود `--no-shrink` في الكود؟
الاحتمالان الوحيدان: (1) الـ APK المثبّت على الهاتف مبني قبل رفع الإصلاح، أو (2) R8 ما زال يعمل رغم الإعلان.
بدل التخمين صار الأمر قابلًا للتحقق:
- `tools/prepare_android.py` يكتب الآن `android/app/proguard-rules.pro` (يحمي `BayanPythonBridge` وكل كلاساتها الداخلية)؛
  Flutter يضيف هذا الملف تلقائيًا إلى بناء release إذا كان R8 فعّالًا. أي أن الحماية تعمل **مع** `--no-shrink` و**بدونه**.
- خطوة CI جديدة `Verify Kotlin callbacks survived R8` تشغّل `tools/verify_apk.py` على الـ APK الناتج وتُفشل البناء
  إذا لم تجد أسماء `emitState/emitPackage/...` داخل `classes.dex`. إذا كانت الخطوة خضراء فالـ APK سليم.
- إن وصل إلى الهاتف APK ناقص رغم ذلك، يعرض المشغّل رسالة عربية واضحة تشرح السبب بدل `'y0' object has no attribute`.

## مشاكل أخرى كانت ستمنع العمل الفعلي (تم إصلاحها في `bayan_runtime.py`)
1. **أزرار Stop لا تعمل أثناء `time.sleep()`** ولا أثناء انتظار حلقة asyncio. الآن `time.sleep` يُقسَّم إلى شرائح 0.1ث تفحص الإيقاف،
   وخيط مراقبة يوقظ حلقات asyncio الخاملة عند الضغط على إيقاف (بوتات تيليجرام).
2. **`python-telegram-bot` و`Telethon` كانا سيفشلان**: السكربت يعمل في خيط ثانوي، و`asyncio.get_event_loop()` و`signal.signal()` و`loop.add_signal_handler()`
   لا تعمل خارج الخيط الرئيسي (`RuntimeError`/`ValueError`). أُضيفت طبقة توافق تنشئ event loop للخيط وتجعل أخطاء الإشارات بلا أثر.
3. **ازدحام الواجهة**: كل `print` كان يرسل رسالتين إلى Flutter. الإخراج يُجمَّع الآن دفعات (≤ 4096 حرف أو كل 30ms) مع الحفاظ على ترتيب stdout/stderr.
4. `sys.stdout.reconfigure(encoding="utf-8")` و`sys.stdout.buffer` كانا يرميان `AttributeError` (شائعة في السكربتات العربية).
5. `sys.argv` لم يكن يُضبط على مسار السكربت.
6. الخيوط غير daemon التي يبدأها السكربت: ينتظرها المشغّل كما يفعل CPython، وخيوط daemon تُنهى مع نهاية التشغيل (لا بوتات زومبي).
7. الضغط على Stop لم يعد يطبع `StopRequested` من خيوط المستخدم.

## اختبارات جديدة (تعمل في CI قبل البناء)
`tools/test_extra.py`: رسالة R8 الواضحة، قواعد keep + `verify_apk`، asyncio/signals في خيط ثانوي، إيقاف `sleep` وحلقات asyncio الخاملة،
تجميع الإخراج وترتيبه، `argv`/`reconfigure`/`buffer`، الخيوط المتبقية.

## قيود معروفة (لم تُحل بعد)
- **البوتات الطويلة في الخلفية**: أندرويد يجمّد/يقتل العملية عند خروج التطبيق من الشاشة. تشغيل بوت لساعات يحتاج Foreground Service + إشعار (إصدار قادم).
- إيقاف سكربت عالق داخل استدعاء شبكة/ملف blocking (مثل `socket.recv` بلا timeout) غير ممكن حتى يعود الاستدعاء.
- حزم تحتاج مترجم C (sdist) لا تُثبَّت؛ يُثبَّت فقط wheel جاهز (pure-Python أو Android من مستودع Chaquopy).

## الملفات المعدّلة في هذه الجولة
`.github/workflows/build.yml`, `bayan_runtime.py`, `tools/prepare_android.py`, `tools/test_extra.py`, `tools/verify_apk.py` (جديد), `FIXES.md`


---

# المرحلة 1 من الإصدار القادم: F3 ثم F2 ثم F1 ثم F9 ثم F10

- **F3 (شاشة المكتبات):** حُذفت بطاقة التقدم العلوية. لكل بطاقة منطقة تقدم ارتفاعها ثابت (22) محجوزة دائمًا،
  وحالاتها: غير مثبّتة / في الانتظار / جارٍ التثبيت (شريط أخضر ونسبة تصاعدية) / تم التثبيت / فشل (سبب مختصر + تفاصيل).
  النسبة: حل الاعتماديات 0–10%، التنزيل 10–80% موزّعًا حسب أحجام كل الـwheels، التثبيت والتحقق 80–100%.
  التثبيتات المتعددة تدخل طابورًا (`LibInstaller` في python_runtime.dart) وتظهر «في الانتظار».
  بايثون يرسل الآن حدث `wheel`/`wheel_cached` بحجم كل wheel قبل تنزيلها.
- **F2 (بطاقات المكتبة الناقصة):** عند انتهاء التشغيل بـ`ModuleNotFoundError` يمسح بايثون كل `import` بـ`ast`
  ويرسل المفقودات كلها دفعة واحدة عبر دالة Kotlin جديدة `emitMissing` (أُضيفت إلى `_RUN_CALLBACK_REQUIRED`
  وإلى `REQUIRED` في verify_apk.py وإلى اختبار العقد). توفر النسخة على أندرويد يُفحص عبر `packages.check`.
- **F1 (سطر الخطأ):** أسطر `File "…", line N` داخل `Bayan 777` قابلة للضغط. إن كان محرر الملف مفتوحًا نرجع إليه
  ولا نفتح نسخة ثانية، وإلا يُفتح المحرر فوق الإخراج.
- **F9:** بحث داخل المحرر (بدون استبدال). **F10:** قائمة النسخ/القص/اللصق/تحديد الكل بالعربية عبر `contextMenuBuilder`.

الملفات المعدّلة: `main.dart`, `python_runtime.dart`, `store.dart`, `MainActivity.kt`, `bayan_runtime.py`,
`tools/test_extra.py`, `tools/test_runtime.py`, `tools/verify_apk.py`, `FIXES.md`.
