import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'python_runtime.dart';
import 'store.dart';

enum ScriptRunnerState { idle, running, waitingForInput, finished, stopped, error }

/// بصمة نص السكربت: طول النص بالبايت + هاش FNV-1a بـ64 بت على UTF-8، بلا أي مكتبة خارجية.
/// تُرسل عند التشغيل وتُقارَن لاحقًا بنص المحرر ليتبدّل الزر بين «دخول» (النص كما هو)
/// و«تشغيل» (النص تغيّر). الضرب يلتف على 64 بت (Dart على أندرويد: int بـ64 بت)،
/// والتحويل إلى hex يتم بنصفين من 32 بت كي لا تظهر إشارة سالبة.
String textFingerprint(String text) {
  final bytes = utf8.encode(text);
  var h = 0xcbf29ce484222325; // FNV offset basis (64 بت)
  for (final b in bytes) {
    h = (h ^ b) * 0x100000001b3; // FNV prime (64 بت)
  }
  String half(int v) => (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  return '${bytes.length}-${half(h >> 32)}${half(h)}';
}

// نفس تطبيع store.readCode (إزالة BOM وتحويل CRLF) كي تتطابق البصمة مع نص المحرر
Future<String?> _fileFingerprint(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    var t = utf8.decode(bytes, allowMalformed: true);
    if (t.isNotEmpty && t.codeUnitAt(0) == 0xFEFF) t = t.substring(1);
    return textFingerprint(t.replaceAll('\r\n', '\n'));
  } catch (_) {
    return null;
  }
}

/// Keeps the Flutter UI independent from the native Chaquopy bridge.
/// One instance represents one real Python execution session.
class ScriptRunner {
  ScriptRunner({required this.scriptPath})
      : runId = bayanPython.newId('run') {
    _subscription = bayanPython.events
        .where((e) => e.channel == 'run' && e.runId == runId)
        .listen(_handleEvent, onError: _handleStreamError);
  }

  final String scriptPath;
  // يتجدد مع كل تشغيل حتى لا تتسرب أحداث تشغيل قديم إلى التشغيل الجديد.
  String runId;

  final _eventsController = StreamController<BayanEvent>.broadcast();
  late final StreamSubscription<BayanEvent> _subscription;

  ScriptRunnerState _state = ScriptRunnerState.idle;
  bool _disposed = false;
  Completer<void>? _finished;
  int? _exitCode;

  // ترقيم الأحداث: آخر رقم عالجناه، فلا يُعرض حدث مرتين ولا يضيع بين الجلب والبث الحي
  int _lastSeq = 0;
  // أثناء attach: الأحداث الحية تُحفظ هنا إلى أن تُعرض لقطة الجلسة أولًا
  bool _attaching = false;
  final List<BayanEvent> _pending = <BayanEvent>[];
  bool _truncated = false;

  ScriptRunnerState get state => _state;
  int? get exitCode => _exitCode;
  bool get isRunning => _state == ScriptRunnerState.running ||
      _state == ScriptRunnerState.waitingForInput;
  Stream<BayanEvent> get events => _eventsController.stream;
  Future<void>? get finished => _finished?.future;

  /// صحيح بعد attach إذا كان الأقدم من الإخراج قد قُطع من مخزن الجلسة.
  bool get truncated => _truncated;

  void _emit(BayanEvent event) {
    if (!_eventsController.isClosed) _eventsController.add(event);
  }

  void _handleEvent(BayanEvent event) {
    if (_disposed) return;
    if (_attaching) {
      _pending.add(event);
      return;
    }
    _process(event);
  }

  void _process(BayanEvent event) {
    final seq = event.seq;
    if (seq > 0) {
      if (seq <= _lastSeq) return; // رأيناه (من اللقطة مثلًا)
      _lastSeq = seq;
    }
    switch (event.type) {
      case 'started':
        _state = ScriptRunnerState.running;
        break;
      case 'input':
        _state = ScriptRunnerState.waitingForInput;
        break;
      case 'stdout':
      case 'stderr':
        // Keep the current state; output can arrive between state events.
        break;
      case 'error':
        _state = ScriptRunnerState.error;
        break;
      case 'state':
        switch (event.text) {
          case 'running':
            _state = ScriptRunnerState.running;
            break;
          case 'stopped':
            _state = ScriptRunnerState.stopped;
            break;
          case 'finished':
            _state = ScriptRunnerState.finished;
            break;
          case 'error':
            _state = ScriptRunnerState.error;
            break;
        }
        break;
      case 'exit':
        _exitCode = event.exitCode;
        if (event.exitCode == 130) {
          _state = ScriptRunnerState.stopped;
        } else if (event.exitCode == 0) {
          _state = ScriptRunnerState.finished;
        } else {
          _state = ScriptRunnerState.error;
        }
        final completer = _finished;
        _finished = null;
        if (completer != null && !completer.isCompleted) completer.complete();
        break;
    }
    _emit(event);
  }

  void _handleStreamError(Object error, StackTrace stack) {
    if (_disposed) return;
    _state = ScriptRunnerState.error;
    if (!_eventsController.isClosed) _eventsController.addError(error, stack);
    final completer = _finished;
    _finished = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  /// يتبنّى جلسة قائمة (حيّة أو منتهية) بدل بدء تشغيل جديد.
  /// يبث أحداثها المحفوظة أولًا (بعلامة replay)، ثم الأحداث الحية التي وصلت أثناء الجلب،
  /// مع إسقاط ما رقمه ≤ lastSeq. يرجع false إذا لم تعد الجلسة موجودة.
  Future<bool> attach(String existingRunId) async {
    if (_disposed) return false;
    runId = existingRunId;
    _exitCode = null;
    _lastSeq = 0;
    _truncated = false;
    _pending.clear();
    _attaching = true;
    RunSnapshot? snapshot;
    try {
      snapshot = await bayanPython.runsAttach(existingRunId);
    } catch (error, stack) {
      _attaching = false;
      _pending.clear();
      _state = ScriptRunnerState.error;
      if (!_eventsController.isClosed) _eventsController.addError(error, stack);
      return false;
    }
    if (_disposed || snapshot == null) {
      _attaching = false;
      _pending.clear();
      if (!_disposed) _state = ScriptRunnerState.idle;
      return false;
    }
    _truncated = snapshot.truncated;
    if (snapshot.truncated) {
      _emit(BayanEvent(<String, dynamic>{
        'channel': 'run',
        'type': 'truncated',
        'runId': existingRunId,
        'replay': true,
      }));
    }
    for (final e in snapshot.events) {
      _process(BayanEvent(<String, dynamic>{...e.raw, 'replay': true}));
    }
    if (snapshot.lastSeq > _lastSeq) _lastSeq = snapshot.lastSeq;
    _applySummary(snapshot.summary);
    final pending = List<BayanEvent>.of(_pending);
    _pending.clear();
    _attaching = false;
    for (final e in pending) {
      _process(e);
    }
    return true;
  }

  // حالة الجلسة وقت اللقطة هي المرجع (مثلًا بعد إرسال الإدخال لا يصل حدث يلغي «ينتظر»)
  void _applySummary(RunSummary s) {
    switch (s.status) {
      case RunStatus.running:
        _state = ScriptRunnerState.running;
        break;
      case RunStatus.waiting:
        _state = ScriptRunnerState.waitingForInput;
        break;
      case RunStatus.finished:
        _state = ScriptRunnerState.finished;
        _exitCode ??= s.exitCode;
        break;
      case RunStatus.stopped:
        _state = ScriptRunnerState.stopped;
        _exitCode ??= s.exitCode;
        break;
      case RunStatus.error:
        _state = ScriptRunnerState.error;
        _exitCode ??= s.exitCode;
        break;
    }
    // جلسة حيّة: حدث exit القادم يُنهي الانتظار في waitForFinish
    if (s.isLive && _finished == null) _finished = Completer<void>();
  }

  Future<void> start() async {
    if (_disposed) return;
    if (isRunning) return;
    _exitCode = null;
    _lastSeq = 0;
    _truncated = false;
    _attaching = false;
    _pending.clear();
    runId = bayanPython.newId('run');
    _finished = Completer<void>();
    _state = ScriptRunnerState.running;
    try {
      await bayanPython.init();
      final hash = await _fileFingerprint(scriptPath);
      await bayanPython.run(runId: runId, scriptPath: scriptPath, textHash: hash);
    } catch (error, stack) {
      _state = ScriptRunnerState.error;
      if (!_eventsController.isClosed) {
        _eventsController.addError(error, stack);
      }
      final completer = _finished;
      _finished = null;
      if (completer != null && !completer.isCompleted) completer.complete();
      rethrow;
    }
  }

  Future<void> sendInput(String text) async {
    if (_disposed || !isRunning) return;
    await bayanPython.sendInput(runId: runId, text: text);
    _state = ScriptRunnerState.running;
    runHub.noteInputSent(runId);
  }

  Future<void> stop() async {
    if (_disposed || !isRunning) return;
    await bayanPython.stop(runId: runId);
  }

  Future<void> waitForFinish({Duration timeout = const Duration(seconds: 2)}) async {
    final pending = finished;
    if (pending == null) return;
    try {
      await pending.timeout(timeout);
    } catch (_) {
      // A Python call blocked in native I/O can outlive the UI wait window.
    }
  }

  Future<void> restart() async {
    await stop();
    await waitForFinish();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  /// يفصل الاستماع فقط. السكربت يكمل شغله، والإيقاف يكون بزر «إيقاف» أو «إيقاف الكل».
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final completer = _finished;
    _finished = null;
    if (completer != null && !completer.isCompleted) completer.complete();
    _pending.clear();
    await _subscription.cancel();
    await _eventsController.close();
  }
}

// ───────── النموذج الحي للجلسات (RunHub) ─────────

/// جلسة سكربت واحدة كما يعرفها النموذج الحي.
class RunInfo {
  RunInfo({
    required this.runId,
    required this.scriptPath,
    required this.status,
    required this.startedAt,
    this.endedAt,
    this.exitCode,
    this.textHash,
  });

  factory RunInfo.fromSummary(RunSummary s) => RunInfo(
        runId: s.runId,
        scriptPath: s.scriptPath,
        status: s.status,
        startedAt: s.startedAt,
        endedAt: s.endedAt,
        exitCode: s.exitCode,
        textHash: s.textHash,
      );

  String runId;
  String scriptPath;
  RunStatus status;
  DateTime startedAt;
  DateTime? endedAt;
  int? exitCode;
  String? textHash;

  bool get isLive => status == RunStatus.running || status == RunStatus.waiting;
}

/// يعرف حال كل سكربت (للنقطة الملونة وزر المحرر) ويسجّل «آخر تشغيل» عند انتهاء أي تشغيل،
/// حتى لو كانت شاشة الإخراج مغلقة. يقرأ runs.list عند الإقلاع ويتابع الأحداث بعدها.
class RunHub extends ChangeNotifier {
  RunHub._();

  static final RunHub instance = RunHub._();

  final Map<String, RunInfo> _byPath = <String, RunInfo>{}; // مسار السكربت ← جلسته
  final Set<String> _recorded = <String>{}; // تشغيلات سُجّل «آخر تشغيل» لها
  final Set<String> _retired = <String>{}; // تشغيلات استُبدلت بتشغيل أحدث لنفس السكربت
  StreamSubscription<BayanEvent>? _sub;
  Future<void>? _refreshing;
  Timer? _ticker;
  bool _started = false;

  /// مؤقت واحد مشترك: يزيد كل ثانية، ويعمل فقط وقت وجود سكربت يعمل.
  final ValueNotifier<int> clock = ValueNotifier<int>(0);

  RunInfo? infoFor(String scriptPath) => _byPath[scriptPath];

  RunInfo? get liveRun {
    for (final r in _byPath.values) {
      if (r.isLive) return r;
    }
    return null;
  }

  bool get hasLive => liveRun != null;

  Future<void> init() async {
    if (_started) return;
    _started = true;
    _sub = bayanPython.events
        .where((e) => e.channel == 'run')
        .listen(_onEvent, onError: (Object _) {});
    await refresh();
  }

  /// إعادة قراءة runs.list (عند الإقلاع، أو وصول حدث لتشغيل لا نعرفه، أو العودة للتطبيق).
  Future<void> refresh() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _doRefresh() async {
    List<RunSummary> list;
    try {
      list = await bayanPython.runsList();
    } catch (e) {
      debugPrint('RunHub.refresh: $e');
      return;
    }
    _apply(list);
    // مصالحة «آخر تشغيل»: من وقت نهاية كل جلسة منتهية
    for (final info in _byPath.values.toList()) {
      _record(info);
    }
  }

  void _apply(List<RunSummary> list) {
    final next = <String, RunInfo>{};
    for (final s in list) {
      final old = _byPath[s.scriptPath];
      if (old != null &&
          ((old.runId == s.runId && !old.isLive && s.isLive) || // انتهت عندنا قبل وصول القراءة
              old.startedAt.isAfter(s.startedAt))) {
        // تشغيل أحدث بدأ بعد القراءة
        next[s.scriptPath] = old;
      } else {
        next[s.scriptPath] = RunInfo.fromSummary(s);
      }
    }
    // جلسة حيّة وُلدت من حدث ولم تظهر في قراءة أقدم منها
    for (final e in _byPath.entries) {
      if (!next.containsKey(e.key) && e.value.isLive) next[e.key] = e.value;
    }
    _byPath
      ..clear()
      ..addAll(next);
    _syncTicker();
    notifyListeners();
  }

  RunInfo? _findByRunId(String runId) {
    for (final r in _byPath.values) {
      if (r.runId == runId) return r;
    }
    return null;
  }

  void _onEvent(BayanEvent e) {
    if (e.runId.isEmpty || _retired.contains(e.runId)) return;
    if (e.type == 'started') {
      final path = e.scriptPath;
      if (path.isEmpty) {
        unawaited(refresh());
        return;
      }
      final old = _byPath[path];
      if (old != null && old.runId != e.runId) _retired.add(old.runId);
      _byPath[path] = RunInfo(
        runId: e.runId,
        scriptPath: path,
        status: RunStatus.running,
        startedAt: DateTime.now(),
        // بصمة النص تصل مع الحدث نفسه: زر المحرر يعرف «دخول» فور البدء بلا انتظار runs.list
        textHash: e.textHash,
      );
      _syncTicker();
      notifyListeners();
      return;
    }
    final info = _findByRunId(e.runId);
    if (info == null) {
      // تشغيل لا نعرفه: نعيد قراءة القائمة
      unawaited(refresh());
      return;
    }
    var changed = false;
    switch (e.type) {
      case 'input':
        if (info.status != RunStatus.waiting) {
          info.status = RunStatus.waiting;
          changed = true;
        }
        break;
      case 'stdout':
      case 'stderr':
        // السكربت لا يطبع وهو ينتظر إدخالًا، فالإخراج يعني أن الإدخال وصل
        changed = _resume(info);
        break;
      case 'state':
        if (e.text == 'running') changed = _resume(info);
        break;
      case 'exit':
        info.exitCode = e.exitCode;
        info.endedAt = DateTime.now();
        info.status = e.exitCode == 0
            ? RunStatus.finished
            : (e.exitCode == 130 ? RunStatus.stopped : RunStatus.error);
        changed = true;
        _record(info);
        break;
    }
    if (changed) {
      _syncTicker();
      notifyListeners();
    }
  }

  bool _resume(RunInfo info) {
    if (info.status != RunStatus.waiting) return false;
    info.status = RunStatus.running;
    return true;
  }

  /// يُستدعى من ScriptRunner بعد إرسال إدخال المستخدم.
  void noteInputSent(String runId) {
    final info = _findByRunId(runId);
    if (info != null && _resume(info)) notifyListeners();
  }

  // «آخر تشغيل»: مرة واحدة لكل تشغيل منتهٍ، بوقت نهايته الفعلي
  void _record(RunInfo info) {
    if (info.isLive || !_recorded.add(info.runId)) return;
    final script = _scriptAt(info.scriptPath);
    if (script == null) {
      _recorded.remove(info.runId); // الملف غير معروف الآن، تُعاد المحاولة في القراءة التالية
      return;
    }
    unawaited(store.markRun(script, at: info.endedAt ?? info.startedAt));
  }

  Script? _scriptAt(String path) {
    for (final s in scripts.value) {
      if (s.path == path) return s;
    }
    return null;
  }

  void _syncTicker() {
    if (hasLive) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => clock.value++);
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// بعد إعادة تسمية سكربت: تنتقل جلسته إلى الاسم الجديد.
  Future<void> moved(String from, String to) async {
    try {
      await bayanPython.runsMove(from: from, to: to);
    } catch (e) {
      debugPrint('RunHub.moved: $e');
    }
    final info = _byPath.remove(from);
    if (info != null) {
      info.scriptPath = to;
      _byPath[to] = info;
      notifyListeners();
    }
  }

  /// بعد حذف سكربت: تُحذف جلسته المنتهية (الشغّالة لا تُمس).
  Future<void> discarded(String scriptPath) async {
    try {
      await bayanPython.runsDiscard(scriptPath);
    } catch (e) {
      debugPrint('RunHub.discarded: $e');
    }
    final info = _byPath[scriptPath];
    if (info != null && !info.isLive) {
      _byPath.remove(scriptPath);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    clock.dispose();
    super.dispose();
  }
}

final runHub = RunHub.instance;

// ───────── مكان التشغيل الوحيد (RunSlot) ─────────

/// كل تشغيل جديد يمر من هنا. سكربت واحد في كل مرة الآن؛ لاحقًا تعدد السكربتات
/// يتم بتغيير هذا الجزء فقط (الواجهة تسأل: هل يوجد مكان؟).
class RunSlot {
  RunSlot._();

  static final RunSlot instance = RunSlot._();

  /// أقصى انتظار بعد الإيقاف. سكربت عالق في عملية شبكة أو ملف قد لا يتوقف.
  static const Duration stopWait = Duration(seconds: 2);

  /// السكربت الذي يشغل المكان الآن (null = المكان فارغ).
  RunInfo? get occupant => runHub.liveRun;

  /// يوقف الشاغل وينتظر حتى ثانيتين تقريبًا. true = صار المكان فارغًا.
  Future<bool> release() async {
    final current = runHub.liveRun;
    if (current == null) return true;
    try {
      await bayanPython.stop(runId: current.runId);
    } catch (e) {
      debugPrint('RunSlot.release: $e');
    }
    final deadline = DateTime.now().add(stopWait);
    while (runHub.hasLive && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    return !runHub.hasLive;
  }
}

final runSlot = RunSlot.instance;
