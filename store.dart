// طبقة الملفات: السكربتات ملفات .py حقيقية داخل مجلد "Bayan 777"
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import 'python_runtime.dart';

const kFolderName = 'Bayan 777';
const kExternalRoot = '/storage/emulated/0/Bayan 777';

// ───────── النموذج ─────────
class Script {
  Script(
      {required this.name,
      required this.path,
      required this.modified,
      this.lastRun,
      this.pinned = false});
  String name; // اسم الملف مع .py
  String path;
  DateTime modified;
  DateTime? lastRun;
  bool pinned;
  String code = ''; // يُقرأ من الملف الحقيقي عند فتح المحرر
}

class DeletedScript {
  DeletedScript(
      {required this.name,
      required this.bytes,
      required this.modified,
      required this.pinned,
      required this.lastRun});
  final String name;
  final List<int> bytes;
  final DateTime modified;
  final bool pinned;
  final DateTime? lastRun;
}

/// الحد الأقصى لحجم ملف السكربت (بايت): أقل بقليل من حد السيرفر (1 MiB) لتفادي أي احتكاك.
/// يطابق bynuxMaxScriptBytes في account_cloud.dart.
const int kMaxScriptBytes = 1000000;
String get kTooLargeMessage => tr(
    'حجم الملف أكبر من الحد المسموح (1 ميجابايت)',
    'File size exceeds the maximum allowed limit (1 MB)');

class PickedPy {
  PickedPy(this.name, this.bytes);
  final String name;
  final List<int> bytes;
}

final scripts = ValueNotifier<List<Script>>(<Script>[]);
final scriptsReady = ValueNotifier<bool>(false);

// true = لا توجد صلاحية، والحفظ مؤقتاً داخل مساحة التطبيق
final fallbackMode = ValueNotifier<bool>(false);

final store = ScriptStore();

// ───────── أسماء الملفات ─────────
bool isPyName(String n) => n.toLowerCase().endsWith('.py');

String _stripPy(String n) => isPyName(n) ? n.substring(0, n.length - 3) : n;

String _base(String path) => path.substring(path.lastIndexOf('/') + 1);

final _badChars = RegExp(r'[\\/:*?"<>|\x00-\x1F]');
final _edges = RegExp(r'^[.\s]+|[.\s]+$');

// ينظّف الاسم ويزيل .py ويضمن ألا يكون فارغاً (يرجع fallback إن لم يبقَ شيء)
String cleanBase(String raw, {String fallback = 'script'}) {
  var s = raw.replaceAll(_badChars, '').trim();
  s = _stripPy(s);
  s = s.replaceAll(_edges, '');
  if (s.runes.length > 80) s = String.fromCharCodes(s.runes.take(80));
  s = s.replaceAll(_edges, '');
  return s.isEmpty ? fallback : s;
}

// ───────── الوقت النسبي ─────────
String _ar(int n, String one, String two, String few, String many) {
  if (n == 1) return one;
  if (n == 2) return two;
  if (n >= 3 && n <= 10) return '$n $few';
  return '$n $many';
}

String relativeTime(DateTime t, [DateTime? ref]) {
  final now = ref ?? DateTime.now();
  final diff = now.difference(t);
  if (isEn) {
    if (diff.inSeconds < 60) return 'Just now';
    final m = diff.inMinutes;
    if (m < 60) return '${m}m ago';
    final h = diff.inHours;
    if (h < 24) return '${h}h ago';
    final d = DateTime.utc(now.year, now.month, now.day)
        .difference(DateTime.utc(t.year, t.month, t.day))
        .inDays;
    if (d <= 1) return 'Yesterday';
    if (d < 30) return '${d}d ago';
    final mo = d ~/ 30;
    if (mo < 12) return '${mo}mo ago';
    final y = d ~/ 365;
    return '${y < 1 ? 1 : y}y ago';
  }
  if (diff.inSeconds < 60) return 'الآن';
  final m = diff.inMinutes;
  if (m < 60) return 'قبل ${_ar(m, 'دقيقة', 'دقيقتين', 'دقائق', 'دقيقة')}';
  final h = diff.inHours;
  if (h < 24) return 'قبل ${_ar(h, 'ساعة', 'ساعتين', 'ساعات', 'ساعة')}';
  final d = DateTime.utc(now.year, now.month, now.day)
      .difference(DateTime.utc(t.year, t.month, t.day))
      .inDays;
  if (d <= 1) return 'أمس';
  if (d < 30) return 'قبل ${_ar(d, 'يوم', 'يومين', 'أيام', 'يوماً')}';
  final mo = d ~/ 30;
  if (mo < 12) return 'قبل ${_ar(mo, 'شهر', 'شهرين', 'أشهر', 'شهراً')}';
  final y = d ~/ 365;
  return 'قبل ${_ar(y < 1 ? 1 : y, 'سنة', 'سنتين', 'سنوات', 'سنة')}';
}

// ───────── اختيار ملف بايثون ─────────
// يرجع null عند الإلغاء، ويرمي FormatException برسالة مناسبة إذا لم يكن الملف .py
Future<PickedPy?> pickPythonFile() async {
  final PlatformFile? f = await FilePicker.pickFile(
      type: FileType.custom, allowedExtensions: ['py']);
  if (f == null) return null;
  if (!isPyName(f.name)) {
    throw FormatException(tr(
        'الملف المختار ليس ملف بايثون (.py)',
        'Selected file is not a Python file (.py)'));
  }
  final bytes = await f.readAsBytes();
  if (bytes.length > kMaxScriptBytes) {
    throw FormatException(kTooLargeMessage);
  }
  return PickedPy(f.name, bytes);
}

// ───────── المخزن ─────────
class ScriptStore {
  static const String _stateFileName = 'bynux_store_v2.json';

  final Map<String, bool> _flags = <String, bool>{};
  final Map<String, Set<String>> _pinsByNs = <String, Set<String>>{};
  final Map<String, Map<String, int>> _runsByNs = <String, Map<String, int>>{};
  Directory? _dir;
  int _sdk = 33;
  bool _prefsLoaded = false;
  bool _inited = false;
  bool _ready = false;
  Future<void> _ops = Future<void>.value();
  Future<void> _saveChain = Future<void>.value();

  // يجعل كل عمليات الملفات تعمل بالتتابع حتى لا تتداخل
  Future<T> _serial<T>(Future<T> Function() job) {
    final run = _ops.then((_) => job());
    _ops = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  // أندرويد 11 فما فوق يحتاج إذن "الوصول إلى جميع الملفات"
  bool get needsAllFilesAccess => _sdk >= 30;

  String get _ns => fallbackMode.value ? 'int' : 'ext';

  File _stateFile() => File('${bynuxAppSupportDirSync().path}/$_stateFileName');

  void _decodeStateMap(Map<dynamic, dynamic> data) {
    final rawFlags = data['flags'];
    if (rawFlags is Map) {
      rawFlags.forEach((k, v) {
        if (v == true || v == 'true') _flags[k.toString()] = true;
      });
    }
    final rawLang = data['lang']?.toString();
    if (rawLang == 'ar' || rawLang == 'en') {
      appLang.value = rawLang!;
    }
    final rawPins = data['pins'];
    if (rawPins is Map) {
      rawPins.forEach((ns, list) {
        if (list is List) {
          _pinsByNs
              .putIfAbsent(ns.toString(), () => <String>{})
              .addAll(list.map((e) => e.toString()));
        }
      });
    }
    final rawRuns = data['runs'];
    if (rawRuns is Map) {
      rawRuns.forEach((ns, map) {
        if (map is Map) {
          final target =
              _runsByNs.putIfAbsent(ns.toString(), () => <String, int>{});
          map.forEach((k, v) {
            if (v is num) target[k.toString()] = v.toInt();
          });
        }
      });
    }
  }

  /// قراءة سريعة للحالة المحفوظة (الأعلام واللغة والمثبّتات) قبل runApp.
  /// اللغة الافتراضية دائمًا هي العربية ('ar') حتى لو كان هاتف المستخدم بالإنجليزية،
  /// ولا تتغير إلا إذا اختار المستخدم نفسه لغة من القائمة الجانبية.
  Future<void> loadSaved() async {
    if (_prefsLoaded) return;
    _prefsLoaded = true;
    try {
      final file = _stateFile();
      if (file.existsSync()) {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map) _decodeStateMap(decoded);
      }
    } catch (e) {
      debugPrint('store state file read: $e');
    }
    try {
      final nativePrefs = await bayanSystem.getPrefs();
      final sdkVal = nativePrefs['sdk'];
      if (sdkVal is num && sdkVal.toInt() > 0) _sdk = sdkVal.toInt();
      nativePrefs.forEach((k, v) {
        if (k.startsWith('flag_') && (v == 'true' || v == true)) {
          _flags[k.substring(5)] = true;
        }
      });
      final savedLang = nativePrefs['lang']?.toString();
      if (savedLang == 'ar' || savedLang == 'en') {
        appLang.value = savedLang!;
      }
      for (final ns in const <String>['ext', 'int']) {
        final rawRuns = nativePrefs['runs.$ns']?.toString();
        if (rawRuns != null && rawRuns.isNotEmpty) {
          try {
            final m = jsonDecode(rawRuns);
            if (m is Map) {
              final target = _runsByNs.putIfAbsent(ns, () => <String, int>{});
              m.forEach((k, v) {
                if (v is num) target.putIfAbsent(k.toString(), () => v.toInt());
              });
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('store native prefs read: $e');
    }
  }

  Future<void> _persistState() {
    final payload = jsonEncode(<String, Object?>{
      'v': 2,
      'lang': appLang.value,
      'flags': _flags,
      'pins': _pinsByNs.map((k, v) => MapEntry(k, v.toList())),
      'runs': _runsByNs,
    });
    final job = _saveChain.then((_) async {
      try {
        final file = _stateFile();
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(payload, flush: true);
        await tmp.rename(file.path);
      } catch (e) {
        debugPrint('store state write: $e');
      }
    });
    _saveChain = job.then<void>((_) {}, onError: (_) {});
    return job;
  }

  // ───── البدء ─────
  Future<void> init() async {
    await loadSaved();
    if (_inited) return;
    _inited = true;
    await _serial<void>(() async {
      try {
        await _resolveRoot();
      } catch (e) {
        debugPrint('resolveRoot: $e');
      }
      await _doRefresh();
    });
    _ready = true;
    scriptsReady.value = true;
  }

  // الفحص الحقيقي: هل نستطيع إنشاء المجلد والكتابة فيه فعلاً؟
  Future<bool> _externalWritable() async {
    try {
      final d = Directory(kExternalRoot);
      if (!await d.exists()) await d.create(recursive: true);
      final probe = File('${d.path}/.bayan_probe');
      await probe.writeAsString('1', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Directory> _internalDir() async {
    final base = bynuxAppDocsDirSync();
    final d = Directory('${base.path}/$kFolderName');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<void> _resolveRoot() async {
    if (await _externalWritable()) {
      _dir = Directory(kExternalRoot);
      fallbackMode.value = false;
      await _migrateInternal();
    } else {
      _dir = await _internalDir();
      fallbackMode.value = true;
    }
  }

  Future<Directory> _ensureDir() async {
    var d = _dir;
    if (d == null) {
      await _resolveRoot();
      d = _dir;
    }
    if (d == null) throw StateError('no storage');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  // ───── أعلام صغيرة لا تخص السكربتات (مثل: هل ظهرت شاشة الترحيب؟) ─────
  bool getFlag(String key) => _flags[key] ?? false;

  Future<void> setFlag(String key, bool value) async {
    _flags[key] = value;
    await _persistState();
    await bayanSystem.setPref('flag_$key', value ? 'true' : 'false');
  }

  // ───── حفظ اللغة المختارة (مع بقاء العربية افتراضية عند أول تشغيل) ─────
  Future<void> setLang(String code) async {
    final normalized = code == 'en' ? 'en' : 'ar';
    appLang.value = normalized;
    await _persistState();
    await bayanSystem.setPref('lang', normalized);
  }

  // ───── الصلاحيات ─────
  Future<void> requestAccess() async {
    try {
      if (_sdk >= 30) {
        await Permission.manageExternalStorage.request();
      } else if (_sdk >= 23) {
        final st = await Permission.storage.request();
        if (st.isPermanentlyDenied) await openAppSettings();
      } else {
        await openAppSettings();
      }
    } catch (_) {
      try {
        await openAppSettings();
      } catch (_) {}
    }
    await reevaluate();
  }

  Future<void> reevaluate() => _serial<void>(() async {
        try {
          await _resolveRoot();
        } catch (e) {
          debugPrint('reevaluate: $e');
        }
        await _doRefresh();
      });

  Future<void> onResume() {
    if (!_ready) return Future<void>.value();
    return fallbackMode.value ? reevaluate() : refresh();
  }

  // ───── نقل السكربتات المؤقتة إلى Bayan 777 (بدون الكتابة فوق أي ملف) ─────
  Future<void> _migrateInternal() async {
    try {
      final base = bynuxAppDocsDirSync();
      final src = Directory('${base.path}/$kFolderName');
      if (!await src.exists()) return;
      final files = await _pyFiles(src);
      if (files.isEmpty) return;
      final dst = Directory(kExternalRoot);
      if (!await dst.exists()) await dst.create(recursive: true);

      final srcPins = _pinSet('int'), dstPins = _pinSet('ext');
      final srcRuns = _runMap('int'), dstRuns = _runMap('ext');

      for (final f in files) {
        try {
          final oldKey = _base(f.path).toLowerCase();
          final bytes = await f.readAsBytes();
          final modified = (await f.stat()).modified;
          final target = await _createUnique(_base(f.path), bytes,
              into: dst, exact: true);
          if (await target.length() != bytes.length) {
            await target.delete(); // النسخة ناقصة: نبقي الأصل ولا نفقده
            continue;
          }
          try {
            await target.setLastModified(modified);
          } catch (_) {}
          final newKey = _base(target.path).toLowerCase();
          if (srcPins.remove(oldKey)) dstPins.add(newKey);
          final r = srcRuns.remove(oldKey);
          if (r != null) dstRuns[newKey] = r;
          await f.delete();
        } catch (e) {
          debugPrint('migrate ${f.path}: $e');
        }
      }
      await _savePins(srcPins, 'int');
      await _savePins(dstPins, 'ext');
      await _saveRuns(srcRuns, 'int');
      await _saveRuns(dstRuns, 'ext');
    } catch (e) {
      debugPrint('migrate: $e');
    }
  }

  // ───── البيانات الوصفية: التثبيت وآخر تشغيل (محفوظة محلياً) ─────
  Set<String> _pinSet([String? ns]) =>
      Set<String>.of(_pinsByNs[ns ?? _ns] ?? const <String>{});

  Future<void> _savePins(Set<String> s, [String? ns]) async {
    _pinsByNs[ns ?? _ns] = Set<String>.of(s);
    await _persistState();
  }

  Map<String, int> _runMap([String? ns]) =>
      Map<String, int>.of(_runsByNs[ns ?? _ns] ?? const <String, int>{});

  Future<void> _saveRuns(Map<String, int> m, [String? ns]) async {
    final key = ns ?? _ns;
    _runsByNs[key] = Map<String, int>.of(m);
    await _persistState();
    unawaited(bayanSystem.setPref('runs.$key', jsonEncode(m)));
  }

  Future<void> _moveMeta(String from, String to) async {
    if (from == to) return;
    final pins = _pinSet();
    if (pins.remove(from)) {
      pins.add(to);
      await _savePins(pins);
    }
    final runs = _runMap();
    final r = runs.remove(from);
    if (r != null) {
      runs[to] = r;
      await _saveRuns(runs);
    }
  }

  Future<void> _dropMeta(String key) async {
    final pins = _pinSet();
    if (pins.remove(key)) await _savePins(pins);
    final runs = _runMap();
    if (runs.remove(key) != null) await _saveRuns(runs);
  }

  // ───── القراءة من المجلد ─────
  Future<List<File>> _pyFiles(Directory d) async {
    final out = <File>[];
    await for (final e in d.list(followLinks: false)) {
      if (e is File && isPyName(_base(e.path))) out.add(e);
    }
    return out;
  }

  Future<Set<String>> _lowerNames(Directory d) async {
    final out = <String>{};
    await for (final e in d.list(followLinks: false)) {
      out.add(_base(e.path).toLowerCase());
    }
    return out;
  }

  void _sort(List<Script> l) => l.sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        final c = b.modified.compareTo(a.modified);
        return c != 0
            ? c
            : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

  void _publishNow() {
    final l = List<Script>.of(scripts.value);
    _sort(l);
    scripts.value = l;
  }

  Future<void> refresh() => _serial<void>(_doRefresh);

  Future<void> _doRefresh() async {
    final d = _dir;
    if (d == null) return;
    try {
      if (!await d.exists()) await d.create(recursive: true);
      final files = await _pyFiles(d);
      final pins = _pinSet();
      final runs = _runMap();
      final old = <String, Script>{for (final s in scripts.value) s.path: s};
      final list = <Script>[];
      final keys = <String>{};
      for (final f in files) {
        final name = _base(f.path);
        final key = name.toLowerCase();
        keys.add(key);
        DateTime mod;
        try {
          mod = (await f.stat()).modified;
        } catch (_) {
          mod = DateTime.now();
        }
        final s = old[f.path] ??
            Script(name: name, path: f.path, modified: mod);
        s.name = name;
        s.path = f.path;
        s.modified = mod;
        s.pinned = pins.contains(key);
        final r = runs[key];
        s.lastRun = r == null ? null : DateTime.fromMillisecondsSinceEpoch(r);
        list.add(s);
      }
      // تنظيف بيانات ملفات لم تعد موجودة (فقط إذا وجدنا ملفات فعلاً)
      if (files.isNotEmpty) {
        final p2 = pins.where(keys.contains).toSet();
        if (p2.length != pins.length) await _savePins(p2);
        final r2 = Map<String, int>.of(runs)
          ..removeWhere((k, _) => !keys.contains(k));
        if (r2.length != runs.length) await _saveRuns(r2);
      }
      _sort(list);
      scripts.value = list;
    } catch (e) {
      debugPrint('refresh: $e');
    }
  }

  // ───── سكربت من مسار نسبي داخل Bayan 777 (من سطر Traceback) ─────
  // يرجع null إذا لم يعد الملف موجودًا. وحدة .py داخل مجلد فرعي ليست في القائمة،
  // فنبني لها كائن Script مؤقتًا حتى يفتحها المحرر.
  Future<Script?> scriptAtRelative(String rel) async {
    final root = _dir?.path;
    if (root == null || rel.isEmpty || rel.split('/').contains('..')) return null;
    final path = '$root/$rel';
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      for (final s in scripts.value) {
        if (s.path == path) return s;
      }
      final stat = await f.stat();
      return Script(name: rel, path: path, modified: stat.modified);
    } catch (_) {
      return null;
    }
  }

  // ───── القراءة والكتابة ─────
  Future<String> readCode(Script s) => _serial<String>(() async {
        final file = File(s.path);
        // ملف أكبر من الحد لا يُفتح في المحرر (يبقى قابلاً للتشغيل)
        if (await file.length() > kMaxScriptBytes) {
          throw FormatException(kTooLargeMessage);
        }
        final bytes = await file.readAsBytes();
        var t = utf8.decode(bytes, allowMalformed: true);
        if (t.isNotEmpty && t.codeUnitAt(0) == 0xFEFF) t = t.substring(1);
        return t.replaceAll('\r\n', '\n');
      });

  // حفظ آمن لملف السكربت فقط: نكتب في ملف مؤقت بنفس المجلد ثم نستبدل به الأصل،
  // فإن امتلأ التخزين أو أُغلق التطبيق أثناء الكتابة يبقى الملف الأصلي سليماً.
  Future<bool> writeCode(Script s, String text) => _serial<bool>(() async {
        final f = File(s.path);
        final tmp = File('${s.path}.tmp');
        try {
          await tmp.writeAsString(text, flush: true);
          try {
            await tmp.rename(s.path);
          } on FileSystemException {
            // بعض أنظمة الملفات ترفض الاستبدال بالتسمية: كحل أخير نكتب مباشرة
            await f.writeAsString(text, flush: true);
            try {
              await tmp.delete();
            } catch (_) {}
          }
          try {
            s.modified = (await f.stat()).modified;
          } catch (_) {
            s.modified = DateTime.now();
          }
          _publishNow();
          return true;
        } catch (e) {
          debugPrint('writeCode: $e');
          try {
            if (await tmp.exists()) await tmp.delete();
          } catch (_) {}
          return false;
        }
      });

  // ───── اختيار اسم غير مستخدم (بدون الكتابة فوق ملف موجود) ─────
  Future<String> _pickName(Directory d, String base, {String? except}) async {
    final taken = await _lowerNames(d);
    final ex = except?.toLowerCase();
    if (ex != null) taken.remove(ex);
    for (var n = 0; n < 100000; n++) {
      final name = n == 0 ? '$base.py' : '${base}_$n.py';
      final low = name.toLowerCase();
      if (taken.contains(low)) continue;
      if (low != ex && await File('${d.path}/$name').exists()) continue;
      return name;
    }
    throw StateError('no free name');
  }

  Future<File> _createUnique(String desired, List<int> bytes,
      {Directory? into, bool exact = false}) async {
    final d = into ?? await _ensureDir();
    final base = exact ? _stripPy(desired) : cleanBase(desired);
    for (var i = 0; i < 20; i++) {
      final name = await _pickName(d, base);
      final f = File('${d.path}/$name');
      try {
        await f.create(exclusive: true);
      } on FileSystemException {
        if (await f.exists()) continue; // سباق نادر: ظهر الملف للتو
        rethrow;
      }
      try {
        await f.writeAsBytes(bytes, flush: true);
      } catch (_) {
        try {
          await f.delete();
        } catch (_) {}
        rethrow;
      }
      return f;
    }
    throw StateError('could not create file');
  }

  Script _find(File f, DateTime fallbackTime) => scripts.value.firstWhere(
      (e) => e.path == f.path,
      orElse: () => Script(
          name: _base(f.path), path: f.path, modified: fallbackTime));

  // ───── إنشاء / استيراد ─────
  Future<Script> createFromBytes(String rawName, List<int> bytes) =>
      _serial<Script>(() async {
        if (bytes.length > kMaxScriptBytes) {
          throw FormatException(kTooLargeMessage);
        }
        final f = await _createUnique(rawName, bytes);
        await _doRefresh();
        return _find(f, DateTime.now());
      });

  Future<Script> createFromText(String rawName, String text) =>
      createFromBytes(rawName, utf8.encode(text));

  // ───── إعادة التسمية: ترجع null إذا كان الاسم غير صالح ─────
  Future<Script?> rename(Script s, String raw) => _serial<Script?>(() async {
        final cleaned = cleanBase(raw, fallback: '');
        if (cleaned.isEmpty) return null;
        final d = await _ensureDir();
        final name = await _pickName(d, cleaned, except: s.name);
        if (name == s.name) return s;
        final target = '${d.path}/$name';
        await File(s.path).rename(target);
        await _moveMeta(s.name.toLowerCase(), name.toLowerCase());
        s.name = name;
        s.path = target;
        _publishNow();
        return s;
      });

  // ───── النسخ ─────
  Future<Script> duplicate(Script s) => _serial<Script>(() async {
        final bytes = await File(s.path).readAsBytes();
        final f = await _createUnique('${_stripPy(s.name)}_copy', bytes);
        await _doRefresh();
        return _find(f, DateTime.now());
      });

  // ───── الحذف مع إمكانية الاستعادة بالمحتوى الحقيقي ─────
  Future<DeletedScript?> delete(Script s) => _serial<DeletedScript?>(() async {
        final f = File(s.path);
        if (!await f.exists()) {
          await _doRefresh();
          return null;
        }
        final bytes = await f.readAsBytes();
        DateTime modified;
        try {
          modified = (await f.stat()).modified;
        } catch (_) {
          modified = s.modified;
        }
        await f.delete();
        final key = s.name.toLowerCase();
        final pinned = _pinSet().contains(key);
        final run = _runMap()[key];
        await _dropMeta(key);
        scripts.value =
            scripts.value.where((e) => !identical(e, s)).toList();
        return DeletedScript(
            name: s.name,
            bytes: bytes,
            modified: modified,
            pinned: pinned,
            lastRun: run == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(run));
      });

  Future<Script> restore(DeletedScript d) => _serial<Script>(() async {
        final f = await _createUnique(d.name, d.bytes, exact: true);
        try {
          await f.setLastModified(d.modified);
        } catch (_) {}
        final key = _base(f.path).toLowerCase();
        if (d.pinned) {
          final p = _pinSet()..add(key);
          await _savePins(p);
        }
        final r = d.lastRun;
        if (r != null) {
          final m = _runMap();
          m[key] = r.millisecondsSinceEpoch;
          await _saveRuns(m);
        }
        await _doRefresh();
        return _find(f, d.modified);
      });

  // ───── التثبيت في الأعلى ─────
  Future<void> setPinned(Script s, bool v) => _serial<void>(() async {
        final key = s.name.toLowerCase();
        final p = _pinSet();
        if (v) {
          p.add(key);
        } else {
          p.remove(key);
        }
        await _savePins(p);
        s.pinned = v;
        _publishNow();
      });

  // ───── آخر تشغيل ─────
  // at: وقت نهاية التشغيل (للمصالحة عند فتح التطبيق). لا يرجع بـ«آخر تشغيل» إلى الوراء.
  Future<void> markRun(Script s, {DateTime? at}) => _serial<void>(() async {
        try {
          final now = at ?? DateTime.now();
          final runs = _runMap();
          final key = s.name.toLowerCase();
          final prev = runs[key];
          if (prev != null && prev >= now.millisecondsSinceEpoch) return;
          runs[key] = now.millisecondsSinceEpoch;
          await _saveRuns(runs);
          s.lastRun = now;
          _publishNow();
        } catch (e) {
          debugPrint('markRun: $e');
        }
      });
}
