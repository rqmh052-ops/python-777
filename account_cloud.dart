import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// إعدادات الخدمة. معرّف تطبيق الويب ليس سرّاً، ولا نضع أي سرّ داخل التطبيق.
const String bynuxGoogleWebClientId =
    '501306408801-thefnjkh78jm27nr3q4h0i6ose0vpehg.apps.googleusercontent.com';
const String bynuxCloudApiBase =
    'https://bayan-storage-api.aaro3498.workers.dev';
/// حد حجم السكربت في التطبيق (بايت): أقل بقليل من حد السيرفر (1 MiB) لتفادي أي احتكاك.
/// يطابق kMaxScriptBytes في store.dart.
const int bynuxMaxScriptBytes = 1000000;

/// حد السيرفر الفعلي (MAX_FILE_BYTES في worker.js). يُستعمل لفحص ما يُنزَّل من السحابة فقط.
const int bynuxServerMaxBytes = 1024 * 1024;

/// رقم إصدار نصوص سياسة الخصوصية وشروط الاستخدام.
/// تغيير هذا الثابت مستقبلاً يعيد طلب الموافقة تلقائياً لكل الحسابات على الجهاز.
const String bynuxLegalTermsVersion = '7.1_2026-10-15';

/// هوية المستخدم المحفوظة على الجهاز.
class BynuxUser {
  const BynuxUser({required this.id, required this.email, this.displayName});

  final String id;
  final String email;
  final String? displayName;

  factory BynuxUser.fromGoogle(GoogleSignInAccount account) => BynuxUser(
        id: account.id,
        email: account.email,
        displayName: account.displayName,
      );

  Map<String, Object?> toJson() =>
      <String, Object?>{'id': id, 'email': email, 'name': displayName};

  static BynuxUser? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    return BynuxUser(
      id: id,
      email: raw['email']?.toString() ?? '',
      displayName: raw['name']?.toString(),
    );
  }
}

/// رمز جلسة طويل الأمد يصدره الخادم بعد التحقق من رمز جوجل مرة واحدة.
class CloudSessionGrant {
  const CloudSessionGrant({required this.token, required this.expiresAt});

  final String token;
  final DateTime expiresAt;
}

/// لقطة الحالة المحفوظة على الجهاز: المستخدم، رمز الجلسة، والموافقات.
/// تُحفظ دائمًا في مكانين مستقلين (SharedPreferences + ملف داخل مجلد التطبيق)
/// فإذا فشل أحدهما أو ضاع، يكفي الآخر.
class _SessionSnapshot {
  _SessionSnapshot({
    this.user,
    this.session,
    this.sessionExp,
    Set<String>? consents,
    this.signedOut = false,
    this.savedAt = 0,
  }) : consents = consents ?? <String>{};

  final BynuxUser? user;
  final String? session;
  final DateTime? sessionExp;
  final Set<String> consents;

  /// true بعد ضغطة «تسجيل الخروج» الصريحة: نمنع الاستعادة الهادئة من جوجل
  /// حتى لا يعود الحساب وحده إذا تعذّر على جوجل نفسه تسجيل الخروج.
  final bool signedOut;
  final int savedAt;

  String encode() => jsonEncode(<String, Object?>{
        'v': 2,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'user': user?.toJson(),
        'session': session,
        'sessionExp': sessionExp?.millisecondsSinceEpoch,
        'consents': consents.toList(),
        'signedOut': signedOut,
      });

  static _SessionSnapshot? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return null;
      final token = data['session']?.toString();
      final expMs = data['sessionExp'];
      final consentsRaw = data['consents'];
      return _SessionSnapshot(
        user: BynuxUser.tryParse(data['user']),
        session: (token == null || token.isEmpty) ? null : token,
        sessionExp: expMs is num
            ? DateTime.fromMillisecondsSinceEpoch(expMs.toInt())
            : null,
        consents: consentsRaw is List
            ? consentsRaw.map((e) => e.toString()).toSet()
            : <String>{},
        signedOut: data['signedOut'] == true,
        savedAt: (data['savedAt'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// صيغة النسخة السابقة (bynux_session_v1) للترحيل بدون أن يخسر أحد جلسته.
  static _SessionSnapshot? tryDecodeLegacy(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return null;
      final user = BynuxUser.tryParse(data['user']);
      if (user == null) return null;
      final token = data['session']?.toString();
      final expMs = data['sessionExp'];
      return _SessionSnapshot(
        user: user,
        session: (token == null || token.isEmpty) ? null : token,
        sessionExp: expMs is num
            ? DateTime.fromMillisecondsSinceEpoch(expMs.toInt())
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// تخزين مزدوج: SharedPreferences + ملف JSON ذرّي داخل مجلد التطبيق الخاص.
/// القراءة تأخذ الأحدث من الاثنين وتدمج الموافقات، والكتابة تتم على الاثنين دائمًا.
class _SessionStore {
  static const String _prefsKey = 'bynux_session_v2';
  static const String _legacyPrefsKey = 'bynux_session_v1';
  static const String _legacyConsentPrefix =
      'bynux_consent_${bynuxLegalTermsVersion}_';
  static const String _fileName = 'bynux_session_v2.json';

  Future<void> _chain = Future<void>.value();

  Future<File?> _file() async {
    try {
      final dir = await getApplicationSupportDirectory();
      if (!await dir.exists()) await dir.create(recursive: true);
      return File('${dir.path}/$_fileName');
    } catch (error) {
      debugPrint('session store: no support dir: $error');
      return null;
    }
  }

  Future<_SessionSnapshot> load() async {
    final candidates = <_SessionSnapshot>[];
    final consents = <String>{};

    try {
      final prefs = await SharedPreferences.getInstance();
      try {
        await prefs.reload();
      } catch (_) {}
      final current = _SessionSnapshot.tryDecode(prefs.getString(_prefsKey));
      if (current != null) candidates.add(current);
      final legacy =
          _SessionSnapshot.tryDecodeLegacy(prefs.getString(_legacyPrefsKey));
      if (legacy != null) candidates.add(legacy);
      for (final key in prefs.getKeys()) {
        if (key.startsWith(_legacyConsentPrefix) &&
            prefs.getBool(key) == true) {
          final id = key.substring(_legacyConsentPrefix.length);
          if (id.isNotEmpty) consents.add(BynuxSession.consentKeyForId(id));
        }
      }
    } catch (error) {
      debugPrint('session store: prefs read failed: $error');
    }

    try {
      final file = await _file();
      if (file != null && await file.exists()) {
        final fromFile = _SessionSnapshot.tryDecode(await file.readAsString());
        if (fromFile != null) candidates.add(fromFile);
      }
    } catch (error) {
      debugPrint('session store: file read failed: $error');
    }

    _SessionSnapshot? best;
    for (final candidate in candidates) {
      consents.addAll(candidate.consents);
      if (best == null || candidate.savedAt >= best.savedAt) best = candidate;
    }
    return _SessionSnapshot(
      user: best?.user,
      session: best?.session,
      sessionExp: best?.sessionExp,
      consents: consents,
      signedOut: best?.signedOut ?? false,
      savedAt: best?.savedAt ?? 0,
    );
  }

  /// الكتابات تتسلسل حتى لا تتداخل، ويُكتب الاثنان دائمًا.
  Future<void> save(_SessionSnapshot snapshot) {
    final encoded = snapshot.encode();
    final run = _chain.then((_) => _saveNow(encoded));
    _chain = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _saveNow(String encoded) async {
    var okPrefs = false;
    var okFile = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      okPrefs = await prefs.setString(_prefsKey, encoded);
    } catch (error) {
      debugPrint('session store: prefs write failed: $error');
    }
    try {
      final file = await _file();
      if (file != null) {
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(encoded, flush: true);
        await tmp.rename(file.path);
        okFile = true;
      }
    } catch (error) {
      debugPrint('session store: file write failed: $error');
    }
    if (!okPrefs && !okFile) {
      debugPrint('session store: BOTH layers failed to save the session');
    }
  }
}

class BynuxSession extends ChangeNotifier {
  BynuxSession._();
  static final BynuxSession instance = BynuxSession._();

  /// مفتاح موافقة الحساب (مرتبط بإصدار نصوص الشروط). يُطابَق بالمعرّف أو بالبريد.
  static String consentKeyForId(String id) =>
      '$bynuxLegalTermsVersion|id:$id';
  static String consentKeyForEmail(String email) =>
      '$bynuxLegalTermsVersion|mail:${email.trim().toLowerCase()}';

  final _SessionStore _store = _SessionStore();
  final GoogleSignIn _google = GoogleSignIn.instance;
  final Set<String> _consents = <String>{};
  StreamSubscription<GoogleSignInAuthenticationEvent>? _events;
  GoogleSignInAccount? _account;
  BynuxUser? _user;
  String? _sessionToken;
  DateTime? _sessionExpiresAt;
  String? _pendingGoogleToken;
  bool _consented = false;
  bool _signedOut = false;
  bool _googleReady = false;
  bool _ready = false;
  bool _signingIn = false;
  bool _obtainingSession = false;
  bool _sessionUnsupported = false;
  String? _initializationError;
  Future<void>? _initializationFuture;

  BynuxUser? get user => _user;
  bool get ready => _ready;
  bool get hasConsented => _user != null && _consented;
  String? get initializationError => _initializationError;

  bool get _sessionIsValid {
    final token = _sessionToken;
    final expiresAt = _sessionExpiresAt;
    if (token == null || token.isEmpty || expiresAt == null) return false;
    return expiresAt.isAfter(DateTime.now().add(const Duration(minutes: 1)));
  }

  bool _isConsentedFor(String id, String email) {
    if (id.isNotEmpty && _consents.contains(consentKeyForId(id))) return true;
    if (email.trim().isNotEmpty &&
        _consents.contains(consentKeyForEmail(email))) {
      return true;
    }
    return false;
  }

  Future<void> _persist() => _store.save(_SessionSnapshot(
        user: _user,
        session: _sessionToken,
        sessionExp: _sessionExpiresAt,
        consents: Set<String>.of(_consents),
        signedOut: _signedOut,
      ));

  /// يقرأ الحالة المحفوظة (بدون شبكة) من المكانين ويدمجهما. يُستدعى قبل runApp،
  /// فتظهر من أول إطار: الرئيسية (أو الموافقة) إن كان هناك حساب محفوظ، وإلا شاشة الدخول
  /// مباشرة، بلا دوران انتظار وبلا أي نافذة جوجل تظهر وحدها.
  Future<void> loadSaved() async {
    if (_ready) return;
    try {
      final snap = await _store.load();
      _consents
        ..clear()
        ..addAll(snap.consents);
      _signedOut = snap.signedOut;
      _user = snap.user;
      _sessionToken = snap.session;
      _sessionExpiresAt = snap.sessionExp;
      final current = _user;
      if (current != null) {
        _consented = _isConsentedFor(current.id, current.email);
      }
    } catch (error) {
      debugPrint('loadSaved failed: $error');
      _user = null;
      _sessionToken = null;
      _sessionExpiresAt = null;
      _consented = false;
    }
    _ready = true;
    notifyListeners();
  }

  /// يحفظ موافقة الحساب الحالي على المكانين ويستكمل إنشاء جلسة الخادم المؤجّلة.
  Future<void> acceptConsent() async {
    final current = _user;
    if (current == null) return;
    _consents.add(consentKeyForId(current.id));
    if (current.email.trim().isNotEmpty) {
      _consents.add(consentKeyForEmail(current.email));
    }
    _consented = true;
    notifyListeners();
    await _persist();
    final pendingToken = _pendingGoogleToken ?? _freshGoogleToken();
    _pendingGoogleToken = null;
    if (!_sessionIsValid && pendingToken != null) {
      // الجلسة الطويلة هي ما يمنع طلب الدخول لاحقًا، فنحاول إنشاءها هنا بإصرار.
      await _obtainSession(pendingToken, attempts: 3)
          .timeout(const Duration(seconds: 15), onTimeout: () {});
    }
  }

  /// تهيئة مكتبة جوجل فقط (سريعة). لا شيء ظاهر ينتظرها.
  Future<void> initialize() => _initializationFuture ??= _initializeOnce();

  Future<void> _initializeOnce() async {
    try {
      await _google.initialize(serverClientId: bynuxGoogleWebClientId);
      _events = _google.authenticationEvents.listen(
        (event) {
          // نتجاهل حدث الخروج القادم من المكتبة عمدًا: الخروج الوحيد المعتمد هو
          // ضغطة «تسجيل الخروج» من المستخدم، حتى لا تضيع الجلسة بسبب حدث عابر.
          if (event is GoogleSignInAuthenticationEventSignIn &&
              !_signingIn &&
              !_signedOut) {
            unawaited(_adoptAccount(event.user));
          }
        },
        onError: (Object error) {
          _initializationError = _friendlyError(error);
          notifyListeners();
        },
      );
      _googleReady = true;
    } catch (error) {
      _initializationError = _friendlyError(error);
      // نسمح بإعادة المحاولة عند ضغط زر الدخول التالي.
      _initializationFuture = null;
      notifyListeners();
    }
  }

  /// لا استعادة هادئة من جوجل إطلاقًا: كانت تُظهر نافذة «حسابات محددة» وحدها وتؤخر الفتح.
  /// الحساب يُحفظ محليًا، وصلاحية السحابة يحفظها رمز جلسة الخادم (180 يومًا).
  /// الدالة تبقى لأن الشاشة تستدعيها؛ تجهّز مكتبة جوجل فقط ليكون زر الدخول سريعًا.
  Future<void> restoreInBackground() => initialize();

  /// يعتمد حسابًا جاء من جوجل (استعادة هادئة أو حدث) ويحفظه على المكانين.
  Future<void> _adoptAccount(GoogleSignInAccount account, {bool mint = true}) async {
    _account = account;
    final next = BynuxUser.fromGoogle(account);
    final current = _user;
    final sameAccount = current != null &&
        (current.id == next.id ||
            (current.email.trim().isNotEmpty &&
                current.email.trim().toLowerCase() ==
                    next.email.trim().toLowerCase()));
    if (!sameAccount) {
      // رمز الجلسة المحفوظ يخص حسابًا آخر.
      _sessionToken = null;
      _sessionExpiresAt = null;
    }
    _user = next;
    _signedOut = false;
    _consented = _isConsentedFor(next.id, next.email);
    _initializationError = null;
    _ready = true;
    notifyListeners();
    await _persist();
    if (mint && _consented && !_sessionIsValid) {
      final google = _freshGoogleToken();
      if (google != null) unawaited(_obtainSession(google));
    }
  }

  Future<void> signIn() async {
    await initialize();
    if (!_googleReady) {
      throw StateError(_initializationError ?? 'تعذّر تجهيز تسجيل الدخول بجوجل.');
    }
    _signingIn = true;
    try {
      final account = await _google.authenticate();
      final token = account.authentication.idToken;
      if (token == null || token.isEmpty) {
        throw StateError('لم يصل رمز التحقق من جوجل. تحقّق من إعدادات معرّف التطبيق وبصمة التوقيع.');
      }
      _signedOut = false;
      final alreadyConsented = _isConsentedFor(account.id, account.email);
      if (alreadyConsented) {
        // الحساب وافق مسبقًا على هذا الجهاز: ننشئ جلسة الخادم مباشرة.
        final grant = await _mintSession(token, attempts: 2);
        _pendingGoogleToken = null;
        await _adoptAccount(account, mint: false);
        if (grant != null) {
          _sessionToken = grant.token;
          _sessionExpiresAt = grant.expiresAt;
          await _persist();
        }
      } else {
        // الحساب لم يوافق بعد: نؤجّل إنشاء جلسة الخادم وأي اتصال بالسحابة إلى ما بعد الموافقة.
        _pendingGoogleToken = token;
        await _adoptAccount(account, mint: false);
      }
    } catch (error) {
      _initializationError = _friendlyError(error);
      notifyListeners();
      rethrow;
    } finally {
      _signingIn = false;
    }
  }

  Future<void> signOut() async {
    final token = _sessionToken;
    _user = null;
    _account = null;
    _sessionToken = null;
    _sessionExpiresAt = null;
    _pendingGoogleToken = null;
    _consented = false;
    _signedOut = true;
    _initializationError = null;
    await _persist();
    notifyListeners();
    if (token != null) unawaited(BynuxCloudApi.instance.revokeSession(token));
    try {
      await initialize();
      if (_googleReady) await _google.signOut();
    } catch (_) {
      // الخروج المحلي تم؛ فشل جوجل لا يمنعه.
    }
  }

  /// يستبدل رمز جوجل (ساعة واحدة) برمز جلسة طويل من الخادم. يُرجع null عند الفشل.
  /// إن كان الخادم قديمًا (لم يُعاد نشر worker.js) لا نعيد المحاولة في هذا التشغيل.
  Future<CloudSessionGrant?> _mintSession(String googleToken, {int attempts = 1}) async {
    if (_sessionUnsupported) return null;
    for (var i = 0; i < attempts; i++) {
      try {
        return await BynuxCloudApi.instance.createSession(googleToken);
      } on CloudApiException catch (error) {
        if (error.statusCode == 404 || error.statusCode == 405) {
          _sessionUnsupported = true;
          return null;
        }
        if (error.statusCode == 401 || error.statusCode == 403) return null;
      } catch (_) {
        // لا اتصال الآن.
      }
      if (i + 1 < attempts) await Future<void>.delayed(const Duration(seconds: 2));
    }
    return null;
  }

  /// يطلب جلسة الخادم الطويلة ويحفظها (بعد الموافقة فقط). إن فشل الاتصال والرمز ما زال
  /// صالحًا نعيد المحاولة بعد 30 ثانية حتى 3 مرات، فلا تضيع الجلسة بسبب انقطاع عابر.
  Future<void> _obtainSession(String googleToken,
      {int attempts = 2, int retriesLeft = 3}) async {
    if (_obtainingSession || _user == null || !_consented || _sessionIsValid) return;
    _obtainingSession = true;
    final forUser = _user?.id;
    var granted = false;
    try {
      final grant = await _mintSession(googleToken, attempts: attempts);
      if (grant != null && forUser != null && _user?.id == forUser && _consented) {
        _sessionToken = grant.token;
        _sessionExpiresAt = grant.expiresAt;
        granted = true;
        await _persist();
      }
    } finally {
      _obtainingSession = false;
    }
    if (!granted && retriesLeft > 0 && !_sessionUnsupported) {
      Timer(const Duration(seconds: 30), () {
        final token = _freshGoogleToken();
        if (token != null && _user?.id == forUser) {
          unawaited(_obtainSession(token, retriesLeft: retriesLeft - 1));
        }
      });
    }
  }

  /// الخادم رفض رمز الجلسة (أُلغي أو انتهى): نتخلى عنه ونعود لرمز جوجل.
  /// يُرجع true إذا كان لدينا رمز جلسة أسقطناه فعلًا (فيستحق الطلب إعادة محاولة).
  bool dropRejectedSession() {
    if (_sessionToken == null) return false;
    _sessionToken = null;
    _sessionExpiresAt = null;
    unawaited(_persist());
    return true;
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

  /// الرمز الذي يُرسل للخادم: رمز الجلسة المحفوظ إن كان صالحًا، وإلا رمز جوجل إن كان
  /// ما زال في الذاكرة. لا نفتح واجهة جوجل هنا أبدًا، ولا نسمح بأي طلب قبل موافقة المستخدم.
  Future<String> authToken() async {
    if (!hasConsented) {
      throw const CloudApiException('يلزم الموافقة على شروط الاستخدام وسياسة الخصوصية أولاً.');
    }
    final saved = _sessionToken;
    if (saved != null && _sessionIsValid) return saved;
    final google = _freshGoogleToken();
    if (google != null) {
      unawaited(_obtainSession(google));
      return google;
    }
    throw CloudApiException(_sessionUnsupported
        ? 'خادم السحابة قديم ولا يدعم حفظ الجلسة. أعد نشر ملف worker.js ثم سجّل الخروج وادخل من جديد.'
        : 'انتهت جلسة السحابة. سجّل الخروج ثم ادخل بحساب جوجل مرة واحدة.');
  }

  String? _freshGoogleToken() {
    final token = _account?.authentication.idToken ?? _pendingGoogleToken;
    return _idTokenIsFresh(token) ? token : null;
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

  /// إذا رفض الخادم رمز الجلسة المحفوظ (401) نسقطه ونعيد الطلب مرة واحدة برمز جوجل.
  Future<T> _withAuthRetry<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on CloudApiException catch (error) {
      if (error.statusCode == 401 &&
          BynuxSession.instance.dropRejectedSession()) {
        return await action();
      }
      rethrow;
    }
  }

  /// يطلب من الخادم رمز جلسة طويلًا مقابل رمز جوجل صالح. يُرمى CloudApiException
  /// برمز 404/405 إذا كان الخادم قديمًا ولا يدعم الجلسات.
  Future<CloudSessionGrant> createSession(String googleIdToken) async {
    final request = await _client
        .postUrl(_uri('/v1/session'))
        .timeout(const Duration(seconds: 15));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $googleIdToken');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode('{}'));
    final response = await request.close().timeout(const Duration(seconds: 20));
    final raw = await utf8.decoder.bind(response).join();
    Map<String, dynamic> decoded = <String, dynamic>{};
    try {
      final value = jsonDecode(raw);
      if (value is Map) decoded = Map<String, dynamic>.from(value);
    } catch (_) {}
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        decoded['ok'] == false) {
      throw CloudApiException(
        _statusMessage(response.statusCode, decoded['error']?.toString()),
        statusCode: response.statusCode,
      );
    }
    final token = decoded['sessionToken']?.toString() ?? '';
    final expiresAt = DateTime.tryParse(decoded['expiresAt']?.toString() ?? '');
    if (token.isEmpty || expiresAt == null) {
      throw const CloudApiException('استجابة الجلسة غير مكتملة.', statusCode: 404);
    }
    return CloudSessionGrant(token: token, expiresAt: expiresAt);
  }

  /// إلغاء رمز الجلسة على الخادم عند تسجيل الخروج (أفضل جهد، لا يعطّل الخروج).
  Future<void> revokeSession(String sessionToken) async {
    try {
      final request = await _client
          .postUrl(_uri('/v1/session/revoke'))
          .timeout(const Duration(seconds: 10));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $sessionToken');
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode('{}'));
      final response = await request.close().timeout(const Duration(seconds: 10));
      await utf8.decoder.bind(response).join();
    } catch (_) {
      // تنتهي صلاحية الجلسة على الخادم من تلقاء نفسها.
    }
  }

  Future<HttpClientRequest> _open(String method, String path) async {
    final token = await BynuxSession.instance.authToken();
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

  Future<CloudProfile> getProfile() => _withAuthRetry(() async {
        final json = await _jsonRequest('GET', '/v1/profile');
        return CloudProfile.fromJson(json);
      });

  Future<List<CloudFile>> listFiles() => _withAuthRetry(_listFilesOnce);

  Future<List<CloudFile>> _listFilesOnce() async {
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

  Future<CloudFile> uploadLocalScript(String path) =>
      _withAuthRetry(() => _uploadLocalScriptOnce(path));

  Future<CloudFile> _uploadLocalScriptOnce(String path) async {
    final file = File(path);
    final name = path.replaceAll('\\', '/').split('/').last;
    if (!name.toLowerCase().endsWith('.py') ||
        name.contains('..') ||
        name.contains('/') ||
        name.contains('\\')) {
      throw const CloudApiException('اسم السكربت غير صالح للنسخ السحابي.');
    }
    if (await file.length() > bynuxMaxScriptBytes) {
      throw const CloudApiException('حجم السكربت أكبر من الحد المسموح وهو 1 ميجابايت.');
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

  Future<List<int>> downloadFile(String name) =>
      _withAuthRetry(() => _downloadFileOnce(name));

  Future<List<int>> _downloadFileOnce(String name) async {
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
      if (bytes.length > bynuxServerMaxBytes) {
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
