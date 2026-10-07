import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'logo.dart';
import 'store.dart';
import 'python_runtime.dart';
import 'script_runner.dart';

// ───────── الألوان والأنماط ─────────
class C {
  static const bg = Color(0xFF090D14);
  static const surface = Color(0xFF0F1624);
  static const border = Color(0xFF1E2A40);
  static const text = Color(0xFFE8EEF8);
  static const muted = Color(0xFF8FA0BC);
  static const dim = Color(0xFF6F829E);
  static const accent = Color(0xFF4D8BFF);
  static const onAccent = Color(0xFF04112B);
  static const console = Color(0xFF060A11);
  static const error = Color(0xFFFF6B6B);
  static const ok = Color(0xFF5BD68A);
  static const warn = Color(0xFFFFB86B);
  static const cyan = Color(0xFF6FD3E8);
  static const accentEdge = Color(0xFF7AA7FF); // حد الأزرار المعبأة (أفتح قليلاً من accent)
  static const outline = Color(0xFF34435E); // حد الأزرار الشفافة المحايدة
}

const mono = TextStyle(
    fontFamily: 'monospace', fontSize: 14, height: 1.57, color: C.text);

BoxDecoration _box(Color color) => BoxDecoration(
    color: color,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: C.border));

final _ob = OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: const BorderSide(color: C.border));
final _obFocus =
    _ob.copyWith(borderSide: const BorderSide(color: C.accent));

const youtubeUrl = 'https://youtube.com/channel/UC4Ox1C-_DWCbIeiWJ_6rV9Q';
const telegramUrl = 'https://t.me/Bayan_x777';
final _logo = base64Decode(kLogoBase64);

// ───────── كتالوج المكتبات (التثبيت حقيقي داخل بيئة Python المشتركة) ─────────
class Lib {
  const Lib(this.name, this.desc, this.module);
  final String name, desc, module;
}

const catalog = <Lib>[
  Lib('requests', 'طلبات HTTP للإنترنت', 'requests'),
  Lib('beautifulsoup4', 'تحليل صفحات HTML', 'bs4'),
  Lib('python-dotenv', 'قراءة متغيرات البيئة من .env', 'dotenv'),
  Lib('PyYAML', 'قراءة وكتابة YAML', 'yaml'),
  Lib('python-telegram-bot', 'تطوير بوتات Telegram', 'telegram'),
  Lib('pyTelegramBotAPI', 'إنشاء بوتات Telegram بواجهة بسيطة', 'telebot'),
  Lib('Telethon', 'عميل Telegram عبر MTProto', 'telethon'),
];

// يعرض رسالة الخطأ الحقيقية بدل PlatformException(code, message, null, null)
String errText(Object e) =>
    e is PlatformException ? (e.message ?? e.code) : '$e';

String _pkgKey(String name) => name.replaceAll(RegExp(r'[_.-]+'), '-').toLowerCase();
String cleanPackageName({required String clean}) {
  final match = RegExp(r'^([A-Za-z0-9][A-Za-z0-9_.-]*)').firstMatch(clean);
  return _pkgKey(match?.group(1) ?? clean);
}

// ───────── انتقالات وحركات ─────────
// منحنى يعرف الاتجاه: دخول يتباطأ عند النهاية، وخروج يبدأ بلطف ثم يسرع
class _DirCurve extends Animatable<double> {
  const _DirCurve(this.forward, this.reverse);
  final Curve forward, reverse;

  @override
  double transform(double t) => forward.transform(t);

  @override
  double evaluate(Animation<double> animation) =>
      (animation.status == AnimationStatus.reverse ? reverse : forward)
          .transform(animation.value);
}

const _pageCurve = _DirCurve(Curves.easeOutCubic, Curves.easeInOutCubic);

// دخول: انزلاق مع ظهور تدريجي. رجوع: عكس الدخول.
// الشاشة التي في الخلف تتحرك قليلاً وتُعتَّم أثناء الانتقال.
Route<T> smooth<T>(Widget page) => PageRouteBuilder<T>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 360),
      reverseTransitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, a, sa, child) {
        final enter = a.drive(_pageCurve);
        final cover = sa.drive(_pageCurve);
        return SlideTransition(
          position: cover.drive(
              Tween<Offset>(begin: Offset.zero, end: const Offset(0.07, 0))),
          textDirection: TextDirection.ltr,
          child: Stack(fit: StackFit.passthrough, children: [
            FadeTransition(
              opacity: enter,
              child: SlideTransition(
                position: enter.drive(Tween<Offset>(
                    begin: const Offset(-0.16, 0), end: Offset.zero)),
                textDirection: TextDirection.ltr,
                child: child,
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: FadeTransition(
                  opacity: cover.drive(Tween<double>(begin: 0, end: 0.3)),
                  child: const ColoredBox(color: Color(0xFF000000)),
                ),
              ),
            ),
          ]),
        );
      },
    );

class Appear extends StatelessWidget {
  const Appear({super.key, required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: 280 + 70 * (index > 8 ? 8 : index)),
        curve: Curves.easeOutCubic,
        builder: (_, v, ch) => Opacity(
            opacity: v,
            child: Transform.translate(offset: Offset(0, 14 * (1 - v)), child: ch)),
        child: child,
      );
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: C.bg,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'مشغّل بايثون',
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: C.bg,
          canvasColor: C.surface,
          colorScheme: const ColorScheme.dark(
              primary: C.accent, onPrimary: C.onAccent, surface: C.surface),
          snackBarTheme: SnackBarThemeData(
            backgroundColor: C.surface,
            contentTextStyle: const TextStyle(color: C.text),
            actionTextColor: C.accent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: C.border)),
          ),
        ),
        builder: (context, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
        onGenerateRoute: (_) => smooth<void>(const HomeScreen()),
      );
}

// ───────── مكونات مشتركة ─────────
class Header extends StatelessWidget {
  const Header(
      {super.key,
      required this.title,
      this.back = false,
      this.mono = false,
      this.onMenu,
      this.onBack,
      this.actions = const []});
  final String title;
  final bool back, mono;
  final VoidCallback? onMenu, onBack;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: C.border))),
        child: Row(children: [
          if (back)
            PressFx(
              scale: .88,
              child: IconButton(
                  tooltip: 'رجوع',
                  color: C.text,
                  onPressed: onBack ?? () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back)),
            ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: back ? 4 : 12),
              child: Text(title,
                  textAlign: TextAlign.right,
                  textDirection: mono ? TextDirection.ltr : null,
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      fontFamily: mono ? 'monospace' : null)),
            ),
          ),
          ...actions,
          if (onMenu != null)
            PressFx(
              scale: .88,
              child: IconButton(
                  tooltip: 'القائمة',
                  color: C.text,
                  onPressed: onMenu,
                  icon: const Icon(Icons.more_vert)),
            ),
        ]),
      );
}

// تأثير ضغط خفيف وسريع: تصغير بسيط أثناء اللمس
class PressFx extends StatefulWidget {
  const PressFx(
      {super.key, required this.child, this.enabled = true, this.scale = 0.97});
  final Widget child;
  final bool enabled;
  final double scale;

  @override
  State<PressFx> createState() => _PressFxState();
}

class _PressFxState extends State<PressFx> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (_) => _set(true),
        onPointerUp: (_) => _set(false),
        onPointerCancel: (_) => _set(false),
        child: AnimatedScale(
          scale: _down && widget.enabled ? widget.scale : 1.0,
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          child: widget.child,
        ),
      );
}

// زر معبأ: حد خارجي رفيع بلون أفتح قليلاً من الزر
class PButton extends StatelessWidget {
  const PButton(
      {super.key,
      required this.label,
      this.icon,
      this.onPressed,
      this.height = 52,
      this.radius = 12,
      this.fontSize = 16});
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final double height, radius, fontSize;

  @override
  Widget build(BuildContext context) {
    final on = onPressed != null;
    return PressFx(
      enabled: on,
      child: SizedBox(
        height: height,
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: C.accent,
            foregroundColor: C.onAccent,
            disabledBackgroundColor: C.accent.withValues(alpha: .35),
            disabledForegroundColor: C.onAccent,
            side: BorderSide(
                color: on ? C.accentEdge : C.accentEdge.withValues(alpha: .25)),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
            textStyle: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
            Text(label),
          ]),
        ),
      ),
    );
  }
}

// زر شفاف: حد متناسق مع الثيم (accent للأزرار الأساسية، محايد للإيقاف)
class OButton extends StatelessWidget {
  const OButton(
      {super.key,
      required this.label,
      this.icon,
      this.onPressed,
      this.accent = true,
      this.height = 40,
      this.radius = 10,
      this.fontSize = 14,
      this.minWidth,
      this.padding});
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool accent;
  final double height, radius, fontSize;
  final double? minWidth;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final on = onPressed != null;
    final line = accent ? C.accent : C.outline;
    return PressFx(
      enabled: on,
      child: SizedBox(
        height: height,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: accent ? C.accent : C.text,
            disabledForegroundColor: C.dim,
            side: BorderSide(color: on ? line : line.withValues(alpha: .4)),
            padding: padding,
            minimumSize: minWidth == null ? null : Size(minWidth!, height),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
            textStyle: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600),
          ),
          child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: fontSize + 4),
                  SizedBox(width: fontSize >= 16 ? 8 : 6),
                ],
                Text(label),
              ]),
        ),
      ),
    );
  }
}

class ActionRow extends StatelessWidget {
  const ActionRow(
      {super.key,
      required this.icon,
      required this.label,
      required this.onTap,
      this.color = C.text});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 52,
          child: Row(children: [
            const SizedBox(width: 8),
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 16),
            Text(label, style: TextStyle(color: color, fontSize: 16)),
          ]),
        ),
      );
}

// ───────── الشاشة الرئيسية ─────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _key = GlobalKey<ScaffoldState>();
  Timer? _tick;
  bool _asked = false, _dialogOpen = false, _prevFallback = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    fallbackMode.addListener(_onMode);
    // تحديث الأوقات النسبية واكتشاف الملفات الجديدة أثناء بقاء التطبيق مفتوحاً
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      store.refresh();
      setState(() {});
    });
    _boot();
  }

  Future<void> _boot() async {
    await store.init();
    if (!mounted) return;
    if (fallbackMode.value && !_asked) {
      _asked = true;
      _showAccessDialog();
    }
  }

  void _onMode() {
    final f = fallbackMode.value;
    if (_prevFallback && !f && mounted) {
      _snack('تم تفعيل الحفظ في مجلد Bayan 777');
    }
    _prevFallback = f;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) store.onResume();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    fallbackMode.removeListener(_onMode);
    _tick?.cancel();
    super.dispose();
  }

  void _snack(String m) {
    final s = ScaffoldMessenger.of(context);
    s.clearSnackBars();
    s.showSnackBar(SnackBar(content: Text(m)));
  }

  // شرح واضح مع زر لفتح إعدادات الصلاحية
  Future<void> _showAccessDialog() async {
    if (_dialogOpen || !mounted) return;
    _dialogOpen = true;
    final all = store.needsAllFilesAccess;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.surface,
        title: const Text('إذن الوصول إلى الملفات'),
        content: Text(all
            ? 'لحفظ سكربتاتك كملفات حقيقية في مجلد "Bayan 777" يحتاج التطبيق إذن «الوصول إلى جميع الملفات».\n\nاضغط «فتح الإعدادات» وفعّل الإذن للتطبيق ثم ارجع إليه.\n\nإلى أن تمنحه، تُحفظ السكربتات مؤقتاً داخل مساحة التطبيق ثم تُنقل تلقائياً.'
            : 'لحفظ سكربتاتك كملفات حقيقية في مجلد "Bayan 777" يحتاج التطبيق إذن الوصول إلى التخزين.\n\nاضغط «منح الإذن» للمتابعة.\n\nإلى أن تمنحه، تُحفظ السكربتات مؤقتاً داخل مساحة التطبيق ثم تُنقل تلقائياً.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('لاحقاً')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(all ? 'فتح الإعدادات' : 'منح الإذن')),
        ],
      ),
    );
    _dialogOpen = false;
    if (go == true) await store.requestAccess();
  }

  // فتح المكتبات من القائمة؛ وعند الرجوع تُفتح القائمة مجدداً كما كانت
  Future<void> _openLibraries() async {
    final nav = Navigator.of(context);
    nav.pop(); // يغلق القائمة الجانبية
    await nav.push<void>(smooth<void>(const LibrariesScreen()));
    if (!mounted) return;
    _key.currentState?.openEndDrawer();
  }


  @override
  Widget build(BuildContext context) => Scaffold(
        key: _key,
        endDrawer: AppDrawer(onLibraries: _openLibraries),
        body: SafeArea(
          child: Column(children: [
            Header(
                title: 'سكربتاتي',
                onMenu: () => _key.currentState?.openEndDrawer()),
            Expanded(
              child: ListenableBuilder(
                listenable:
                    Listenable.merge([scripts, scriptsReady, fallbackMode]),
                builder: (c, _) {
                  if (!scriptsReady.value) {
                    return const Center(
                        child: CircularProgressIndicator(
                            strokeWidth: 2.4, color: C.accent));
                  }
                  final list = scripts.value;
                  return RefreshIndicator(
                    color: C.accent,
                    backgroundColor: C.surface,
                    onRefresh: store.refresh,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(16),
                      children: [
                        Appear(
                            index: 0,
                            child: PButton(
                                label: 'سكربت جديد',
                                icon: Icons.add,
                                onPressed: () => Navigator.push(
                                    c, smooth(const CreateScreen())))),
                        if (fallbackMode.value) ...[
                          const SizedBox(height: 16),
                          StorageBanner(onGrant: _showAccessDialog),
                        ],
                        const SizedBox(height: 28),
                        if (list.isEmpty)
                          const Appear(index: 1, child: EmptyState())
                        else ...[
                          const Text('السكربتات',
                              style: TextStyle(color: C.muted, fontSize: 13)),
                          const SizedBox(height: 12),
                          for (var i = 0; i < list.length; i++)
                            Padding(
                                key: ObjectKey(list[i]),
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Appear(
                                    index: i + 1,
                                    child: ScriptTile(script: list[i]))),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ]),
        ),
      );
}

// تنبيه يظهر عندما يكون الحفظ مؤقتاً داخل مساحة التطبيق (لا توجد صلاحية)
class StorageBanner extends StatelessWidget {
  const StorageBanner({super.key, required this.onGrant});
  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: C.warn.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: C.warn.withValues(alpha: .35))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Row(children: [
            Icon(Icons.info_outline, color: C.warn, size: 20),
            SizedBox(width: 10),
            Expanded(
                child: Text(
                    'السكربتات محفوظة مؤقتاً داخل التطبيق فقط. امنح إذن الملفات لتُحفظ في مجلد Bayan 777.',
                    style: TextStyle(fontSize: 13, color: C.text))),
          ]),
          const SizedBox(height: 10),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OButton(
                label: 'منح الإذن',
                icon: Icons.folder_open_outlined,
                height: 38,
                fontSize: 13,
                onPressed: onGrant),
          ),
        ]),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 40),
        child: Column(children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
                shape: BoxShape.circle, color: C.accent.withValues(alpha: .12)),
            child: const Icon(Icons.code_rounded, color: C.accent, size: 34),
          ),
          const SizedBox(height: 18),
          const Text('ما عندك سكربتات بعد',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text('اضغط "سكربت جديد" وابدأ بكتابة أول سكربت',
              textAlign: TextAlign.center,
              style: TextStyle(color: C.muted, fontSize: 14)),
        ]),
      );
}

class ScriptTile extends StatelessWidget {
  const ScriptTile({super.key, required this.script});
  final Script script;

  @override
  Widget build(BuildContext context) {
    final run = script.lastRun;
    return Material(
      color: C.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: C.border)),
      child: InkWell(
        onTap: () => Navigator.push(context, smooth(ScriptScreen(script: script)))
            .then((_) => store.refresh()),
        onLongPress: () {
          HapticFeedback.mediumImpact();
          scriptActions(context, script);
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            const Icon(Icons.description_outlined, color: C.accent, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(script.name,
                            textDirection: TextDirection.ltr,
                            overflow: TextOverflow.ellipsis,
                            style: mono.copyWith(fontSize: 15)),
                      ),
                      if (script.pinned) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.push_pin, color: C.accent, size: 15),
                      ],
                    ]),
                    const SizedBox(height: 2),
                    Text('آخر تعديل: ${relativeTime(script.modified)}',
                        style: const TextStyle(fontSize: 12, color: C.muted)),
                    Text(
                        run == null
                            ? 'لم يُشغّل بعد'
                            : 'آخر تشغيل: ${relativeTime(run)}',
                        style: const TextStyle(fontSize: 12, color: C.muted)),
                  ]),
            ),
            const Icon(Icons.chevron_left,
                color: C.muted, size: 22, textDirection: TextDirection.ltr),
          ]),
        ),
      ),
    );
  }
}

// ───────── إدارة السكربتات: تثبيت / إعادة تسمية / نسخ / حذف ─────────
void _toast(BuildContext context, String m) {
  final s = ScaffoldMessenger.of(context);
  s.clearSnackBars();
  s.showSnackBar(SnackBar(content: Text(m)));
}

void scriptActions(BuildContext context, Script s) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: C.surface,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: C.border, borderRadius: BorderRadius.circular(2))),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
                child: Text(s.name,
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.right,
                    style: mono.copyWith(fontSize: 15, color: C.muted)),
              ),
              ActionRow(
                  icon: s.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                  label: s.pinned ? 'إلغاء التثبيت' : 'تثبيت في الأعلى',
                  onTap: () {
                    Navigator.pop(ctx);
                    togglePin(context, s);
                  }),
              ActionRow(
                  icon: Icons.edit_outlined,
                  label: 'إعادة تسمية',
                  onTap: () {
                    Navigator.pop(ctx);
                    renameScript(context, s);
                  }),
              ActionRow(
                  icon: Icons.content_copy_outlined,
                  label: 'نسخ',
                  onTap: () {
                    Navigator.pop(ctx);
                    duplicateScript(context, s);
                  }),
              ActionRow(
                  icon: Icons.delete_outline,
                  label: 'حذف',
                  color: C.error,
                  onTap: () {
                    Navigator.pop(ctx);
                    deleteScript(context, s);
                  }),
            ]),
      ),
    ),
  );
}

Future<void> togglePin(BuildContext context, Script s) async {
  try {
    await store.setPinned(s, !s.pinned);
  } catch (_) {
    if (context.mounted) _toast(context, 'تعذّر حفظ حالة التثبيت');
  }
}

Future<void> renameScript(BuildContext context, Script s) async {
  final ctl = TextEditingController(text: s.name);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: C.surface,
      title: const Text('إعادة تسمية'),
      content: TextField(
        controller: ctl,
        autofocus: true,
        textDirection: TextDirection.ltr,
        style: mono.copyWith(fontSize: 15),
        cursorColor: C.accent,
        decoration: InputDecoration(
            border: _ob, enabledBorder: _ob, focusedBorder: _obFocus),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('حفظ')),
      ],
    ),
  );
  if (result == null || result.isEmpty) return;
  try {
    final r = await store.rename(s, result);
    if (!context.mounted) return;
    if (r == null) {
      _toast(context, 'اسم غير صالح');
    } else if (r.name.toLowerCase() != '${cleanBase(result)}.py'.toLowerCase()) {
      _toast(context, 'الاسم موجود مسبقاً، تمت التسمية: ${r.name}');
    }
  } catch (_) {
    if (context.mounted) _toast(context, 'تعذّرت إعادة التسمية');
  }
}

Future<void> duplicateScript(BuildContext context, Script s) async {
  try {
    final c = await store.duplicate(s);
    if (context.mounted) _toast(context, 'تم النسخ: ${c.name}');
  } catch (_) {
    if (context.mounted) _toast(context, 'تعذّر نسخ السكربت');
  }
}

Future<void> deleteScript(BuildContext context, Script s) async {
  final m = ScaffoldMessenger.of(context);
  DeletedScript? d;
  try {
    d = await store.delete(s);
  } catch (_) {
    m.clearSnackBars();
    m.showSnackBar(const SnackBar(content: Text('تعذّر حذف الملف')));
    return;
  }
  if (d == null) return;
  final gone = d;
  m.clearSnackBars();
  m.showSnackBar(SnackBar(
    content: Text('تم حذف ${gone.name}'),
    action: SnackBarAction(
      label: 'تراجع',
      onPressed: () async {
        try {
          final r = await store.restore(gone);
          if (r.name != gone.name) {
            m.clearSnackBars();
            m.showSnackBar(
                SnackBar(content: Text('تمت الاستعادة باسم ${r.name}')));
          }
        } catch (_) {
          m.clearSnackBars();
          m.showSnackBar(const SnackBar(content: Text('تعذّرت الاستعادة')));
        }
      },
    ),
  ));
}

// ───────── القائمة الجانبية ─────────
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key, required this.onLibraries});
  final VoidCallback onLibraries;

  Widget _nav(IconData icon, String label, bool active, VoidCallback onTap) =>
      Material(
        color: active ? C.accent.withValues(alpha: .14) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Icon(icon, color: active ? C.accent : C.muted, size: 20),
                const SizedBox(width: 12),
                Text(label,
                    style: TextStyle(
                        color: active ? C.accent : C.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ),
      );

  Widget _link(IconData icon, String label, String url) => Expanded(
        child: OButton(
          label: label,
          icon: icon,
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          onPressed: () =>
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        ),
      );

  @override
  Widget build(BuildContext context) => Drawer(
        width: 300,
        backgroundColor: C.surface,
        shape: const RoundedRectangleBorder(),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 28, 16, 16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(4, 0, 4, 16),
                    child: Text('مشغّل بايثون',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w600)),
                  ),
                  _nav(Icons.description_outlined, 'السكربتات', true,
                      () => Navigator.pop(context)),
                  const SizedBox(height: 4),
                  _nav(Icons.extension_outlined, 'المكتبات', false, onLibraries),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(4, 24, 4, 8),
                    child: Text('حول التطبيق',
                        style: TextStyle(fontSize: 13, color: C.muted)),
                  ),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: _box(C.bg),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(children: [
                            ClipOval(
                              child: Image.memory(_logo,
                                  width: 52,
                                  height: 52,
                                  fit: BoxFit.cover,
                                  gaplessPlayback: true),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('بيان',
                                        style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w600)),
                                    SizedBox(height: 2),
                                    Text('شروحات تقنية مبسطة',
                                        style: TextStyle(
                                            fontSize: 12, color: C.muted)),
                                  ]),
                            ),
                          ]),
                          const SizedBox(height: 14),
                          Row(children: [
                            _link(Icons.smart_display_outlined, 'يوتيوب',
                                youtubeUrl),
                            const SizedBox(width: 8),
                            _link(Icons.send_outlined, 'تليجرام', telegramUrl),
                          ]),
                        ]),
                  ),
                ]),
          ),
        ),
      );
}

// ───────── شاشة المكتبات ─────────
class LibrariesScreen extends StatefulWidget {
  const LibrariesScreen({super.key});

  @override
  State<LibrariesScreen> createState() => _LibrariesScreenState();
}

class _LibrariesScreenState extends State<LibrariesScreen> {
  final _packages = <String, InstalledPackage>{};
  final _jobs = <String, BayanEvent>{};
  final _jobPackages = <String, String>{};
  List<CatalogPackage> _catalog = const <CatalogPackage>[];
  StreamSubscription<BayanEvent>? _events;
  bool _loading = true;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _events = bayanPython.events.listen(_onEvent);
    _load();
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  void _onEvent(BayanEvent e) {
    if (e.channel != 'package' || !mounted || e.jobId.isEmpty) return;
    setState(() => _jobs[e.jobId] = e);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      await bayanPython.init();
      final results = await Future.wait([
        bayanPython.listInstalled(),
        bayanPython.catalogStatus(),
      ]);
      final installed = results[0] as List<InstalledPackage>;
      final catalog = results[1] as List<CatalogPackage>;
      if (!mounted) return;
      setState(() {
        _packages
          ..clear()
          ..addEntries(installed.map((p) => MapEntry(_pkgKey(p.name), p)));
        _catalog = catalog;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('تعذر فتح مدير المكتبات: ${errText(e)}');
    }
  }

  Future<void> _refresh({bool silent = false, bool force = false}) async {
    if (_refreshing || (_jobs.isNotEmpty && !force)) return;
    setState(() => _refreshing = true);
    try {
      final results = await Future.wait([
        bayanPython.listInstalled(),
        bayanPython.catalogStatus(),
      ]);
      final installed = results[0] as List<InstalledPackage>;
      final catalog = results[1] as List<CatalogPackage>;
      if (!mounted) return;
      setState(() {
        _packages
          ..clear()
          ..addEntries(installed.map((p) => MapEntry(_pkgKey(p.name), p)));
        _catalog = catalog;
      });
    } catch (e) {
      if (mounted && !silent) _snack('تعذر تحديث حالة المكتبات: ${errText(e)}');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _snack(String text) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _install(String spec) async {
    final clean = spec.trim();
    if (_jobs.isNotEmpty) {
      _snack('انتظر حتى تنتهي عملية المكتبة الحالية');
      return;
    }
    if (clean.isEmpty) {
      _snack('اكتب اسم المكتبة أولاً');
      return;
    }
    final jobId = bayanPython.newId('pkg');
    String rootName = cleanPackageName(clean: clean);
    setState(() {
      _jobPackages[jobId] = rootName;
      _jobs[jobId] = const BayanEvent({
        'channel': 'package',
        'type': 'progress',
        'stage': 'start',
        'progress': 0.0,
      });
    });
    try {
      await bayanPython.installPackage(spec: clean, jobId: jobId);
      await _refresh(silent: true, force: true);
      if (mounted) {
        final job = _jobs[jobId];
        if (job?.type != 'error') {
          _snack('تم تثبيت المكتبة بنجاح');
        }
        setState(() {
          _jobs.remove(jobId);
          _jobPackages.remove(jobId);
        });
      }
    } catch (e) {
      await _refresh(silent: true, force: true);
      if (!mounted) return;
      _snack('فشل تثبيت المكتبة: ${errText(e)}');
      setState(() {
        _jobs.remove(jobId);
        _jobPackages.remove(jobId);
      });
    }
  }

  Future<void> _remove(InstalledPackage package) async {
    if (_jobs.isNotEmpty) {
      _snack('انتظر حتى تنتهي عملية المكتبة الحالية');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.surface,
        title: const Text('إزالة المكتبة'),
        content: Text('هل تريد إزالة ${package.name}؟\nلن يتم حذف ملفات سكربتاتك.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: C.error),
            child: const Text('إزالة'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await bayanPython.removePackage(name: package.name);
      await _refresh(silent: true);
      if (mounted) _snack('تمت إزالة ${package.name}');
    } catch (e) {
      if (mounted) _snack('تعذر إزالة المكتبة: ${errText(e)}');
    }
  }

  Future<void> _downloadUnknown() async {
    if (_jobs.isNotEmpty) {
      _snack('انتظر حتى تنتهي عملية المكتبة الحالية');
      return;
    }
    final name = TextEditingController();
    final version = TextEditingController();
    try {
      final spec = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: C.surface,
          title: const Text('تنزيل مكتبة غير موجودة'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                textDirection: TextDirection.ltr,
                style: mono.copyWith(fontSize: 15),
                decoration: InputDecoration(
                  labelText: 'اسم المكتبة',
                  hintText: 'requests',
                  border: _ob,
                  enabledBorder: _ob,
                  focusedBorder: _obFocus,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: version,
                textDirection: TextDirection.ltr,
                style: mono.copyWith(fontSize: 15),
                decoration: InputDecoration(
                  labelText: 'الإصدار (اختياري)',
                  hintText: '2.32.5',
                  border: _ob,
                  enabledBorder: _ob,
                  focusedBorder: _obFocus,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            PButton(
              label: 'تنزيل',
              height: 42,
              radius: 10,
              onPressed: () {
                final n = name.text.trim();
                if (n.isEmpty) return;
                final v = version.text.trim();
                Navigator.pop(ctx, v.isEmpty ? n : '$n==$v');
              },
            ),
          ],
        ),
      );
      if (spec != null && mounted) await _install(spec);
    } finally {
      name.dispose();
      version.dispose();
    }
  }

  CatalogPackage? _catalogFor(String name) {
    final key = _pkgKey(name);
    for (final p in _catalog) {
      if (_pkgKey(p.name) == key) return p;
    }
    return null;
  }

  String _busyFor(Lib lib) {
    final key = _pkgKey(lib.name);
    for (final entry in _jobPackages.entries) {
      if (entry.value == key && _jobs.containsKey(entry.key)) return entry.key;
    }
    return '';
  }

  Widget _statusButton(Lib lib) {
    final catalog = _catalogFor(lib.name);
    final installed = _packages[_pkgKey(lib.name)];
    final busyId = _busyFor(lib);
    if (busyId.isNotEmpty && installed == null) {
      final e = _jobs[busyId];
      final progress = e?.progress ?? 0;
      return SizedBox(
        width: 108,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: progress > 0 ? progress.clamp(0.0, 1.0).toDouble() : null,
              minHeight: 3,
              backgroundColor: C.border,
              color: C.accent,
            ),
            const SizedBox(height: 4),
            Text(
              e?.stage == 'download' ? 'جاري التنزيل' : 'جاري التثبيت',
              style: const TextStyle(fontSize: 11, color: C.muted),
            ),
          ],
        ),
      );
    }
    if (installed == null) {
      if (catalog != null && !catalog.compatible) {
        return const Text('غير متوافقة', style: TextStyle(fontSize: 12, color: C.dim));
      }
      return OButton(
        label: 'تثبيت',
        height: 42,
        radius: 10,
        fontSize: 14,
        onPressed: _jobs.isEmpty ? () => _install(lib.name) : null,
      );
    }
    if (catalog?.updateAvailable == true) {
      return PButton(
        label: 'تحديث',
        height: 42,
        radius: 10,
        fontSize: 14,
        onPressed: _jobs.isEmpty ? () => _install('${lib.name}==${catalog!.latestVersion}') : null,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle_rounded, color: C.ok, size: 19),
        const SizedBox(width: 5),
        TextButton(
          onPressed: _jobs.isEmpty ? () => _remove(installed) : null,
          style: TextButton.styleFrom(foregroundColor: C.error),
          child: const Text('إزالة'),
        ),
      ],
    );
  }

  Widget _tile(Lib lib, int index) {
    final installed = _packages[_pkgKey(lib.name)];
    final catalog = _catalogFor(lib.name);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Appear(
        index: index,
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: _box(C.surface),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(lib.name, textDirection: TextDirection.ltr, style: mono.copyWith(fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(lib.desc, style: const TextStyle(fontSize: 12, color: C.muted)),
                    if (installed != null || catalog?.latestVersion != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        installed != null
                            ? 'الإصدار ${installed.version}${catalog?.updateAvailable == true && catalog?.latestVersion != null ? '  ←  ${catalog!.latestVersion}' : ''}'
                            : 'أحدث نسخة: ${catalog!.latestVersion}',
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(fontSize: 10.5, color: C.dim),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _statusButton(lib),
            ],
          ),
        ),
      ),
    );
  }

  Widget _jobBanner(String jobId, BayanEvent e) {
    final name = _jobPackages[jobId] ?? e.packageName;
    final progress = e.progress.clamp(0.0, 1.0).toDouble();
    final indeterminate = progress <= 0 && e.total <= 0 && e.stage != 'done';
    final stage = switch (e.stage) {
      'metadata' => 'جاري البحث عن الإصدار…',
      'resolve' => 'جاري حل الاعتماديات…',
      'download' => 'جاري تنزيل $name…',
      'verify' => 'جاري التحقق…',
      'extract' => 'جاري فك الحزمة…',
      'install' => 'جاري تثبيت الاعتماديات…',
      'rollback' => 'جاري استرجاع الحالة السابقة…',
      'done' => 'تم التثبيت بنجاح ✓',
      'error' => 'فشل التثبيت',
      _ => e.message.isNotEmpty ? e.message : 'جاري تجهيز المكتبة…',
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: e.stage == 'error' ? C.error : C.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.download_rounded, color: C.accent, size: 19),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name.isEmpty ? 'تثبيت مكتبة' : name,
                  textDirection: TextDirection.ltr,
                  style: mono.copyWith(fontSize: 14),
                ),
              ),
              if (e.stage == 'error')
                const Icon(Icons.error_outline_rounded, color: C.error, size: 19)
              else if (e.stage == 'done')
                const Icon(Icons.check_circle_rounded, color: C.ok, size: 19)
              else
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: indeterminate ? null : progress,
            minHeight: 4,
            backgroundColor: C.border,
            color: e.stage == 'error' ? C.error : C.accent,
          ),
          const SizedBox(height: 7),
          Text(stage, style: const TextStyle(fontSize: 12, color: C.muted)),
          if (e.total > 0)
            Text(
              '${formatBytes(e.received)} / ${formatBytes(e.total)}',
              style: const TextStyle(fontSize: 11, color: C.dim),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Header(
                title: 'المكتبات',
                back: true,
                actions: [
                  PressFx(
                    scale: .88,
                    child: IconButton(
                      tooltip: 'تحديث',
                      color: C.text,
                      onPressed: (_refreshing || _jobs.isNotEmpty) ? null : () => _refresh(),
                      icon: _refreshing
                          ? const SizedBox(width: 19, height: 19, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh_rounded),
                    ),
                  ),
                ],
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator(color: C.accent))
                    : ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          if (_jobs.isNotEmpty) ...[
                            for (final entry in _jobs.entries) _jobBanner(entry.key, entry.value),
                            const SizedBox(height: 12),
                          ],
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: C.accent.withValues(alpha: .10),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: C.border),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.info_outline, color: C.accent, size: 20),
                                SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'المكتبات تثبت مرة واحدة داخل بيئة Python العامة للتطبيق، وتصبح متاحة لكل سكربتاتك.',
                                    style: TextStyle(fontSize: 13, color: C.text),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 20),
                          if (_packages.isNotEmpty) ...[
                            const Text('المثبتة', style: TextStyle(color: C.muted, fontSize: 13)),
                            const SizedBox(height: 10),
                            for (final package in _packages.values.where((p) => _catalogFor(p.name) == null))
                              _tile(Lib(package.name, 'مكتبة أضفتها بنفسك', package.name.replaceAll('-', '_')), _catalog.length + _packages.keys.toList().indexOf(_pkgKey(package.name))),
                            for (final lib in catalog)
                              if (_packages.containsKey(_pkgKey(lib.name)))
                                _tile(lib, catalog.indexOf(lib)),
                            const SizedBox(height: 10),
                          ],
                          const Text('المكتبات الأساسية', style: TextStyle(color: C.muted, fontSize: 13)),
                          const SizedBox(height: 10),
                          for (var i = 0; i < catalog.length; i++)
                            if (!_packages.containsKey(_pkgKey(catalog[i].name))) _tile(catalog[i], i),
                          const SizedBox(height: 14),
                          OButton(
                            label: '+ تنزيل مكتبة غير موجودة',
                            icon: Icons.download_rounded,
                            height: 50,
                            radius: 12,
                            onPressed: _jobs.isEmpty ? _downloadUnknown : null,
                          ),
                          const SizedBox(height: 12),
                          if (_packages.isNotEmpty)
                            Center(
                              child: Text(
                                'مساحة المكتبات: ${formatBytes(_packages.values.fold<int>(0, (sum, p) => sum + p.size))}',
                                style: const TextStyle(fontSize: 12, color: C.dim),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      );
}

// ───────── شاشة إنشاء سكربت ─────────
class CreateScreen extends StatefulWidget {
  const CreateScreen({super.key});

  @override
  State<CreateScreen> createState() => _CreateScreenState();
}

class _CreateScreenState extends State<CreateScreen> {
  final _name = TextEditingController();
  final _paste = TextEditingController();
  bool _pasteMode = true;
  bool _busy = false;
  PickedPy? _picked;

  @override
  void dispose() {
    _name.dispose();
    _paste.dispose();
    super.dispose();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  // اختيار ملف .py حقيقي من مدير الملفات (مع فحص الامتداد بعد الاختيار)
  Future<void> _pick() async {
    try {
      final p = await pickPythonFile();
      if (p == null || !mounted) return;
      setState(() => _picked = p);
      if (_name.text.trim().isEmpty) _name.text = cleanBase(p.name);
    } on FormatException catch (e) {
      if (mounted) _snack(e.message);
    } catch (_) {
      if (mounted) _snack('تعذّر قراءة الملف');
    }
  }

  Future<void> _create() async {
    if (_busy) return;
    final n = _name.text.trim();
    if (n.isEmpty) {
      _snack('اكتب اسم السكربت أولاً');
      return;
    }
    final picked = _picked;
    if (!_pasteMode && picked == null) {
      _snack('اختر ملف بايثون أولاً');
      return;
    }
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final Script s;
      if (_pasteMode) {
        final code = _paste.text.isEmpty ? 'print("hello")' : _paste.text;
        s = await store.createFromText(n, code);
      } else {
        s = await store.createFromBytes(n, picked!.bytes);
      }
      if (!mounted) return;
      Navigator.pop(context);
      if (s.name.toLowerCase() != '${cleanBase(n)}.py'.toLowerCase()) {
        messenger.clearSnackBars();
        messenger.showSnackBar(SnackBar(
            content: Text('الاسم موجود مسبقاً، تم الحفظ باسم ${s.name}')));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('تعذّر إنشاء الملف');
    }
  }

  Widget _seg(String label, bool active, VoidCallback onTap) => Expanded(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          height: 44,
          decoration: BoxDecoration(
              color: active ? C.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(9)),
          child: TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              foregroundColor: active ? C.onAccent : C.muted,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
              textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            child: Text(label),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(children: [
            const Header(title: 'سكربت جديد', back: true),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('اسم السكربت',
                          style: TextStyle(fontSize: 13, color: C.muted)),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 48,
                        child: TextField(
                          controller: _name,
                          textDirection: TextDirection.ltr,
                          style: mono.copyWith(fontSize: 15),
                          cursorColor: C.accent,
                          decoration: InputDecoration(
                            hintText: 'مثال: bot.py',
                            hintStyle: const TextStyle(color: C.dim),
                            filled: true,
                            fillColor: C.surface,
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            border: _ob,
                            enabledBorder: _ob,
                            focusedBorder: _obFocus,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: _box(C.surface),
                        child: Row(children: [
                          _seg('لصق النص', _pasteMode,
                              () => setState(() => _pasteMode = true)),
                          const SizedBox(width: 4),
                          _seg('اختيار ملف', !_pasteMode,
                              () => setState(() => _pasteMode = false)),
                        ]),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: _pasteMode
                              ? KeyedSubtree(
                                  key: const ValueKey('paste'), child: _pasteBox())
                              : KeyedSubtree(
                                  key: const ValueKey('file'), child: _fileBox()),
                        ),
                      ),
                      const SizedBox(height: 16),
                      PButton(label: 'إنشاء', onPressed: _busy ? null : _create),
                    ]),
              ),
            ),
          ]),
        ),
      );

  Widget _pasteBox() => TextField(
        controller: _paste,
        expands: true,
        maxLines: null,
        minLines: null,
        textAlign: TextAlign.left,
        textAlignVertical: TextAlignVertical.top,
        textDirection: TextDirection.ltr,
        style: mono,
        cursorColor: C.accent,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          hintText: 'الصق الكود هنا',
          hintStyle: const TextStyle(color: C.dim),
          filled: true,
          fillColor: C.surface,
          contentPadding: const EdgeInsets.all(12),
          border: _ob,
          enabledBorder: _ob,
          focusedBorder: _obFocus,
        ),
      );

  Widget _fileBox() {
    final p = _picked;
    return Container(
      decoration: _box(C.surface),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(p == null ? Icons.folder_open_outlined : Icons.description_outlined,
              color: p == null ? C.muted : C.accent, size: 40),
          const SizedBox(height: 12),
          if (p == null)
            const Text('اختر ملف بايثون من جهازك',
                style: TextStyle(color: C.muted))
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(p.name,
                  textDirection: TextDirection.ltr,
                  textAlign: TextAlign.center,
                  style: mono.copyWith(fontSize: 15)),
            ),
          const SizedBox(height: 16),
          OButton(
            label: p == null ? 'اختيار ملف' : 'تغيير الملف',
            height: 44,
            minWidth: 140,
            onPressed: _pick,
          ),
        ]),
      ),
    );
  }
}

// ───────── المحرر: تلوين الكود ─────────
const _keywords = {
  'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await', 'break',
  'class', 'continue', 'def', 'del', 'elif', 'else', 'except', 'finally',
  'for', 'from', 'global', 'if', 'import', 'in', 'is', 'lambda', 'nonlocal',
  'not', 'or', 'pass', 'raise', 'return', 'try', 'while', 'with', 'yield'
};
const _builtins = {
  'print', 'input', 'len', 'range', 'int', 'str', 'float', 'list', 'dict',
  'set', 'tuple', 'open', 'type', 'sum', 'min', 'max', 'abs', 'sorted',
  'enumerate', 'zip', 'map', 'filter', 'bool', 'isinstance', 'round'
};

class CodeController extends TextEditingController {
  CodeController(String text)
      : super.fromValue(TextEditingValue(
            text: text, selection: TextSelection.collapsed(offset: text.length)));
  static final _tok = RegExp(
      r'''(#[^\n]*)|("[^"\n]*"|'[^'\n]*')|(\b\d+(?:\.\d+)?\b)|(\b[A-Za-z_][A-Za-z0-9_]*\b)''');

  @override
  TextSpan buildTextSpan(
      {required BuildContext context,
      TextStyle? style,
      required bool withComposing}) {
    final spans = <TextSpan>[];
    var i = 0;
    for (final m in _tok.allMatches(text)) {
      if (m.start > i) spans.add(TextSpan(text: text.substring(i, m.start)));
      final w = m[0]!;
      Color? col;
      var fs = FontStyle.normal;
      if (m[1] != null) {
        col = C.dim;
        fs = FontStyle.italic;
      } else if (m[2] != null) {
        col = C.ok;
      } else if (m[3] != null) {
        col = C.warn;
      } else if (_keywords.contains(w)) {
        col = C.accent;
      } else if (_builtins.contains(w)) {
        col = C.cyan;
      }
      spans.add(TextSpan(
          text: w,
          style: col == null ? null : TextStyle(color: col, fontStyle: fs)));
      i = m.end;
    }
    if (i < text.length) spans.add(TextSpan(text: text.substring(i)));
    return TextSpan(style: style, children: spans);
  }
}

// ───────── المحرر: المسافات والأقواس التلقائية ─────────
// يعمل فقط على إدخال/حذف حرف واحد عند المؤشر، ولا يتدخل أثناء الإدخال المركب
class PyEditFormatter extends TextInputFormatter {
  const PyEditFormatter();

  static const _pairs = {'(': ')', '[': ']', '{': '}', '"': '"', "'": "'"};
  static const _closers = {')', ']', '}'};
  static const _strPrefixes = {'r', 'b', 'u', 'f', 'rb', 'br', 'fr', 'rf'};
  static final _word = RegExp(r'[\p{L}\p{N}_]', unicode: true);
  static final _prefix =
      RegExp(r'(?:^|[^\p{L}\p{N}_])([A-Za-z]{1,2})$', unicode: true);
  static final _indent = RegExp(r'^[ \t]*');

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldV, TextEditingValue newV) {
    // لا نتدخل أثناء الإدخال المركب (العربية وغيرها)
    if (newV.composing.isValid && !newV.composing.isCollapsed) return newV;
    final os = oldV.selection, ns = newV.selection;
    if (!os.isValid || !os.isCollapsed || !ns.isValid || !ns.isCollapsed) {
      return newV;
    }
    final o = oldV.text, n = newV.text, pos = os.baseOffset;
    if (pos < 0 || pos > o.length) return newV;

    // إدخال حرف واحد عند المؤشر
    if (n.length == o.length + 1 &&
        ns.baseOffset == pos + 1 &&
        n.startsWith(o.substring(0, pos)) &&
        n.endsWith(o.substring(pos))) {
      final ch = n[pos];
      if (ch == '\n') return _enter(o, pos);
      if (_closers.contains(ch)) {
        // تجاوز قوس الإغلاق الموجود بدل إضافة قوس جديد
        if (pos < o.length && o[pos] == ch) return _skip(o, pos);
        return newV;
      }
      if (ch == '"' || ch == "'") return _quote(newV, o, pos, ch);
      final close = _pairs[ch];
      if (close != null) {
        // لا نُنشئ حرفاً إضافياً إذا كان حرف الإغلاق موجوداً بالفعل بعد المؤشر
        if (pos < o.length && o[pos] == close) return newV;
        return _make(
            o.substring(0, pos) + ch + close + o.substring(pos), pos + 1);
      }
      return newV;
    }

    // حذف حرف واحد قبل المؤشر (Backspace) داخل زوج فارغ
    if (n.length == o.length - 1 &&
        pos >= 1 &&
        pos < o.length &&
        ns.baseOffset == pos - 1 &&
        n == o.substring(0, pos - 1) + o.substring(pos)) {
      final del = o[pos - 1];
      final close = _pairs[del];
      if (close != null && o[pos] == close) {
        final isQuote = del == '"' || del == "'";
        // في الاقتباسات: نحذف الزوج فقط إذا كان الأول علامة فتح وليس إغلاق
        if (isQuote && _count(_lineBefore(o, pos - 1), del).isOdd) return newV;
        return _make(o.substring(0, pos - 1) + o.substring(pos + 1), pos - 1);
      }
    }
    return newV;
  }

  static TextEditingValue _make(String text, int caret) => TextEditingValue(
      text: text, selection: TextSelection.collapsed(offset: caret));

  static TextEditingValue _skip(String o, int pos) => _make(o, pos + 1);

  static String _lineBefore(String t, int pos) {
    final s = pos == 0 ? 0 : t.lastIndexOf('\n', pos - 1) + 1;
    return t.substring(s, pos);
  }

  static int _count(String s, String ch) {
    var c = 0;
    for (var i = 0; i < s.length; i++) {
      if (s[i] == ch) c++;
    }
    return c;
  }

  // Enter: نحافظ على مسافة السطر السابق، ونزيد 4 مسافات بعد ":"
  static TextEditingValue _enter(String o, int pos) {
    final before = _lineBefore(o, pos);
    final indent = _indent.firstMatch(before)![0]!;
    final code = before.trimRight();
    final more = code.endsWith(':') && !code.trimLeft().startsWith('#');
    final extra = more ? '    ' : '';
    final ins = '\n$indent$extra';
    return _make(o.substring(0, pos) + ins + o.substring(pos), pos + ins.length);
  }

  static bool _isStrPrefix(String before) {
    final m = _prefix.firstMatch(before);
    return m != null && _strPrefixes.contains(m[1]!.toLowerCase());
  }

  static TextEditingValue _quote(
      TextEditingValue newV, String o, int pos, String q) {
    final before = _lineBefore(o, pos);
    final inside = _count(before, q).isOdd; // نحن داخل نص مفتوح
    final next = pos < o.length ? o[pos] : '';
    final prev = pos > 0 ? o[pos - 1] : '';
    // تجاوز علامة الإغلاق
    if (next == q && inside) return _skip(o, pos);
    // لا نُنشئ زوجاً: الحرف التالي موجود، أو داخل نص، أو بعد نفس العلامة
    if (next == q || inside || prev == q) return newV;
    // فاصلة عليا داخل كلمة (don't) — إلا بادئة النص مثل f"..." أو r'...'
    if (_word.hasMatch(prev) && !_isStrPrefix(before)) return newV;
    return _make(o.substring(0, pos) + q + q + o.substring(pos), pos + 1);
  }
}

// ───────── شاشة المحرر ─────────
class ScriptScreen extends StatefulWidget {
  const ScriptScreen({super.key, required this.script});
  final Script script;

  @override
  State<ScriptScreen> createState() => _ScriptScreenState();
}

class _ScriptScreenState extends State<ScriptScreen>
    with WidgetsBindingObserver {
  final _code = CodeController('');
  final _focus = FocusNode();
  final _undo = UndoHistoryController();
  Timer? _timer;
  String? _lastSaved;
  bool _loading = true, _warned = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  // قراءة محتوى الملف الحقيقي داخل المحرر
  Future<void> _load() async {
    try {
      final text = await store.readCode(widget.script);
      if (!mounted) return;
      _code.value = TextEditingValue(
          text: text, selection: TextSelection.collapsed(offset: text.length));
      widget.script.code = text;
      _lastSaved = text;
      _code.addListener(_onChanged);
      setState(() => _loading = false);
    } catch (_) {
      if (!mounted) return;
      final m = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      m.showSnackBar(
          const SnackBar(content: Text('تعذّر فتح الملف، ربما حُذف أو نُقل')));
      store.refresh();
    }
  }

  // حفظ تلقائي: بعد توقف الكتابة لفترة قصيرة (بدون كتابة مع كل حرف)
  void _onChanged() {
    final t = _code.text;
    if (t == widget.script.code) return; // تغيير في المؤشر فقط
    widget.script.code = t;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 800), _save);
  }

  Future<void> _save() async {
    _timer?.cancel();
    if (_loading) return;
    final t = widget.script.code;
    if (t == _lastSaved) return;
    _lastSaved = t;
    final ok = await store.writeCode(widget.script, t);
    if (ok) {
      _warned = false;
    } else {
      _lastSaved = null; // تُعاد المحاولة عند التعديل التالي أو الحفظ النهائي
      if (mounted && !_warned) {
        _warned = true;
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تعذّر حفظ التعديلات في الملف')));
      }
    }
  }

  // حفظ نهائي فوري (مغادرة المحرر، التشغيل، الخروج من التطبيق)
  void _flush() {
    if (!_loading) unawaited(_save());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _flush();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _flush();
    _code.removeListener(_onChanged);
    _code.dispose();
    _focus.dispose();
    _undo.dispose();
    super.dispose();
  }

  void _leave() {
    _flush();
    Navigator.pop(context);
  }

  // التشغيل يفتح شاشة إخراج مستقلة
  Future<void> _openOutput() async {
    await _save();
    if (!mounted) return;
    _focus.unfocus();
    Navigator.push(context, smooth(OutputScreen(script: widget.script)));
  }

  Widget _historyBtn(
          IconData icon, String tip, bool enabled, VoidCallback onTap) =>
      PressFx(
        enabled: enabled,
        scale: .88,
        child: IconButton(
          tooltip: tip,
          color: C.text,
          disabledColor: C.dim.withValues(alpha: .45),
          onPressed: enabled ? onTap : null,
          icon: Icon(icon, textDirection: TextDirection.ltr),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(children: [
            Header(
              title: widget.script.name,
              back: true,
              mono: true,
              onBack: _leave,
              actions: [
                ValueListenableBuilder<UndoHistoryValue>(
                  valueListenable: _undo,
                  builder: (_, v, __) => Row(mainAxisSize: MainAxisSize.min, children: [
                    _historyBtn(Icons.redo, 'إعادة', v.canRedo, _undo.redo),
                    _historyBtn(Icons.undo, 'تراجع', v.canUndo, _undo.undo),
                  ]),
                ),
              ],
            ),
            Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                            strokeWidth: 2.4, color: C.accent))
                    : _editor()),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Row(children: [
                Expanded(
                    child: PButton(
                        label: 'تشغيل',
                        icon: Icons.play_arrow_rounded,
                        onPressed: _loading ? null : _openOutput)),
              ]),
            ),
          ]),
        ),
      );

  Widget _editor() => Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        decoration: _box(C.surface),
        clipBehavior: Clip.antiAlias,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _focus.requestFocus(),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ListenableBuilder(
                  listenable: _code,
                  builder: (_, __) => Text(
                    List.generate('\n'.allMatches(_code.text).length + 1,
                        (i) => '${i + 1}').join('\n'),
                    textAlign: TextAlign.right,
                    style: mono.copyWith(color: C.dim),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: TextField(
                    controller: _code,
                    focusNode: _focus,
                    undoController: _undo,
                    inputFormatters: const [PyEditFormatter()],
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    autocorrect: false,
                    enableSuggestions: false,
                    cursorColor: C.accent,
                    onTapOutside: (_) {},
                    style: mono,
                    decoration: const InputDecoration.collapsed(hintText: null),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
}

// ───────── شاشة الإخراج (Python حقيقي) ─────────

class Line {
  Line(this.text, [this.kind = 0]);
  String text;
  final int kind;
}

Color _lineColor(int k) => k == 1
    ? C.dim
    : k == 2
        ? C.accent
        : k == 3
            ? C.error
            : C.text;

class OutputScreen extends StatefulWidget {
  const OutputScreen({super.key, required this.script});
  final Script script;

  @override
  State<OutputScreen> createState() => _OutputScreenState();
}

class _OutputScreenState extends State<OutputScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _lines = <Line>[];
  final _rawOutput = StringBuffer();
  late final ScriptRunner _runner;
  StreamSubscription<BayanEvent>? _events;
  bool _stopRequested = false;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _runner = ScriptRunner(scriptPath: widget.script.path);
    _events = _runner.events.listen(_onEvent, onError: (Object error, StackTrace stack) {
      _add('$error', 3);
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _startRun());
  }

  @override
  void dispose() {
    _events?.cancel();
    _stopRequested = true;
    unawaited(_runner.dispose());
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  ScriptRunnerState get _runnerState => _runner.state;

  void _onEvent(BayanEvent e) {
    if (!mounted) return;
    switch (e.type) {
      case 'started':
      case 'error':
      case 'input':
      case 'state':
        setState(() {});
        if (e.type == 'error' && e.text.isNotEmpty) _add(e.text, 3);
        if (e.type == 'input' && e.text.isNotEmpty) _add(e.text, 2);
        break;
      case 'stdout':
        _appendOutput(e.text, 0);
        break;
      case 'stderr':
        _appendOutput(e.text, 3);
        break;
      case 'exit':
        final code = e.exitCode;
        if (code == 0) {
          _add('[انتهى بكود 0]', 1);
        } else if (code == 130) {
          if (!_stopRequested) _add('[تم إيقاف التشغيل]', 1);
        } else {
          _add('[انتهى بكود $code]', 3);
        }
        unawaited(store.markRun(widget.script));
        _stopRequested = false;
        setState(() {});
        break;
    }
  }

  void _add(String text, [int kind = 0]) {
    if (!mounted || text.isEmpty) return;
    setState(() => _lines.add(Line(text, kind)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _appendOutput(String text, int kind) {
    if (!mounted || text.isEmpty) return;
    _rawOutput.write(text);
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    setState(() {
      for (var i = 0; i < normalized.length; i++) {
        final ch = normalized[i];
        if (_lines.isEmpty) {
          _lines.add(Line('', kind));
        } else if (_lines.last.kind != kind) {
          _lines.add(Line('', kind));
        }
        if (ch == '\n') {
          _lines.add(Line('', kind));
        } else {
          _lines.last.text += ch;
        }
      }
      if (_lines.length > 5000) _lines.removeRange(0, _lines.length - 5000);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _startRun() async {
    if (!mounted || _starting) return;
    _starting = true;
    _stopRequested = false;
    setState(() {
      _lines.clear();
      _rawOutput.clear();
    });
    _add(r'$ python ' + widget.script.name, 1);
    try {
      await _runner.start();
    } catch (e) {
      if (mounted) _add('تعذر بدء Python: ${errText(e)}', 3);
    } finally {
      _starting = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _send() async {
    if (_runnerState != ScriptRunnerState.waitingForInput) return;
    final text = _input.text;
    _input.clear();
    _add('> $text', 2);
    try {
      await _runner.sendInput(text);
      if (mounted) setState(() {});
    } catch (e) {
      _add('تعذر إرسال الإدخال: ${errText(e)}', 3);
    }
  }

  Future<void> _stop() async {
    if (!_runner.isRunning) return;
    _stopRequested = true;
    try {
      await _runner.stop();
    } catch (e) {
      if (mounted) _add('تعذر إيقاف التشغيل: ${errText(e)}', 3);
    }
  }

  Future<void> _restart() async {
    if (_runner.isRunning) {
      _stopRequested = true;
      try {
        await _runner.stop();
      } catch (_) {}
      await _runner.waitForFinish(timeout: const Duration(milliseconds: 1600));
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (!mounted) return;
    await _startRun();
  }

  Future<void> _leave() async {
    _stopRequested = true;
    try {
      await _runner.stop();
      await _runner.waitForFinish(timeout: const Duration(milliseconds: 450));
    } catch (_) {}
    if (mounted) Navigator.pop(context);
  }

  void _copyOutput() {
    if (_lines.isEmpty) {
      _snack('لا يوجد إخراج للنسخ');
      return;
    }
    Clipboard.setData(ClipboardData(text: _rawOutput.toString()));
    _snack('تم نسخ الإخراج');
  }

  void _clearOutput() => setState(() {
    _lines.clear();
    _rawOutput.clear();
  });

  void _snack(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final idle = !_runner.isRunning;
    final waiting = _runnerState == ScriptRunnerState.waitingForInput;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Header(
                title: widget.script.name,
                back: true,
                mono: true,
                onBack: () => unawaited(_leave()),
              ),
              Expanded(child: _consoleBox(waiting)),
              _actionBar(idle),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionBar(bool idle) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Row(
          children: [
            Expanded(
              child: PButton(
                label: 'إعادة تشغيل',
                icon: Icons.replay_rounded,
                onPressed: _restart,
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 120,
              child: OButton(
                label: 'إيقاف',
                icon: Icons.stop_rounded,
                accent: false,
                height: 52,
                radius: 12,
                fontSize: 16,
                onPressed: idle ? null : _stop,
              ),
            ),
          ],
        ),
      );

  Widget _consoleBox(bool waiting) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      decoration: _box(C.console),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            height: 44,
            padding: const EdgeInsets.only(right: 14, left: 4),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.border))),
            child: Row(
              children: [
                const Expanded(
                  child: Text('الإخراج · تشغيل Python', style: TextStyle(fontSize: 12, color: C.muted)),
                ),
                PressFx(
                  scale: .88,
                  child: IconButton(
                    tooltip: 'نسخ',
                    iconSize: 20,
                    color: C.muted,
                    visualDensity: VisualDensity.compact,
                    onPressed: _copyOutput,
                    icon: const Icon(Icons.content_copy_outlined),
                  ),
                ),
                PressFx(
                  scale: .88,
                  child: IconButton(
                    tooltip: 'مسح',
                    iconSize: 22,
                    color: C.muted,
                    visualDensity: VisualDensity.compact,
                    onPressed: _clearOutput,
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _lines.isEmpty
                ? Center(
                    child: Text(
                      _runner.isRunning ? 'جاري تشغيل Python…' : 'اضغط "إعادة تشغيل" ليظهر الإخراج هنا',
                      style: const TextStyle(fontSize: 13, color: C.dim),
                    ),
                  )
                : Directionality(
                    textDirection: TextDirection.ltr,
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(14),
                      itemCount: _lines.length,
                      itemBuilder: (_, i) => Text(
                        _lines[i].text,
                        style: mono.copyWith(color: _lineColor(_lines[i].kind)),
                      ),
                    ),
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: C.border))),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: TextField(
                      controller: _input,
                      enabled: waiting,
                      onSubmitted: (_) => unawaited(_send()),
                      textInputAction: TextInputAction.send,
                      style: const TextStyle(fontSize: 14),
                      cursorColor: C.accent,
                      decoration: InputDecoration(
                        hintText: waiting ? 'اكتب هنا ثم أرسل' : 'في انتظار input()…',
                        hintStyle: const TextStyle(color: C.dim),
                        isDense: true,
                        filled: true,
                        fillColor: C.surface,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                        border: _ob,
                        enabledBorder: _ob,
                        disabledBorder: _ob,
                        focusedBorder: _obFocus,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                PressFx(
                  enabled: waiting,
                  child: Semantics(
                    button: true,
                    label: 'إرسال',
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        color: waiting ? C.accent : C.border,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: waiting ? C.accentEdge : C.outline),
                      ),
                      child: IconButton(
                        onPressed: waiting ? () => unawaited(_send()) : null,
                        color: waiting ? C.onAccent : C.dim,
                        tooltip: 'إرسال',
                        icon: const Icon(Icons.arrow_upward_rounded),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
