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
