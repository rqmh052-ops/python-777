// طبقة الملفات: السكربتات ملفات .py حقيقية داخل مجلد "Bayan 777"
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
// يرجع null عند الإلغاء، ويرمي FormatException برسالة عربية إذا لم يكن الملف .py
Future<PickedPy?> pickPythonFile() async {
  final PlatformFile? f = await FilePicker.pickFile(
      type: FileType.custom, allowedExtensions: ['py']);
  if (f == null) return null;
  if (!isPyName(f.name)) {
    throw const FormatException('الملف المختار ليس ملف بايثون (.py)');
  }
  final bytes = await f.readAsBytes();
  return PickedPy(f.name, bytes);
}

// ───────── المخزن ─────────
class ScriptStore {
  SharedPreferences? _prefs;
  Directory? _dir;
  int _sdk = 0;
  bool _inited = false;
  bool _ready = false;
  Future<void> _ops = Future<void>.value();

  // يجعل كل عمليات الملفات تعمل بالتتابع حتى لا تتداخل
  Future<T> _serial<T>(Future<T> Function() job) {
    final run = _ops.then((_) => job());
    _ops = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  // أندرويد 11 فما فوق يحتاج إذن "الوصول إلى جميع الملفات"
  bool get needsAllFilesAccess => _sdk >= 30;

  String get _ns => fallbackMode.value ? 'int' : 'ext';

  // ───── البدء ─────
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('prefs: $e');
    }
    _sdk = await _androidSdk();
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

  Future<int> _androidSdk() async {
    if (!Platform.isAndroid) return 0;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final int? v = info.version.sdkInt;
      return v ?? 0;
    } catch (_) {
      return 0;
    }
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
    final base = await getApplicationDocumentsDirectory();
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
      final base = await getApplicationDocumentsDirectory();
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
      (_prefs?.getStringList('pins.${ns ?? _ns}') ?? const <String>[]).toSet();

  Future<void> _savePins(Set<String> s, [String? ns]) async {
    await _prefs?.setStringList('pins.${ns ?? _ns}', s.toList());
  }

  Map<String, int> _runMap([String? ns]) {
    final raw = _prefs?.getString('runs.${ns ?? _ns}');
    if (raw == null) return <String, int>{};
    try {
      final m = jsonDecode(raw) as Map;
      return m.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    } catch (_) {
      return <String, int>{};
    }
  }

  Future<void> _saveRuns(Map<String, int> m, [String? ns]) async {
    await _prefs?.setString('runs.${ns ?? _ns}', jsonEncode(m));
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

  // ───── القراءة والكتابة ─────
  Future<String> readCode(Script s) => _serial<String>(() async {
        final bytes = await File(s.path).readAsBytes();
        var t = utf8.decode(bytes, allowMalformed: true);
        if (t.isNotEmpty && t.codeUnitAt(0) == 0xFEFF) t = t.substring(1);
        return t.replaceAll('\r\n', '\n');
      });

  Future<bool> writeCode(Script s, String text) => _serial<bool>(() async {
        try {
          final f = File(s.path);
          await f.writeAsString(text, flush: true);
          try {
            s.modified = (await f.stat()).modified;
          } catch (_) {
            s.modified = DateTime.now();
          }
          _publishNow();
          return true;
        } catch (e) {
          debugPrint('writeCode: $e');
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
  Future<void> markRun(Script s) => _serial<void>(() async {
        try {
          final now = DateTime.now();
          final runs = _runMap();
          runs[s.name.toLowerCase()] = now.millisecondsSinceEpoch;
          await _saveRuns(runs);
          s.lastRun = now;
          _publishNow();
        } catch (e) {
          debugPrint('markRun: $e');
        }
      });
}
