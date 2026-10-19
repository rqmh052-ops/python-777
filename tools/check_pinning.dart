// بوابة CI: يتحقق أن التثبيت يعمل فعلًا قبل البناء.
//  1) اتصال حقيقي بالخادم: أي رد HTTP (حتى 401/404) = نجاح المصافحة؛ HandshakeException = فشل البناء.
//  2) اختبار سلبي: العميل المثبَّت يجب أن يفشل مع https://example.com (دليل أنه لا يستعمل جذور النظام).
// التشغيل: dart run tools/check_pinning.dart
import 'dart:io';

import '../secure_http.dart';

Future<void> main() async {
  var failed = false;

  final client = createPinnedHttpClient();
  try {
    final request = await openPinned(
      client,
      'GET',
      Uri.parse('https://$pinnedHost/'),
      timeout: const Duration(seconds: 30),
    );
    final response = await request.close().timeout(const Duration(seconds: 30));
    await response.drain<void>();
    stdout.writeln('OK: handshake with $pinnedHost succeeded (HTTP ${response.statusCode}).');
  } on PinnedConnectionException catch (e) {
    stderr.writeln('FAIL: TLS pinning rejected the real server: $e');
    failed = true;
  } catch (e) {
    stderr.writeln('FAIL: could not reach $pinnedHost: $e');
    failed = true;
  } finally {
    client.close(force: true);
  }

  // اختبار سلبي: نتجاوز requirePinnedUri عمدًا باستعمال HttpClient المثبَّت مباشرة.
  final negative = createPinnedHttpClient();
  try {
    final request = await negative
        .getUrl(Uri.parse('https://example.com/'))
        .timeout(const Duration(seconds: 30));
    final response = await request.close().timeout(const Duration(seconds: 30));
    await response.drain<void>();
    stderr.writeln('FAIL: pinned client connected to example.com - pinning is NOT enforced.');
    failed = true;
  } on HandshakeException {
    stdout.writeln('OK: example.com was rejected (pinning is enforced).');
  } on TlsException {
    stdout.writeln('OK: example.com was rejected (pinning is enforced).');
  } catch (e) {
    // خطأ شبكة غير TLS (مثل انقطاع DNS) لا يثبت التثبيت ولا ينفيه.
    stderr.writeln('FAIL: negative test inconclusive (non-TLS error): $e');
    failed = true;
  } finally {
    negative.close(force: true);
  }

  exit(failed ? 1 : 0);
}
