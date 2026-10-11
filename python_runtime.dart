import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

// يعرض رسالة الخطأ الحقيقية بدل PlatformException(code, message, null, null)
String errText(Object e) =>
    e is PlatformException ? (e.message ?? e.code) : '$e';

// اسم المكتبة موحّدًا (حروف صغيرة، والفواصل _ . - تصبح -)
String pkgKey(String name) =>
    name.replaceAll(RegExp(r'[_.-]+'), '-').toLowerCase();

String cleanPackageName({required String clean}) {
  final match = RegExp(r'^([A-Za-z0-9][A-Za-z0-9_.-]*)').firstMatch(clean);
  return pkgKey(match?.group(1) ?? clean);
}

class BayanEvent {
  const BayanEvent(this.raw);

  final Map<String, dynamic> raw;

  String get channel => raw['channel']?.toString() ?? '';
  String get type => raw['type']?.toString() ?? '';
  String get runId => raw['runId']?.toString() ?? '';
  String get jobId => raw['jobId']?.toString() ?? '';
  String get text => raw['text']?.toString() ?? '';
  String get packageName => raw['package']?.toString() ?? '';
  int get exitCode => (raw['exitCode'] as num?)?.toInt() ?? -1;
  double get progress => (raw['progress'] as num?)?.toDouble() ?? 0;
  int get received => (raw['received'] as num?)?.toInt() ?? 0;
  int get total => (raw['total'] as num?)?.toInt() ?? 0;
  String get stage => raw['stage']?.toString() ?? '';
  String get message => raw['message']?.toString() ?? '';
}

class InstalledPackage {
  const InstalledPackage({
    required this.name,
    required this.version,
    required this.size,
  });

  final String name;
  final String version;
  final int size;

  factory InstalledPackage.fromJson(Map<String, dynamic> json) {
    return InstalledPackage(
      name: json['name']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  }
}

// هل توجد نسخة من المكتبة تعمل على أندرويد؟ available == null يعني غير معروف (مثلًا لا اتصال).
class PackageAvailability {
  const PackageAvailability({
    required this.name,
    this.available,
    this.version,
    this.reason = '',
  });

  final String name;
  final bool? available;
  final String? version;
  final String reason;

  factory PackageAvailability.fromJson(Map<String, dynamic> json) {
    final a = json['available'];
    return PackageAvailability(
      name: json['name']?.toString() ?? '',
      available: a is bool ? a : null,
      version: json['version']?.toString(),
      reason: json['reason']?.toString() ?? '',
    );
  }
}

class CatalogPackage {
  const CatalogPackage({
    required this.name,
    required this.description,
    required this.module,
    this.installedVersion,
    this.latestVersion,
    this.latestSize,
    this.compatible = true,
    this.updateAvailable = false,
  });

  final String name;
  final String description;
  final String module;
  final String? installedVersion;
  final String? latestVersion;
  final int? latestSize;
  final bool compatible;
  final bool updateAvailable;

  factory CatalogPackage.fromJson(Map<String, dynamic> json) {
    return CatalogPackage(
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      module: json['module']?.toString() ?? '',
      installedVersion: json['installedVersion']?.toString(),
      latestVersion: json['latestVersion']?.toString(),
      latestSize: (json['latestSize'] as num?)?.toInt(),
      compatible: json['compatible'] != false,
      updateAvailable: json['updateAvailable'] == true,
    );
  }

  CatalogPackage copyWith({
    String? installedVersion,
    String? latestVersion,
    int? latestSize,
    bool? compatible,
    bool? updateAvailable,
  }) {
    return CatalogPackage(
      name: name,
      description: description,
      module: module,
      installedVersion: installedVersion ?? this.installedVersion,
      latestVersion: latestVersion ?? this.latestVersion,
      latestSize: latestSize ?? this.latestSize,
      compatible: compatible ?? this.compatible,
      updateAvailable: updateAvailable ?? this.updateAvailable,
    );
  }
}

class BayanPythonRuntime {
  BayanPythonRuntime._() {
    _eventsController = StreamController<BayanEvent>.broadcast();
    _eventSubscription = _eventChannel
        .receiveBroadcastStream()
        .map((dynamic value) => _decodeEvent(value))
        .listen(_eventsController.add, onError: _eventsController.addError);
  }

  static final BayanPythonRuntime instance = BayanPythonRuntime._();

  static const _methodChannel = MethodChannel('bayan/python');
  static const _eventChannel = EventChannel('bayan/python/events');

  late final StreamController<BayanEvent> _eventsController;
  late final StreamSubscription<dynamic> _eventSubscription;
  Stream<BayanEvent> get events => _eventsController.stream;

  int _serial = 0;

  BayanEvent _decodeEvent(dynamic value) {
    if (value is Map) {
      return BayanEvent(Map<String, dynamic>.from(value));
    }
    try {
      final decoded = jsonDecode(value.toString());
      if (decoded is Map) {
        return BayanEvent(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    return BayanEvent(<String, dynamic>{'text': value.toString()});
  }

  String newId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}-${++_serial}';

  Future<void> init() async {
    await _methodChannel.invokeMethod<dynamic>('init');
  }

  Future<void> run({required String runId, required String scriptPath}) async {
    await _methodChannel.invokeMethod<dynamic>('run', <String, dynamic>{
      'runId': runId,
      'scriptPath': scriptPath,
    });
  }

  Future<void> sendInput({required String runId, required String text}) async {
    await _methodChannel.invokeMethod<dynamic>('sendInput', <String, dynamic>{
      'runId': runId,
      'text': text,
    });
  }

  Future<void> stop({required String runId}) async {
    await _methodChannel.invokeMethod<dynamic>('stop', <String, dynamic>{
      'runId': runId,
    });
  }

  Future<List<InstalledPackage>> listInstalled() async {
    final raw = await _methodChannel
        .invokeMethod<dynamic>('packages.list') as dynamic;
    if (raw is! List) return const <InstalledPackage>[];
    return raw
        .whereType<Map>()
        .map((e) => InstalledPackage.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
  }

  Future<List<CatalogPackage>> catalogStatus() async {
    final raw = await _methodChannel
        .invokeMethod<dynamic>('packages.catalog') as dynamic;
    if (raw is! List) return const <CatalogPackage>[];
    return raw
        .whereType<Map>()
        .map((e) => CatalogPackage.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
  }

  Future<List<PackageAvailability>> checkAvailability(List<String> names) async {
    final dynamic raw = await _methodChannel.invokeMethod<dynamic>(
        'packages.check', <String, dynamic>{'names': names});
    if (raw is! List) return const <PackageAvailability>[];
    return raw
        .whereType<Map>()
        .map((e) => PackageAvailability.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
  }

  Future<void> installPackage({
    required String spec,
    required String jobId,
  }) async {
    await _methodChannel.invokeMethod<dynamic>('packages.install', <String, dynamic>{
      'spec': spec,
      'jobId': jobId,
    });
  }

  Future<void> removePackage({required String name}) async {
    await _methodChannel
        .invokeMethod<dynamic>('packages.remove', <String, dynamic>{'name': name});
  }

  void dispose() {
    _eventSubscription.cancel();
    _eventsController.close();
  }
}

final bayanPython = BayanPythonRuntime.instance;

String formatBytes(int bytes) {
  if (bytes <= 0) return '—';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb >= 100 ? 0 : 1)} KB';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(mb >= 100 ? 0 : 1)} MB';
}

// ───────── طابور تثبيت المكتبات (مشترك بين شاشة المكتبات وبطاقات الإخراج) ─────────
enum JobState { queued, running, done, failed }

// وزن تقديري لـ wheel لا يُعرف حجمه بعد، حتى لا يقفز الشريط عند اكتشافه
const int _unknownWheelBytes = 1 << 20;

/// عملية تثبيت واحدة. النسبة تصاعدية دائمًا:
/// حل الاعتماديات 0–10%، التنزيل 10–80% (موزّعًا حسب حجم كل الـwheels)،
/// التثبيت والتحقق 80–100%.
class LibJob {
  LibJob({required this.key, required this.spec, required this.name});

  final String key;
  final String spec;
  final String name;

  JobState state = JobState.queued;
  double progress = 0;
  String stage = ''; // resolve | download | install
  String reason = '';
  String details = '';
  String jobId = '';

  int _searches = 0;
  final Map<String, int> _expected = <String, int>{};
  final Map<String, int> _received = <String, int>{};

  bool get isLive => state == JobState.queued || state == JobState.running;

  void _raise(double v) {
    final capped = v > 1.0 ? 1.0 : v;
    if (capped > progress) progress = capped;
  }

  void _recomputeDownload() {
    var received = 0.0;
    var expected = 0.0;
    _expected.forEach((file, size) {
      final weight = size > 0 ? size : _unknownWheelBytes;
      final got = _received[file] ?? 0;
      expected += weight;
      received += got > weight ? weight : got;
    });
    if (expected <= 0) return;
    var ratio = received / expected;
    // لا نصل إلى 80% قبل أن تُعرف خطة التثبيت كاملة (قد تظهر اعتمادية جديدة)
    if (ratio > 0.97) ratio = 0.97;
    _raise(0.10 + 0.70 * ratio);
  }

  /// يطبّق حدث تقدم من بايثون. يرجع true إذا تغير ما يراه المستخدم.
  bool apply(BayanEvent e) {
    final beforeProgress = progress;
    final beforeStage = stage;
    switch (e.stage) {
      case 'start':
        stage = 'resolve';
        _raise(0.01);
        break;
      case 'search':
        _searches++;
        if (stage != 'download' && stage != 'install') stage = 'resolve';
        _raise(0.10 * (1 - 1 / (1 + 0.6 * _searches)));
        break;
      case 'wheel':
        stage = 'download';
        _expected[e.message] = e.received;
        _received.putIfAbsent(e.message, () => 0);
        _recomputeDownload();
        break;
      case 'wheel_cached':
        stage = 'download';
        final size = e.received > 0 ? e.received : 1;
        _expected[e.message] = size;
        _received[e.message] = size;
        _recomputeDownload();
        break;
      case 'download_start':
        stage = 'download';
        _expected.putIfAbsent(e.message, () => 0);
        _received.putIfAbsent(e.message, () => 0);
        _recomputeDownload();
        break;
      case 'download':
        stage = 'download';
        _received[e.message] = e.received;
        if (e.total > 0) {
          _expected[e.message] = e.total;
        } else {
          _expected.putIfAbsent(e.message, () => 0);
        }
        _recomputeDownload();
        break;
      case 'dependencies':
        stage = 'install';
        _raise(0.80);
        break;
      case 'verify':
      case 'install':
        stage = 'install';
        final total = e.total > 0 ? e.total : 1;
        var frac = (e.received + (e.stage == 'install' ? 0.5 : 0.0)) / total;
        if (frac > 0.98) frac = 0.98;
        _raise(0.80 + 0.20 * frac);
        break;
      case 'done':
        _raise(1.0);
        break;
      default:
        break;
    }
    return progress != beforeProgress || stage != beforeStage;
  }
}

/// سبب فشل مختصر بالعربية (النص الكامل يبقى في details).
String shortInstallReason(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return 'فشل التثبيت';
  if (t.contains('لا توجد wheel متوافقة')) return 'لا توجد نسخة تعمل على أندرويد';
  if (t.contains('لم يتم العثور على مكتبة')) return 'المكتبة غير موجودة في PyPI';
  if (t.contains('تعذر الاتصال')) return 'تعذر الاتصال بالإنترنت';
  if (t.contains('checksum')) return 'فشل التحقق من الملف المنزّل';
  if (t.contains('تم إيقاف التثبيت')) return 'تم إيقاف التثبيت';
  if (t.contains('هناك سكربت') || t.contains('أوقف السكربت')) {
    return 'أوقف السكربت الحالي أولاً';
  }
  final first = t.split('\n').first.trim();
  return first.length > 60 ? '${first.substring(0, 60)}…' : first;
}

class LibInstaller {
  LibInstaller._() {
    bayanPython.events.where((e) => e.channel == 'package').listen(_onEvent);
  }

  static final LibInstaller instance = LibInstaller._();

  final Map<String, LibJob> _jobs = <String, LibJob>{};
  final List<LibJob> _queue = <LibJob>[];
  final StreamController<int> _changes = StreamController<int>.broadcast();
  LibJob? _active;
  bool _pumping = false;
  bool _completed = false;
  String _lastError = '';
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _pendingNotify;

  int revision = 0;
  Stream<int> get changes => _changes.stream;

  LibJob? jobFor(String key) => _jobs[key];
  Iterable<LibJob> get jobs => _jobs.values;

  /// هناك عملية في الانتظار أو جارية.
  bool get busy => _jobs.values.any((j) => j.isLive);

  /// عمليات حية أو انتهت للتو (تبقى ثانيتين تقريبًا ليراها المستخدم).
  bool get hasLiveJobs =>
      _jobs.values.any((j) => j.isLive || j.state == JobState.done);

  /// true مرة واحدة بعد انتهاء عملية بنجاح (ليحدّث الطرف المستمع قائمة المثبّت).
  bool consumeCompleted() {
    final v = _completed;
    _completed = false;
    return v;
  }

  /// يضيف التثبيت إلى الطابور. تثبيت واحد فقط يعمل في كل مرة.
  LibJob enqueue(String spec) {
    final clean = spec.trim();
    final key = cleanPackageName(clean: clean);
    final existing = _jobs[key];
    if (existing != null && existing.isLive) return existing;
    final match = RegExp(r'^([A-Za-z0-9][A-Za-z0-9_.-]*)').firstMatch(clean);
    final job = LibJob(key: key, spec: clean, name: match?.group(1) ?? clean);
    _jobs[key] = job;
    _queue.add(job);
    _notify(now: true);
    unawaited(_pump());
    return job;
  }

  void retry(String key) {
    final old = _jobs[key];
    if (old == null || old.state != JobState.failed) return;
    enqueue(old.spec);
  }

  /// يلغي عملية ما زالت في الانتظار.
  void cancel(String key) {
    final job = _jobs[key];
    if (job == null || job.state != JobState.queued) return;
    _queue.remove(job);
    _jobs.remove(key);
    _notify(now: true);
  }

  /// يخفي عملية فاشلة أو منتهية.
  void dismiss(String key) {
    final job = _jobs[key];
    if (job == null || job.isLive) return;
    _jobs.remove(key);
    _notify(now: true);
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.removeAt(0);
        await _run(job);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(LibJob job) async {
    job.state = JobState.running;
    job.stage = 'resolve';
    job.jobId = bayanPython.newId('pkg');
    job._raise(0.01);
    _active = job;
    _lastError = '';
    _notify(now: true);
    try {
      await bayanPython.init();
      await bayanPython.installPackage(spec: job.spec, jobId: job.jobId);
      job._raise(1.0);
      job.state = JobState.done;
      _completed = true;
      Timer(const Duration(milliseconds: 2400), () {
        if (identical(_jobs[job.key], job) && job.state == JobState.done) {
          _jobs.remove(job.key);
          _notify(now: true);
        }
      });
    } catch (e) {
      final raw = errText(e);
      job.state = JobState.failed;
      job.details = raw.isNotEmpty ? raw : _lastError;
      job.reason = shortInstallReason(job.details);
    } finally {
      _active = null;
      _notify(now: true);
    }
  }

  void _onEvent(BayanEvent e) {
    final job = _active;
    if (job == null || e.jobId != job.jobId) return;
    if (e.type == 'error' || e.stage == 'error') {
      if (e.message.isNotEmpty) _lastError = e.message;
      return;
    }
    if (e.stage == 'rollback') return;
    if (job.apply(e)) _notify();
  }

  // إشعار الواجهة: فوري عند تغيّر الحالة، ومخفّف (≈ 60ms) أثناء تدفق التقدم
  void _notify({bool now = false}) {
    revision++;
    final t = DateTime.now();
    if (now || t.difference(_lastNotify).inMilliseconds >= 60) {
      _pendingNotify?.cancel();
      _pendingNotify = null;
      _lastNotify = t;
      if (!_changes.isClosed) _changes.add(revision);
      return;
    }
    _pendingNotify ??= Timer(const Duration(milliseconds: 60), () {
      _pendingNotify = null;
      _lastNotify = DateTime.now();
      if (!_changes.isClosed) _changes.add(revision);
    });
  }
}

final libInstaller = LibInstaller.instance;
