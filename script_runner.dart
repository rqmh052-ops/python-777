import 'dart:async';

import 'python_runtime.dart';

enum ScriptRunnerState { idle, running, waitingForInput, finished, stopped, error }

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
  final String runId;

  final _eventsController = StreamController<BayanEvent>.broadcast();
  late final StreamSubscription<BayanEvent> _subscription;

  ScriptRunnerState _state = ScriptRunnerState.idle;
  bool _disposed = false;
  Completer<void>? _finished;
  int? _exitCode;

  ScriptRunnerState get state => _state;
  int? get exitCode => _exitCode;
  bool get isRunning => _state == ScriptRunnerState.running ||
      _state == ScriptRunnerState.waitingForInput;
  Stream<BayanEvent> get events => _eventsController.stream;
  Future<void>? get finished => _finished?.future;

  void _emit(BayanEvent event) {
    if (!_eventsController.isClosed) _eventsController.add(event);
  }

  void _handleEvent(BayanEvent event) {
    if (_disposed) return;
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

  Future<void> start() async {
    if (_disposed) return;
    if (isRunning) return;
    _exitCode = null;
    _finished = Completer<void>();
    _state = ScriptRunnerState.running;
    try {
      await bayanPython.init();
      await bayanPython.run(runId: runId, scriptPath: scriptPath);
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

  Future<void> dispose() async {
    if (_disposed) return;
    try {
      await stop();
    } catch (_) {}
    await waitForFinish(timeout: const Duration(milliseconds: 450));
    _disposed = true;
    await _subscription.cancel();
    await _eventsController.close();
  }
}
