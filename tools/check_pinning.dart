// بوابة CI: يتحقق أن التثبيت يعمل فعلًا قبل البناء.
//  1) اتصال حقيقي بالخادم عبر العميل المثبَّت الفعلي: أي رد HTTP (حتى 401/404) = نجاح المصافحة؛
//     HandshakeException = فشل البناء (الجذور المضمّنة لا تغطي سلسلة الخادم).
//  2) اختبار سلبي حتمي: نفس الخادم الحقيقي، لكن بسياق ثقة فارغ (withTrustedRoots: false وبلا أي جذر).
//     يجب أن تفشل المصافحة؛ وهذا دليل أن جذور النظام لا تُستعمل أصلًا (جذور runner تثق بهذا الخادم حتمًا).
//
// لماذا لا نختبر ضد موقع خارجي (مثل example.com)؟ لأن القائمة تضم عمدًا جذور مُصدري Cloudflare
// (ISRG وGTS وSSL.com وSectigo)، وكثير من المواقع تستعمل الجذور نفسها، فقد ينجح الاتصال بها
// وهذا سلوك صحيح للتثبيت على مستوى الجذور، لا عيب فيه. أما منع بقية المضيفين فتتولاه
// requirePinnedUri في طبقة التطبيق، ونختبره هنا أيضًا (3).
//  3) requirePinnedUri يرفض مضيفًا آخر وhttp العادي.
// التشغيل: dart run tools/check_pinning.dart
import 'dart:io';

import '../secure_http.dart';

Future<void> main() async {
  var failed = false;

  // 1) إيجابي: العميل المثبَّت الفعلي مع الخادم الحقيقي.
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

  // 2) سلبي: الخادم نفسه بسياق بلا أي جذر. لو نجح فجذور النظام تُستعمل = التثبيت غير مطبّق.
  final empty = createPinnedHttpClient(
    contextOverride: SecurityContext(withTrustedRoots: false),
  );
  try {
    final request = await empty
        .getUrl(Uri.parse('https://$pinnedHost/'))
        .timeout(const Duration(seconds: 30));
    final response = await request.close().timeout(const Duration(seconds: 30));
    await response.drain<void>();
    stderr.writeln('FAIL: client with an EMPTY trust store still connected - system roots are being used.');
    failed = true;
  } on HandshakeException {
    stdout.writeln('OK: empty trust store was rejected (system roots are not used).');
  } on TlsException {
    stdout.writeln('OK: empty trust store was rejected (system roots are not used).');
  } catch (e) {
    // خطأ شبكة غير TLS لا يثبت التثبيت ولا ينفيه.
    stderr.writeln('FAIL: negative test inconclusive (non-TLS error): $e');
    failed = true;
  } finally {
    empty.close(force: true);
  }

  // 3) طبقة المضيف: أي مضيف آخر أو http العادي يُرفض قبل أي اتصال.
  for (final bad in <String>[
    'https://example.com/',
    'https://evil.$pinnedHost.example.org/',
    'http://$pinnedHost/',
  ]) {
    try {
      requirePinnedUri(Uri.parse(bad));
      stderr.writeln('FAIL: requirePinnedUri accepted $bad');
      failed = true;
    } on ArgumentError {
      stdout.writeln('OK: requirePinnedUri rejected $bad');
    }
  }

  exit(failed ? 1 : 0);
}
