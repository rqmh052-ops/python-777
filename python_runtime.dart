import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

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
