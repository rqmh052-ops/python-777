import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// إعدادات الخدمة. معرّف تطبيق الويب ليس سرّاً، ولا نضع أي سرّ داخل التطبيق.
const String bynuxGoogleWebClientId =
    '501306408801-thefnjkh78jm27nr3q4h0i6ose0vpehg.apps.googleusercontent.com';
const String bynuxCloudApiBase =
    'https://bayan-storage-api.aaro3498.workers.dev';
const int bynuxMaxScriptBytes = 1024 * 1024;

class BynuxSession extends ChangeNotifier {
  BynuxSession._();
  static final BynuxSession instance = BynuxSession._();

  final GoogleSignIn _google = GoogleSignIn.instance;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _events;
  GoogleSignInAccount? _user;
  bool _initializing = false;
  bool _initialized = false;
  bool _ready = false;
  String? _initializationError;
  Future<void>? _initializationFuture;

  GoogleSignInAccount? get user => _user;
  bool get ready => _ready;
  String? get initializationError => _initializationError;

  Future<void> initialize() {
    if (_initializationFuture != null) return _initializationFuture!;
    _initializationFuture = _initializeOnce();
    return _initializationFuture!;
  }

  Future<void> _initializeOnce() async {
    if (_initializing || _initialized) return;
    _initializing = true;
    try {
      await _google.initialize(serverClientId: bynuxGoogleWebClientId);
      _events = _google.authenticationEvents.listen(
        (event) {
          if (event is GoogleSignInAuthenticationEventSignIn) {
            _user = event.user;
            _initializationError = null;
            notifyListeners();
          } else if (event is GoogleSignInAuthenticationEventSignOut) {
            _user = null;
            notifyListeners();
          }
        },
        onError: (Object error) {
          _initializationError = _friendlyError(error);
          notifyListeners();
        },
      );
      _initialized = true;
      final attempt = _google.attemptLightweightAuthentication();
      if (attempt != null) {
        try {
          final restored = await attempt;
          if (restored != null) _user = restored;
        } catch (error) {
          _initializationError = _friendlyError(error);
        }
      }
    } catch (error) {
      _initializationError = _friendlyError(error);
    } finally {
      _initializing = false;
      _ready = true;
      notifyListeners();
    }
  }

  Future<void> signIn() async {
    await initialize();
    if (!_initialized) {
      throw StateError(_initializationError ?? 'تعذّر تجهيز تسجيل الدخول بجوجل.');
    }
    try {
      final account = await _google.authenticate();
      final token = account.authentication.idToken;
      if (token == null || token.isEmpty) {
        throw StateError('لم يصل رمز التحقق من جوجل. تحقّق من إعدادات معرّف التطبيق وبصمة التوقيع.');
      }
      _user = account;
      _initializationError = null;
      notifyListeners();
    } catch (error) {
      _initializationError = _friendlyError(error);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> signOut() async {
    try {
      await _google.signOut();
    } finally {
      _user = null;
      _initializationError = null;
      notifyListeners();
    }
  }

  bool _idTokenIsFresh(String? token) {
    if (token == null || token.isEmpty) return false;
    try {
      final parts = token.split('.');
      if (parts.length != 3) return false;
      final normalized = base64Url.normalize(parts[1]);
      final claims = jsonDecode(utf8.decode(base64Url.decode(normalized)));
      if (claims is! Map || claims['exp'] is! num) return false;
      final expiresAt = (claims['exp'] as num).toInt();
      // نحدّثه قبل الانتهاء بدقيقتين لتجنب انتهاءه أثناء طلب الملف.
      return expiresAt > DateTime.now().millisecondsSinceEpoch ~/ 1000 + 120;
    } catch (_) {
      return false;
    }
  }

  Future<String> idToken() async {
    var token = _user?.authentication.idToken;
    if (_idTokenIsFresh(token)) return token!;

    // رموز هوية جوجل تنتهي صلاحيتها؛ نحاول استعادة الجلسة بهدوء للحصول على رمز جديد
    // قبل مطالبة المستخدم بالتسجيل مرة أخرى.
    final attempt = _google.attemptLightweightAuthentication();
    if (attempt != null) {
      try {
        final restored = await attempt;
        if (restored != null) {
          _user = restored;
          token = restored.authentication.idToken;
          notifyListeners();
        }
      } catch (_) {
        // سنعرض رسالة واضحة أدناه بدلاً من تسريب تفاصيل الاستثناء.
      }
    }
    if (!_idTokenIsFresh(token)) {
      throw const CloudApiException(
          'انتهت جلسة التحقق. أعد تسجيل الدخول بحساب جوجل للمتابعة.');
    }
    return token!;
  }

  static String _friendlyError(Object error) {
    final message = error.toString().toLowerCase();
    if (message.contains('network') || message.contains('socket')) {
      return 'تحقّق من اتصال الإنترنت ثم حاول مرة أخرى.';
    }
    if (message.contains('canceled') || message.contains('cancelled')) {
      return 'تم إلغاء تسجيل الدخول.';
    }
    if (message.contains('clientconfiguration') || message.contains('developer_error')) {
      return 'إعدادات تسجيل جوجل غير مكتملة. يلزم التأكد من اسم الحزمة وبصمة مفتاح التوقيع في منصة جوجل.';
    }
    return 'تعذّر تسجيل الدخول بجوجل. تحقّق من الاتصال وإعدادات التطبيق ثم أعد المحاولة.';
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }
}

class CloudApiException implements Exception {
  const CloudApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class CloudFile {
  const CloudFile({
    required this.name,
    required this.size,
    required this.uploadedAt,
  });

  final String name;
  final int size;
  final DateTime? uploadedAt;

  factory CloudFile.fromJson(Map<String, dynamic> json) => CloudFile(
        name: json['name']?.toString() ?? 'script.py',
        size: (json['size'] as num?)?.toInt() ?? 0,
        uploadedAt: DateTime.tryParse(
          json['uploadedAt']?.toString() ??
              json['uploaded']?.toString() ??
              json['modified']?.toString() ??
              '',
        )?.toLocal(),
      );
}

class CloudProfile {
  const CloudProfile({
    required this.email,
    required this.createdAt,
    this.lastUpload,
  });

  final String email;
  final DateTime? createdAt;
  final CloudFile? lastUpload;

  factory CloudProfile.fromJson(Map<String, dynamic> json) {
    final rawLast = json['lastUpload'];
    return CloudProfile(
      email: json['email']?.toString() ?? '',
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '')?.toLocal(),
      lastUpload: rawLast is Map
          ? CloudFile.fromJson(Map<String, dynamic>.from(rawLast))
          : null,
    );
  }
}

class BynuxCloudApi {
  BynuxCloudApi._();
  static final BynuxCloudApi instance = BynuxCloudApi._();

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 20);

  Uri _uri(String path) => Uri.parse('$bynuxCloudApiBase$path');

  Future<HttpClientRequest> _open(String method, String path) async {
    final token = await BynuxSession.instance.idToken();
    final request = await _client.openUrl(method, _uri(path)).timeout(
          const Duration(seconds: 25),
        );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    return request;
  }

  Future<Map<String, dynamic>> _jsonRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final request = await _open(method, path);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
    }
    final response = await request.close().timeout(const Duration(seconds: 30));
    final raw = await utf8.decoder.bind(response).join();
    Map<String, dynamic> decoded = <String, dynamic>{};
    if (raw.trim().isNotEmpty) {
      try {
        final value = jsonDecode(raw);
        if (value is Map) decoded = Map<String, dynamic>.from(value);
      } catch (_) {
        // رسالة HTTP العامة أدناه تكفي إذا أعاد الخادم نصاً غير JSON.
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CloudApiException(
        _statusMessage(response.statusCode, decoded['error']?.toString()),
        statusCode: response.statusCode,
      );
    }
    if (decoded['ok'] == false) {
      throw CloudApiException(
          _statusMessage(response.statusCode, decoded['error']?.toString()),
          statusCode: response.statusCode);
    }
    return decoded;
  }

  Future<CloudProfile> getProfile() async {
    final json = await _jsonRequest('GET', '/v1/profile');
    return CloudProfile.fromJson(json);
  }

  Future<List<CloudFile>> listFiles() async {
    final json = await _jsonRequest('GET', '/v1/files');
    final rawFiles = json['files'] ?? json['items'];
    if (rawFiles is! List) {
      throw const CloudApiException('استجابة السحابة غير مكتملة. أعد نشر ملف الخادم المرفق ثم حاول مرة أخرى.');
    }
    return rawFiles
        .whereType<Map>()
        .map((item) => CloudFile.fromJson(Map<String, dynamic>.from(item)))
        .toList()
      ..sort((a, b) => (b.uploadedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(a.uploadedAt ?? DateTime.fromMillisecondsSinceEpoch(0)));
  }

  Future<CloudFile> uploadLocalScript(String path) async {
    final file = File(path);
    final name = path.replaceAll('\\', '/').split('/').last;
    if (!name.toLowerCase().endsWith('.py') ||
        name.contains('..') ||
        name.contains('/') ||
        name.contains('\\')) {
      throw const CloudApiException('اسم السكربت غير صالح للنسخ السحابي.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > bynuxMaxScriptBytes) {
      throw const CloudApiException('حجم السكربت أكبر من الحد المسموح وهو 1 ميجابايت.');
    }
    final request = await _open(
        'PUT', '/v1/files/${Uri.encodeComponent(name)}');
    request.headers.contentType = ContentType('text', 'x-python', charset: 'utf-8');
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close().timeout(const Duration(seconds: 30));
    final raw = await utf8.decoder.bind(response).join();
    Map<String, dynamic> json = <String, dynamic>{};
    if (raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) json = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    if (response.statusCode < 200 || response.statusCode >= 300 || json['ok'] == false) {
      throw CloudApiException(
        _statusMessage(response.statusCode, json['error']?.toString()),
        statusCode: response.statusCode,
      );
    }
    return CloudFile.fromJson(<String, dynamic>{
      'name': json['name'] ?? name,
      'size': json['size'] ?? bytes.length,
      'uploadedAt': json['uploadedAt'] ?? DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<List<int>> downloadFile(String name) async {
    final request = await _open('GET', '/v1/files/${Uri.encodeComponent(name)}');
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final raw = await utf8.decoder.bind(response).join();
      String? error;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) error = decoded['error']?.toString();
      } catch (_) {}
      throw CloudApiException(_statusMessage(response.statusCode, error),
          statusCode: response.statusCode);
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > bynuxMaxScriptBytes) {
        throw const CloudApiException('حجم الملف المستلم تجاوز الحد الآمن.');
      }
    }
    return bytes;
  }

  String _statusMessage(int status, String? serverMessage) {
    switch (status) {
      case 400:
        return 'تعذّر تنفيذ الطلب؛ بيانات الملف غير صالحة.';
      case 401:
        return 'تعذّر التحقق من حساب جوجل. سجّل الخروج ثم ادخل من جديد.';
      case 403:
        return 'ليس لديك صلاحية للوصول إلى هذا الملف.';
      case 404:
        return 'الملف غير موجود في السحابة.';
      case 413:
        return 'حجم الملف أكبر من الحد المسموح وهو 1 ميجابايت.';
      case 429:
        return 'وصلت إلى حد الطلبات المسموح مؤقتاً. حاول بعد قليل.';
      case 500:
      case 502:
      case 503:
        return 'خدمة السحابة تواجه مشكلة مؤقتة. حاول بعد قليل.';
      default:
        if (serverMessage != null && serverMessage.isNotEmpty) {
          return 'تعذّر إكمال العملية على السحابة.';
        }
        return 'تعذّر الاتصال بالسحابة. تحقّق من الإنترنت وحاول مرة أخرى.';
    }
  }
}

String bynuxFormatBytes(int bytes) {
  if (bytes < 1024) return '$bytes بايت';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} كيلوبايت';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} ميجابايت';
}

String bynuxFormatDate(DateTime? date) {
  if (date == null) return 'غير متوفر';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(date.day)}/${two(date.month)}/${date.year}  ${two(date.hour)}:${two(date.minute)}';
}

String bynuxFriendlyCloudError(Object error) =>
    error is CloudApiException ? error.message : 'تعذّر الاتصال بالسحابة. تحقّق من الإنترنت ثم حاول مرة أخرى.';
