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
  static const borderHi = Color(0xFF2A3A58); // حد البطاقات المرفوعة (أفتح قليلاً من border)
}

const mono = TextStyle(
    fontFamily: 'monospace', fontSize: 14, height: 1.57, color: C.text);

// ظل ناعم يرفع البطاقات قليلاً عن الخلفية
const _shadow = <BoxShadow>[
  BoxShadow(color: Color(0x4D000000), blurRadius: 14, offset: Offset(0, 5)),
];

// raised: تدرج خفيف من الأعلى + حد أفتح + ظل (للبطاقات). بدونه: صندوق مسطح كما كان.
BoxDecoration _box(Color color, {bool raised = false}) => BoxDecoration(
    color: color,
    gradient: raised
        ? LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color.lerp(color, Colors.white, .045)!, color])
        : null,
    borderRadius: BorderRadius.circular(14),
    border: Border.all(color: raised ? C.borderHi : C.border),
    boxShadow: raised ? _shadow : null);

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

// ───────── قائمة التحديد بالعربية (نسخ / قص / لصق / تحديد الكل) ─────────
// تُمرَّر إلى contextMenuBuilder في كل حقول التطبيق وSelectableText.
Widget arContextMenu(BuildContext context, EditableTextState editable) {
  final items = <ContextMenuButtonItem>[];
  for (final item in editable.contextMenuButtonItems) {
    String? label;
    switch (item.type) {
      case ContextMenuButtonType.copy:
        label = 'نسخ';
        break;
      case ContextMenuButtonType.cut:
        label = 'قص';
        break;
      case ContextMenuButtonType.paste:
        label = 'لصق';
        break;
      case ContextMenuButtonType.selectAll:
        label = 'تحديد الكل';
        break;
      case ContextMenuButtonType.delete:
        label = 'حذف';
        break;
      default:
        label = null;
    }
    items.add(label == null ? item : item.copyWith(label: label));
  }
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: editable.contextMenuAnchors,
    buttonItems: items,
  );
}

/// قائمة التحديد العربية للنصوص القابلة للتحديد خارج حقول الكتابة.
Widget arSelectionContextMenu(
    BuildContext context, SelectableRegionState selectableRegionState) {
  final items = <ContextMenuButtonItem>[];
  for (final item in selectableRegionState.contextMenuButtonItems) {
    if (item.type == ContextMenuButtonType.copy) {
      items.add(item.copyWith(label: 'نسخ'));
    } else if (item.type == ContextMenuButtonType.selectAll) {
      items.add(item.copyWith(label: 'تحديد الكل'));
    }
  }
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: selectableRegionState.contextMenuAnchors,
    buttonItems: items,
  );
}

// يعيد بناء الواجهة كلما تغيّر طابور تثبيت المكتبات
class InstallerBuilder extends StatelessWidget {
  const InstallerBuilder({super.key, required this.builder});
  final Widget Function(BuildContext context, LibInstaller installer) builder;

  @override
  Widget build(BuildContext context) => StreamBuilder<int>(
        stream: libInstaller.changes,
        initialData: libInstaller.revision,
        builder: (context, _) => builder(context, libInstaller),
      );
}

// ───────── سطر في Traceback: File "…", line N ─────────
class FrameRef {
  const FrameRef(this.path, this.relative, this.line);
  final String path; // كما ظهر في Traceback
  final String relative; // المسار داخل مجلد Bayan 777
  final int line;
}

final _frameRe = RegExp(r'^\s*File "([^"]+)", line (\d+)');

// يرجع null إن لم يكن السطر إطارًا، أو كان الملف خارج مجلد Bayan 777
// (مثل مكتبات site-packages)، فلا يصبح قابلًا للضغط.
FrameRef? parseFrame(String text) {
  final m = _frameRe.firstMatch(text);
  if (m == null) return null;
  final path = m.group(1)!;
  final line = int.tryParse(m.group(2)!);
  if (line == null) return null;
  final marker = '/$kFolderName/';
  final at = path.indexOf(marker);
  if (at < 0) return null;
  final rel = path.substring(at + marker.length);
  if (!isPyName(rel) ||
      rel.contains('site-packages') ||
      rel.split('/').contains('..')) {
    return null;
  }
  return FrameRef(path, rel, line);
}

// ───────── منطقة التقدم داخل بطاقة المكتبة (ارتفاعها ثابت يحدده الأب) ─────────
class LibJobZone extends StatelessWidget {
  const LibJobZone({super.key, required this.job, this.onDetails, this.onDismiss});
  final LibJob job;
  final VoidCallback? onDetails;
  final VoidCallback? onDismiss;

  static String _stageLabel(String stage) {
    if (stage == 'download') return 'التنزيل';
    if (stage == 'install') return 'التثبيت';
    return 'التحضير';
  }

  @override
  Widget build(BuildContext context) {
    switch (job.state) {
      case JobState.queued:
        return const Row(children: [
          Icon(Icons.schedule_rounded, color: C.warn, size: 16),
          SizedBox(width: 6),
          Text('في الانتظار', style: TextStyle(fontSize: 12, color: C.warn)),
        ]);
      case JobState.running:
        final raw = (job.progress * 100).floor();
        final pct = raw > 100 ? 100 : raw;
        return Row(children: [
          SizedBox(
            width: 58,
            child: Text(_stageLabel(job.stage),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: C.muted)),
          ),
          Expanded(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: job.progress),
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              builder: (_, v, __) => ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: v,
                  minHeight: 4,
                  backgroundColor: C.border,
                  color: C.ok,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 36,
            child: Text('$pct%',
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.left,
                style: const TextStyle(fontSize: 11.5, color: C.muted)),
          ),
        ]);
      case JobState.done:
        return const Row(children: [
          Icon(Icons.check_circle_rounded, color: C.ok, size: 16),
          SizedBox(width: 6),
          Text('تم تثبيت المكتبة بنجاح',
              style: TextStyle(fontSize: 12, color: C.ok)),
        ]);
      case JobState.failed:
        return Row(children: [
          const Icon(Icons.error_outline_rounded, color: C.error, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(job.reason,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: C.error)),
          ),
          if (onDetails != null)
            InkWell(
              onTap: onDetails,
              borderRadius: BorderRadius.circular(6),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Text('التفاصيل',
                    style: TextStyle(fontSize: 12, color: C.accent)),
              ),
            ),
          if (onDismiss != null)
            InkWell(
              onTap: onDismiss,
              borderRadius: BorderRadius.circular(6),
              child: const Padding(
                padding: EdgeInsets.all(3),
                child: Icon(Icons.close_rounded, size: 16, color: C.muted),
              ),
            ),
        ]);
    }
  }
}

// تفاصيل فشل التثبيت (نافذة، فلا يتغير ارتفاع البطاقة)
void showInstallDetails(BuildContext context, LibJob job) {
  final text = job.details.isEmpty ? job.reason : job.details;
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: C.surface,
      title: Text(job.name,
          textDirection: TextDirection.ltr,
          style: mono.copyWith(fontSize: 16)),
      content: SingleChildScrollView(
        child: SelectableText(
          text,
          contextMenuBuilder: arContextMenu,
          style: const TextStyle(fontSize: 13, height: 1.5, color: C.text),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            Navigator.pop(ctx);
          },
          child: const Text('نسخ'),
        ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
      ],
    ),
  );
}

// ───────── بطاقة تثبيت مكتبة ناقصة (تظهر تحت الخطأ في شاشة الإخراج) ─────────
class MissingLib {
  MissingLib(this.package, this.module, {this.failed = false});
  final String package; // اسم التثبيت (opencv-python)
  final String module; // اسم الاستيراد (cv2)
  final bool failed; // هذه المكتبة هي التي أوقفت التشغيل (ModuleNotFoundError)
  bool checking = true;
  bool? available;
  String reason = '';
  String? version;
}

class MissingLibCard extends StatelessWidget {
  const MissingLibCard({super.key, required this.item});
  final MissingLib item;

  Widget _action(LibJob? job) {
    final key = pkgKey(item.package);
    if (job != null) {
      switch (job.state) {
        case JobState.queued:
          return Row(children: [
            const Icon(Icons.schedule_rounded, color: C.warn, size: 16),
            const SizedBox(width: 6),
            const Expanded(
              child: Text('في الانتظار',
                  style: TextStyle(fontSize: 13, color: C.warn)),
            ),
            OButton(
              label: 'إلغاء',
              accent: false,
              height: 36,
              radius: 10,
              fontSize: 13,
              onPressed: () => libInstaller.cancel(key),
            ),
          ]);
        case JobState.running:
        case JobState.done:
          return Center(child: LibJobZone(job: job));
        case JobState.failed:
          return OButton(
            label: 'إعادة المحاولة',
            icon: Icons.refresh_rounded,
            height: 44,
            radius: 10,
            onPressed: () => libInstaller.retry(key),
          );
      }
    }
    if (item.available == false) {
      return Row(children: [
        const Icon(Icons.info_outline_rounded, color: C.warn, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            item.reason.isEmpty ? 'لا توجد نسخة تعمل على أندرويد' : item.reason,
            style: const TextStyle(fontSize: 13, color: C.warn),
          ),
        ),
      ]);
    }
    return OButton(
      label: 'تثبيت',
      icon: Icons.download_rounded,
      height: 44,
      radius: 10,
      onPressed: () => libInstaller.enqueue(item.package),
    );
  }

  Widget _status(BuildContext context, LibJob? job) {
    if (job != null && job.state == JobState.failed) {
      return LibJobZone(job: job, onDetails: () => showInstallDetails(context, job));
    }
    if (job == null && item.checking) {
      return const Align(
        alignment: AlignmentDirectional.centerStart,
        child: Text('جارٍ التحقق من التوفر…',
            style: TextStyle(fontSize: 11.5, color: C.dim)),
      );
    }
    final v = item.version;
    if (job == null && item.available == true && v != null && v.isNotEmpty) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: Text('أحدث نسخة: $v',
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontSize: 11.5, color: C.dim)),
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) => InstallerBuilder(
        builder: (context, installer) {
          final job = installer.jobFor(pkgKey(item.package));
          return Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            decoration: _box(C.surface),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  const Icon(Icons.extension_outlined, color: C.accent, size: 19),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(item.package,
                        textDirection: TextDirection.ltr,
                        textAlign: TextAlign.right,
                        overflow: TextOverflow.ellipsis,
                        style: mono.copyWith(fontSize: 15)),
                  ),
                  if (item.module != item.package)
                    Text('import ${item.module}',
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(fontSize: 11, color: C.dim)),
                ]),
                const SizedBox(height: 10),
                SizedBox(height: 44, child: _action(job)),
                const SizedBox(height: 6),
                SizedBox(height: 22, child: _status(context, job)),
              ],
            ),
          );
        },
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
          fontFamily: 'Tajawal',
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
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
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
      child: Container(
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: on
              ? const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF6B9EFF), C.accent])
              : null,
          color: on ? null : C.accent.withValues(alpha: .35),
          boxShadow: on
              ? [
                  BoxShadow(
                      color: C.accent.withValues(alpha: .30),
                      blurRadius: 16,
                      offset: const Offset(0, 6))
                ]
              : null,
        ),
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.transparent,
            disabledBackgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: C.onAccent,
            disabledForegroundColor: C.onAccent,
            side: BorderSide(
                color: on ? C.accentEdge : C.accentEdge.withValues(alpha: .25)),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
            textStyle: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w800),
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
            backgroundColor: line.withValues(alpha: on ? .08 : .03),
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

// علم يُحفظ بعد أول ظهور لشاشة الترحيب (الصلاحيات)
const _welcomeFlag = 'welcome_seen_v1';

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
    unawaited(runHub.init());
    if (!store.getFlag(_welcomeFlag)) {
      // الترحيب يشمل إذن الملفات، فلا نعرض نافذته المنفصلة في هذه المرة
      _asked = true;
      await _showWelcome();
      return;
    }
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
    if (state == AppLifecycleState.resumed) {
      store.onResume();
      unawaited(runHub.refresh());
    }
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
            ? 'لحفظ ملفاتك في مجلد "Bayan 777"، فعّل إذن «الوصول إلى جميع الملفات» ثم ارجع للتطبيق.'
            : 'لحفظ ملفاتك في مجلد "Bayan 777"، امنح إذن التخزين.'),
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

  // شاشة الترحيب عند أول فتح؛ تُعدّ مشاهَدة مهما كانت طريقة الخروج منها
  Future<void> _showWelcome() async {
    if (!mounted) return;
    await Navigator.of(context)
        .push<void>(smooth<void>(const PermissionsScreen(welcome: true)));
    await store.setFlag(_welcomeFlag, true);
  }

  // «فحص الصلاحيات» من القائمة؛ وعند الرجوع تُفتح القائمة مجدداً كما كانت
  Future<void> _openPermissions() async {
    final nav = Navigator.of(context);
    nav.pop(); // يغلق القائمة الجانبية
    await nav.push<void>(smooth<void>(const PermissionsScreen()));
    if (!mounted) return;
    _key.currentState?.openEndDrawer();
  }


  @override
  Widget build(BuildContext context) => Scaffold(
        key: _key,
        endDrawer: AppDrawer(
            onLibraries: _openLibraries, onPermissions: _openPermissions),
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
                    'امنح إذن الملفات لحفظ سكربتاتك في Bayan 777.',
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
          const Text('اضغط «سكربت جديد» للبدء',
              textAlign: TextAlign.center,
              style: TextStyle(color: C.muted, fontSize: 14)),
        ]),
      );
}

class ScriptTile extends StatelessWidget {
  const ScriptTile({super.key, required this.script});
  final Script script;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: runHub,
        builder: (context, _) => _tile(context),
      );

  Widget _tile(BuildContext context) {
    final info = runHub.infoFor(script.path);
    final live = info != null &&
        (info.status == RunStatus.running ||
            info.status == RunStatus.waiting ||
            info.status == RunStatus.error);
    final tile = Material(
      color: C.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: C.borderHi)),
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
                      RunDot(status: info?.status),
                      const SizedBox(width: 8),
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
                    if (live) ...[
                      const SizedBox(height: 3),
                      _statusLine(info),
                    ],
                  ]),
            ),
            const Icon(Icons.chevron_left,
                color: C.muted, size: 22, textDirection: TextDirection.ltr),
          ]),
        ),
      ),
    );
    return Container(
      decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14), boxShadow: _shadow),
      child: tile,
    );
  }

  // أخضر «يعمل منذ 02:15» (مؤقت حي) · عنبري «ينتظر إدخال» · أحمر «انتهى بكود N».
  // لا شيء في بقية الحالات (لا تواريخ في البطاقة).
  Widget _statusLine(RunInfo? info) {
    if (info != null && info.status == RunStatus.running) {
      return ValueListenableBuilder<int>(
        valueListenable: runHub.clock,
        builder: (context, tick, child) => Text(
          'يعمل منذ ${fmtElapsed(DateTime.now().difference(info.startedAt))}',
          style: TextStyle(fontSize: 12, color: RunDot.colorOf(info.status)),
        ),
      );
    }
    if (info != null && info.status == RunStatus.waiting) {
      return Text('ينتظر إدخال',
          style: TextStyle(fontSize: 12, color: RunDot.colorOf(info.status)));
    }
    if (info != null && info.status == RunStatus.error) {
      final code = info.exitCode;
      return Text(code == null ? 'انتهى بخطأ' : 'انتهى بكود $code',
          style: TextStyle(fontSize: 12, color: RunDot.colorOf(info.status)));
    }
    return const SizedBox.shrink();
  }
}

String fmtElapsed(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final sec = total % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}

/// نقطة حال السكربت: أخضر يعمل، عنبري ينتظر إدخالًا، أحمر انتهى بخطأ،
/// ورمادي في بقية الحالات (انتهى بنجاح أو موقوف، وأغمق إن لم تكن له جلسة).
class RunDot extends StatelessWidget {
  const RunDot({super.key, required this.status});
  final RunStatus? status;

  static Color colorOf(RunStatus? s) {
    switch (s) {
      case RunStatus.running:
        return C.ok;
      case RunStatus.waiting:
        return C.warn;
      case RunStatus.error:
        return C.error;
      case RunStatus.finished:
      case RunStatus.stopped:
        return C.dim;
      case null:
        return C.outline;
    }
  }

  static String labelOf(RunStatus? s) {
    switch (s) {
      case RunStatus.running:
        return 'يعمل';
      case RunStatus.waiting:
        return 'ينتظر إدخالًا';
      case RunStatus.finished:
        return 'انتهى';
      case RunStatus.error:
        return 'انتهى بخطأ';
      case RunStatus.stopped:
        return 'موقوف';
      case null:
        return 'لا توجد جلسة';
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
        label: labelOf(status),
        child: Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(shape: BoxShape.circle, color: colorOf(status)),
        ),
      );
}

/// كل تشغيل جديد يمر من هنا (سكربت واحد في كل مرة الآن).
/// true = المكان فارغ ويمكن بدء التشغيل.
/// - يعمل سكربت آخر: نافذة «سكربت آخر يعمل» (إيقافه وتشغيل هذا؟).
/// - تعمل نسخة قديمة من هذا السكربت نفسه (نصه تغيّر): نافذة «إيقاف النسخة القديمة وتشغيل الجديدة؟».
/// confirmOwnOldRun = false لزر «إعادة تشغيل» في شاشة الإخراج: المستخدم طلب الإيقاف بنفسه.
Future<bool> claimRunSlot(BuildContext context, Script script,
    {bool confirmOwnOldRun = true}) async {
  final other = runSlot.occupant;
  if (other == null) return true;
  final sameScript = other.scriptPath == script.path;
  if (!sameScript || confirmOwnOldRun) {
    final otherName =
        other.scriptPath.substring(other.scriptPath.lastIndexOf('/') + 1);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.surface,
        title: Text(sameScript
            ? 'إيقاف النسخة القديمة وتشغيل الجديدة؟'
            : 'سكربت آخر يعمل'),
        content: Text(sameScript
            ? 'النسخة السابقة من هذا السكربت ما زالت تعمل بالنص القديم.'
            : 'يعمل الآن $otherName. إيقافه وتشغيل هذا؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('إيقاف وتشغيل')),
        ],
      ),
    );
    if (ok != true) return false;
  }
  final freed = await runSlot.release();
  if (!freed && context.mounted) {
    _toast(context,
        'السكربت الذي يعمل لم يتوقف بعد (قد يكون عالقًا في عملية شبكة أو ملف). حاول بعد قليل، أو أوقفه من إشعار «مشغّل بايثون»');
  }
  return freed;
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
                  icon: Icons.receipt_long_outlined,
                  label: 'سجل الإخراج',
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.of(context).push(smooth<void>(LogScreen(script: s)));
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

/// سكربت يعمل الآن (أو ينتظر إدخالًا) لا يُعاد تسميته ولا يُحذف: الجلسة مرتبطة بمساره.
/// true = ممنوع (تظهر الرسالة إن كانت الشاشة ما زالت قائمة).
bool _blockedWhileRunning(BuildContext context, Script s) {
  if (runHub.infoFor(s.path)?.isLive != true) return false;
  if (context.mounted) _toast(context, 'أوقف السكربت أولًا');
  return true;
}

Future<void> togglePin(BuildContext context, Script s) async {
  try {
    await store.setPinned(s, !s.pinned);
  } catch (_) {
    if (context.mounted) _toast(context, 'تعذّر حفظ حالة التثبيت');
  }
}

Future<void> renameScript(BuildContext context, Script s) async {
  if (_blockedWhileRunning(context, s)) return;
  final ctl = TextEditingController(text: s.name);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: C.surface,
      title: const Text('إعادة تسمية'),
      content: TextField(
        contextMenuBuilder: arContextMenu,
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
  // قد يبدأ التشغيل أثناء النافذة المفتوحة: نعيد الفحص قبل التنفيذ
  if (_blockedWhileRunning(context, s)) return;
  final oldPath = s.path;
  try {
    final r = await store.rename(s, result);
    if (r != null && r.path != oldPath) {
      unawaited(runHub.moved(oldPath, r.path));
      try {
        final moved = await bayanPython.logsMove(from: oldPath, to: r.path);
        if (!moved && context.mounted) {
          _toast(context, 'تمت إعادة التسمية لكن تعذّر نقل سجل الإخراج');
        }
      } catch (_) {
        if (context.mounted) {
          _toast(context, 'تمت إعادة التسمية لكن تعذّر نقل سجل الإخراج');
        }
      }
    }
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
  if (_blockedWhileRunning(context, s)) return;
  final m = ScaffoldMessenger.of(context);
  final deletedPath = s.path;
  DeletedScript? d;
  try {
    d = await store.delete(s);
  } catch (_) {
    m.clearSnackBars();
    m.showSnackBar(const SnackBar(content: Text('تعذّر حذف الملف')));
    return;
  }
  if (d == null) return;
  unawaited(runHub.discarded(deletedPath));

  // نحجز السجل بعد نجاح حذف الملف، حتى لا تُفقد السجلات إن فشل الحذف نفسه.
  var logTrashed = false;
  var logTrashFailed = false;
  try {
    logTrashed = await bayanPython.logsTrash(deletedPath);
  } catch (_) {
    logTrashFailed = true;
  }

  final gone = d;
  m.clearSnackBars();
  final controller = m.showSnackBar(SnackBar(
    content: Text(logTrashFailed
        ? 'تم حذف ${gone.name} (تعذّر نقل سجل الإخراج مؤقتًا)'
        : 'تم حذف ${gone.name}'),
    action: SnackBarAction(
      label: 'تراجع',
      onPressed: () async {
        late final Script r;
        try {
          r = await store.restore(gone);
        } catch (_) {
          if (logTrashed) {
            try {
              await bayanPython.logsPurge(deletedPath);
            } catch (_) {}
          }
          if (context.mounted) {
            m.clearSnackBars();
            m.showSnackBar(const SnackBar(content: Text('تعذّرت استعادة الملف')));
          }
          return;
        }

        // فشل استعادة السجل لا يعني أن استعادة ملف السكربت نفسها فشلت.
        if (logTrashed) {
          var logRestored = false;
          try {
            logRestored = await bayanPython.logsUntrash(
              deletedPath,
              restoreAs: r.path,
            );
          } catch (_) {}
          if (!logRestored) {
            try {
              await bayanPython.logsPurge(deletedPath);
            } catch (_) {}
            if (context.mounted) {
              _toast(context, 'تمت استعادة الملف لكن تعذّر استعادة سجل الإخراج');
            }
          }
        }
        if (r.name != gone.name && context.mounted) {
          _toast(context, 'تمت الاستعادة باسم ${r.name}');
        }
      },
    ),
  ));
  // يُحذف الملف المؤقت عند انقضاء الإشعار أو إغلاقه، ويُترك فقط عند ضغط «تراجع».
  unawaited(controller.closed.then((reason) async {
    if (!logTrashed || reason == SnackBarClosedReason.action) return;
    try {
      await bayanPython.logsPurge(deletedPath);
    } catch (_) {
      // تنظيف .trash عند بدء التطبيق يغطي أي فشل عابر هنا.
    }
  }));
}

// ───────── القائمة الجانبية ─────────
class AppDrawer extends StatelessWidget {
  const AppDrawer(
      {super.key, required this.onLibraries, required this.onPermissions});
  final VoidCallback onLibraries, onPermissions;

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
                  const SizedBox(height: 4),
                  _nav(Icons.verified_user_outlined, 'فحص الصلاحيات', false,
                      onPermissions),
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

// ───────── شاشة الصلاحيات: الترحيب عند أول فتح + «فحص الصلاحيات» من القائمة ─────────
enum _PermState { granted, missing, manual }

class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key, this.welcome = false});

  /// true: شاشة الترحيب (بلا زر رجوع، وفيها «تخطٍّ» لكل صلاحية وزر متابعة).
  final bool welcome;

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  SystemStatus _sys = const SystemStatus();
  bool _busy = false;
  final _skipped = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // بعد العودة من صفحة إعدادات النظام نعيد الفحص
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    SystemStatus next = _sys;
    try {
      next = await bayanSystem.status();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _sys = next);
  }

  void _snack(String m) {
    final s = ScaffoldMessenger.of(context);
    s.clearSnackBars();
    s.showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) _snack(errText(e));
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _refresh();
  }

  Future<void> _grantFiles() => store.requestAccess();

  Future<void> _grantNotifications() => bayanSystem.requestNotifications();

  Future<void> _grantBattery() async {
    final how = await bayanSystem.requestBattery();
    if (how == 'list') {
      if (mounted) {
        _snack('اختر «كل التطبيقات» ثم مشغّل بايثون ثم «عدم التحسين».');
      }
    } else if (how == 'app') {
      if (mounted) {
        _snack('افتح «البطارية» من إعدادات التطبيق واختر «بلا قيود».');
      }
    } else if (how == 'failed') {
      if (mounted) _snack('تعذّر فتح إعدادات البطارية.');
    }
  }

  Future<void> _openAutoStart() async {
    final how = await bayanSystem.openAutoStart();
    if (how == 'app') {
      if (mounted) _snack('فتحنا إعدادات التطبيق بدل صفحة الشركة.');
    } else if (how == 'failed') {
      if (mounted) _snack('تعذّر فتح الإعدادات.');
    }
  }

  Future<void> _openBrandBattery() async {
    final how = await bayanSystem.openBrandBattery();
    if (how == 'app') {
      if (mounted) _snack('فتحنا إعدادات التطبيق بدل صفحة الشركة.');
    } else if (how == 'failed') {
      if (mounted) _snack('تعذّر فتح الإعدادات.');
    }
  }

  Future<void> _openAppSettings() async {
    final ok = await bayanSystem.openAppSettings();
    if (!ok && mounted) _snack('تعذّر فتح الإعدادات.');
  }

  Future<void> _openDeveloper() async {
    final how = await bayanSystem.openDeveloperOptions();
    if (how == 'about') {
      if (mounted) _snack('فعّل خيارات المطور: اضغط 7 مرات على «رقم الإصدار».');
    } else if (how == 'failed') {
      if (mounted) _snack('تعذّر فتح الإعدادات.');
    }
  }

  Widget _card({
    required int index,
    required String id,
    required IconData icon,
    required String title,
    required String why,
    required _PermState state,
    required String actionLabel,
    required Future<void> Function() onAction,
  }) {
    final skipped = _skipped.contains(id) && state != _PermState.granted;
    final Color tone = state == _PermState.granted
        ? C.ok
        : (state == _PermState.missing ? C.warn : C.muted);
    final String chip = state == _PermState.granted
        ? 'ممنوح'
        : (state == _PermState.missing ? 'غير ممنوح' : 'إعداد يدوي');
    return Appear(
      index: index,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: _box(C.surface, raised: true),
        child: Opacity(
          opacity: skipped ? .6 : 1,
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: tone.withValues(alpha: .14),
                        border:
                            Border.all(color: tone.withValues(alpha: .35))),
                    child: Icon(icon, color: tone, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Text(title,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600))),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                        color: tone.withValues(alpha: .14),
                        borderRadius: BorderRadius.circular(20)),
                    child: Text(chip,
                        style: TextStyle(
                            fontSize: 12,
                            color: tone,
                            fontWeight: FontWeight.w600)),
                  ),
                ]),
                const SizedBox(height: 10),
                Text(why,
                    style: const TextStyle(
                        fontSize: 13.5, height: 1.6, color: C.muted)),
                if (state != _PermState.granted) ...[
                  const SizedBox(height: 12),
                  Row(children: [
                    OButton(
                        label: actionLabel,
                        height: 38,
                        fontSize: 13,
                        onPressed: _busy ? null : () => _run(onAction)),
                    if (widget.welcome && !skipped) ...[
                      const SizedBox(width: 8),
                      TextButton(
                          onPressed: () => setState(() => _skipped.add(id)),
                          child: const Text('تخطٍّ',
                              style: TextStyle(color: C.muted))),
                    ],
                    if (skipped)
                      const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Text('تم التخطي',
                              style: TextStyle(fontSize: 12, color: C.dim))),
                  ]),
                ],
              ]),
        ),
      ),
    );
  }

  // بطاقة اختصار: الضغط عليها يفتح صفحة الإعداد مباشرة (عنوان + سطر قصير)
  Widget _shortcut({
    required int index,
    required IconData icon,
    required String title,
    required String hint,
    required Future<void> Function() onTap,
  }) =>
      Appear(
        index: index,
        child: PressFx(
          scale: .985,
          child: Container(
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14), boxShadow: _shadow),
            child: Material(
              color: C.surface,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: const BorderSide(color: C.borderHi)),
              child: InkWell(
                onTap: _busy ? null : () => _run(onTap),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: C.accent.withValues(alpha: .12),
                          border: Border.all(
                              color: C.accent.withValues(alpha: .35))),
                      child: Icon(icon, color: C.accent, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title,
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w600)),
                            if (hint.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(hint,
                                  style: const TextStyle(
                                      fontSize: 12.5, color: C.muted)),
                            ],
                          ]),
                    ),
                    const Icon(Icons.chevron_left,
                        color: C.muted,
                        size: 22,
                        textDirection: TextDirection.ltr),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );

  // سطر قصير بلا زر (لما لا يمكن فتحه من التطبيق)
  Widget _tip(int index, IconData icon, String text) => Appear(
        index: index,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(children: [
            Icon(icon, color: C.dim, size: 18),
            const SizedBox(width: 8),
            Expanded(
                child: Text(text,
                    style: const TextStyle(fontSize: 12.5, color: C.dim))),
          ]),
        ),
      );

  // اختصارات الشركة + خيارات المطور. صفحات الشركات لا يمكن فحص وجودها مسبقًا،
  // فإن لم تُفتح الصفحة تُفتح إعدادات التطبيق ويظهر تنبيه قصير.
  List<Widget> _shortcuts(int start) {
    final items = <Widget>[];
    var k = start;
    void add(IconData icon, String title, String hint,
        Future<void> Function() onTap) {
      items.add(const SizedBox(height: 12));
      items.add(_shortcut(
          index: k++, icon: icon, title: title, hint: hint, onTap: onTap));
    }

    switch (_sys.oem) {
      case 'xiaomi':
        add(Icons.play_circle_outline, 'التشغيل التلقائي', 'فعّل التطبيق',
            _openAutoStart);
        add(Icons.tune, 'توفير البطارية', 'اختر «بلا قيود»',
            _openBrandBattery);
        break;
      case 'samsung':
        add(Icons.tune, 'حدود الخلفية', 'أضفه إلى Never sleeping apps',
            _openAutoStart);
        break;
      case 'huawei':
        add(Icons.play_circle_outline, 'تشغيل التطبيقات',
            'إدارة يدوية ← فعّل الكل', _openAutoStart);
        break;
      case 'oppo':
      case 'oneplus':
        add(Icons.play_circle_outline, 'التشغيل التلقائي', 'فعّل التطبيق',
            _openAutoStart);
        add(Icons.tune, 'نشاط الخلفية', 'اسمح بالتشغيل في الخلفية',
            _openAppSettings);
        break;
      case 'vivo':
        add(Icons.play_circle_outline, 'التشغيل التلقائي', 'فعّل التطبيق',
            _openAutoStart);
        add(Icons.tune, 'استهلاك الخلفية', 'اسمح بالاستهلاك العالي',
            _openAppSettings);
        break;
      case 'transsion':
        add(Icons.play_circle_outline, 'التشغيل التلقائي', 'فعّل التطبيق',
            _openAutoStart);
        add(Icons.tune, 'نشاط الخلفية', 'Allow background activity',
            _openAppSettings);
        break;
      case 'asus':
        add(Icons.play_circle_outline, 'التشغيل التلقائي', 'فعّل التطبيق',
            _openAutoStart);
        break;
      default:
        break;
    }
    add(Icons.developer_mode, 'خيارات المطور',
        'أوقف «Suspend execution for cached apps»', _openDeveloper);
    if (_sys.oem.isNotEmpty) {
      items.add(const SizedBox(height: 14));
      items.add(_tip(k++, Icons.lock_outline, 'اقفل التطبيق في قائمة الأخيرة'));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(children: [
            Header(
                title: widget.welcome ? 'مرحبًا بك' : 'فحص الصلاحيات',
                back: !widget.welcome),
            Expanded(
              child: ListenableBuilder(
                listenable: fallbackMode,
                builder: (context, _) {
                  final filesOk = !fallbackMode.value;
                  final missing = (filesOk ? 0 : 1) +
                      (_sys.notifications ? 0 : 1) +
                      (_sys.battery ? 0 : 1);
                  var i = 0;
                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (widget.welcome) ...[
                        const Text(
                            'امنح هذه الصلاحيات لتستمر سكربتاتك في الخلفية.',
                            style: TextStyle(
                                fontSize: 14, height: 1.7, color: C.muted)),
                        const SizedBox(height: 16),
                      ],
                      _card(
                        index: i++,
                        id: 'files',
                        icon: Icons.folder_open_outlined,
                        title: 'الوصول إلى الملفات',
                        why: 'لحفظ ملفاتك',
                        state:
                            filesOk ? _PermState.granted : _PermState.missing,
                        actionLabel: 'منح',
                        onAction: _grantFiles,
                      ),
                      const SizedBox(height: 12),
                      _card(
                        index: i++,
                        id: 'notifications',
                        icon: Icons.notifications_none,
                        title: 'الإشعارات',
                        why: 'لإظهار ما يعمل في الخلفية',
                        state: _sys.notifications
                            ? _PermState.granted
                            : _PermState.missing,
                        actionLabel: 'منح',
                        onAction: _grantNotifications,
                      ),
                      const SizedBox(height: 12),
                      _card(
                        index: i++,
                        id: 'battery',
                        icon: Icons.battery_charging_full,
                        title: 'استثناء البطارية',
                        why: 'لتستمر السكربتات مع قفل الشاشة',
                        state: _sys.battery
                            ? _PermState.granted
                            : _PermState.missing,
                        actionLabel: 'منح',
                        onAction: _grantBattery,
                      ),
                      ..._shortcuts(i),
                      const SizedBox(height: 16),
                      const Text(
                          'قد تُنهي بعض الأجهزة التطبيقات رغم كل الإعدادات.',
                          style: TextStyle(
                              fontSize: 12.5, height: 1.7, color: C.dim)),
                      if (widget.welcome) ...[
                        const SizedBox(height: 20),
                        PButton(
                            label: missing == 0 ? 'متابعة' : 'تخطّي الآن',
                            onPressed: () => Navigator.pop(context)),
                      ],
                    ],
                  );
                },
              ),
            ),
          ]),
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
  // مفاتيح المكتبات المعروضة في قسم «المثبتة». لا تتغير أثناء التثبيت
  // حتى لا تقفز البطاقات من مكانها؛ تُحدَّث بعد انتهاء كل العمليات.
  Set<String> _shown = <String>{};
  List<CatalogPackage> _catalog = const <CatalogPackage>[];
  StreamSubscription<int>? _installerSub;
  bool _loading = true;
  bool _refreshing = false;
  bool _needsRefresh = false;
  bool _wasLive = false;
  bool _companionsOpen = false;

  @override
  void initState() {
    super.initState();
    _wasLive = libInstaller.hasLiveJobs;
    _installerSub = libInstaller.changes.listen(_onInstaller);
    _load();
  }

  @override
  void dispose() {
    _installerSub?.cancel();
    super.dispose();
  }

  void _syncShown() {
    // المطلوبة فقط؛ المكتبات المرافقة تظهر في قسمها المطوي أسفل القائمة
    _shown = {
      for (final e in _packages.entries)
        if (e.value.requested) e.key,
    };
  }

  void _onInstaller(int _) {
    if (!mounted) return;
    if (libInstaller.consumeCompleted()) _needsRefresh = true;
    // نحدّث قائمة المثبّت بعد آخر عملية فقط (لا أثناء تثبيت لاحق في الطابور)
    if (_needsRefresh && !libInstaller.busy) {
      _needsRefresh = false;
      unawaited(_refresh(silent: true));
    }
    final live = libInstaller.hasLiveJobs;
    if (_wasLive && !live) setState(_syncShown);
    _wasLive = live;
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
          ..addEntries(installed.map((p) => MapEntry(pkgKey(p.name), p)));
        _catalog = catalog;
        _loading = false;
        _syncShown();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('تعذر فتح مدير المكتبات: ${errText(e)}');
    }
  }

  Future<void> _refresh({bool silent = false}) async {
    if (_refreshing) return;
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
          ..addEntries(installed.map((p) => MapEntry(pkgKey(p.name), p)));
        _catalog = catalog;
        if (!libInstaller.hasLiveJobs) _syncShown();
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

  // التثبيت يدخل الطابور؛ تثبيت واحد فقط يعمل في كل مرة
  void _install(String spec) {
    final clean = spec.trim();
    if (clean.isEmpty) {
      _snack('اكتب اسم المكتبة أولاً');
      return;
    }
    libInstaller.enqueue(clean);
  }

  // المكتبات المرافقة التي ستُزال مع [package] لأن أي مكتبة أخرى لن تحتاجها بعد إزالتها.
  // نفس منطق remove_package في بايثون: ما لا يمكن الوصول إليه من المكتبات المطلوبة المتبقية.
  List<InstalledPackage> _orphansAfterRemoving(InstalledPackage package) {
    final removedKey = pkgKey(package.name);
    final alive = <String>{};
    final stack = <String>[
      for (final e in _packages.entries)
        if (e.key != removedKey && e.value.requested) e.key,
    ];
    while (stack.isNotEmpty) {
      final key = stack.removeLast();
      if (!alive.add(key)) continue;
      final current = _packages[key];
      if (current == null) continue;
      for (final dep in current.requires) {
        final depKey = pkgKey(dep);
        if (depKey != removedKey &&
            _packages.containsKey(depKey) &&
            !alive.contains(depKey)) {
          stack.add(depKey);
        }
      }
    }
    final orphans = <InstalledPackage>[
      for (final e in _packages.entries)
        if (e.key != removedKey && !e.value.requested && !alive.contains(e.key))
          e.value,
    ];
    orphans.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return orphans;
  }

  Future<void> _remove(InstalledPackage package) async {
    if (libInstaller.busy) {
      _snack('انتظر حتى تنتهي عملية المكتبة الحالية');
      return;
    }
    final orphans = _orphansAfterRemoving(package);
    final needing = package.requiredBy;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.surface,
        title: const Text('إزالة المكتبة'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('هل تريد إزالة ${package.name}؟\nلن يتم حذف ملفات سكربتاتك.'),
            if (orphans.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('ستُزال معها لأنها لا تحتاجها مكتبة أخرى:'),
              const SizedBox(height: 4),
              Text(
                orphans.map((p) => p.name).join('، '),
                textDirection: TextDirection.ltr,
                style: mono.copyWith(fontSize: 13, color: C.muted),
              ),
            ],
            if (needing.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'تنبيه: تحتاجها ${needing.join('، ')}، وقد تتوقف عن العمل بعد إزالتها.',
                style: const TextStyle(color: C.warn),
              ),
            ],
          ],
        ),
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
      if (mounted) {
        setState(_syncShown);
        _snack(orphans.isEmpty
            ? 'تمت إزالة ${package.name}'
            : 'تمت إزالة ${package.name} مع ${orphans.length} مكتبة مرافقة');
      }
    } catch (e) {
      if (mounted) _snack('تعذر إزالة المكتبة: ${errText(e)}');
    }
  }

  Future<void> _downloadUnknown() async {
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
                contextMenuBuilder: arContextMenu,
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
                contextMenuBuilder: arContextMenu,
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
      if (spec != null && mounted) _install(spec);
    } finally {
      name.dispose();
      version.dispose();
    }
  }

  CatalogPackage? _catalogFor(String name) {
    final key = pkgKey(name);
    for (final p in _catalog) {
      if (pkgKey(p.name) == key) return p;
    }
    return null;
  }

  // ───── أجزاء البطاقة ─────
  Widget _trailing(
      Lib lib, InstalledPackage? installed, CatalogPackage? cat, LibJob? job) {
    final key = pkgKey(lib.name);
    if (job != null && job.state == JobState.queued) {
      return OButton(
        label: 'إلغاء',
        accent: false,
        height: 42,
        radius: 10,
        onPressed: () => libInstaller.cancel(key),
      );
    }
    if (job != null && job.state == JobState.running) {
      return const Text('جارٍ التثبيت', style: TextStyle(fontSize: 12, color: C.muted));
    }
    if (job != null && job.state == JobState.failed) {
      return OButton(
        label: 'إعادة المحاولة',
        height: 42,
        radius: 10,
        fontSize: 12.5,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        onPressed: () => libInstaller.retry(key),
      );
    }
    if (installed == null) {
      if (job != null && job.state == JobState.done) {
        return const Icon(Icons.check_circle_rounded, color: C.ok, size: 22);
      }
      if (cat != null && !cat.compatible) {
        return const Text('غير متوافقة', style: TextStyle(fontSize: 12, color: C.dim));
      }
      return OButton(
        label: 'تثبيت',
        height: 42,
        radius: 10,
        fontSize: 14,
        onPressed: () => _install(lib.name),
      );
    }
    final latest = cat?.latestVersion;
    if (cat?.updateAvailable == true && latest != null) {
      return PButton(
        label: 'تحديث',
        height: 42,
        radius: 10,
        fontSize: 14,
        onPressed: libInstaller.busy ? null : () => _install('${lib.name}==$latest'),
      );
    }
    // الإزالة في الصف السفلي من البطاقة (_installedZone)، فلا شيء هنا
    return const SizedBox.shrink();
  }

  // زر إزالة بإطار أحمر، عند الطرف الأيسر من الصف السفلي
  Widget _removeButton(InstalledPackage p, {required bool enabled}) {
    final color = enabled ? C.error : C.error.withValues(alpha: .4);
    return PressFx(
      enabled: enabled,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? () => _remove(p) : null,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: color, width: 1.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'إزالة',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: color),
            ),
          ),
        ),
      ),
    );
  }

  // سطر الإصدار تحت البطاقة (مع سهم الإصدار الأحدث إن وُجد)
  String _versionLine(InstalledPackage p, CatalogPackage? cat) {
    final latest = cat?.latestVersion;
    final update = cat?.updateAvailable == true && latest != null;
    return 'الإصدار ${p.version}${update ? '  ←  $latest' : ''}';
  }

  Widget _installedZone(InstalledPackage p) {
    return Row(children: [
      const Expanded(
        child: Row(children: [
          Icon(Icons.check_circle_rounded, color: C.ok, size: 16),
          SizedBox(width: 6),
          Text('تم تثبيت المكتبة بنجاح',
              style: TextStyle(fontSize: 12, color: C.ok)),
        ]),
      ),
      const SizedBox(width: 8),
      _removeButton(p, enabled: !libInstaller.busy),
    ]);
  }

  // مكتبة من الكتالوج موجودة لكنها جاءت تلقائيًا مع مكتبة أخرى (لم يطلبها المستخدم)
  Widget _companionZone(InstalledPackage p) {
    final by = p.requiredBy.join('، ');
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Text(
        by.isEmpty ? 'مثبتة تلقائيًا كمكتبة مرافقة' : 'مثبتة تلقائيًا لأن $by تحتاجها',
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, color: C.dim),
      ),
    );
  }

  Widget _idleZone(CatalogPackage? cat) {
    final latest = cat?.latestVersion;
    if (latest == null) return const SizedBox.shrink();
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Text('أحدث نسخة: $latest',
          textDirection: TextDirection.ltr,
          style: const TextStyle(fontSize: 11, color: C.dim)),
    );
  }

  // كل بطاقة: عنوان + زر، ثم منطقة سفلية بارتفاع ثابت (36) محجوزة دائمًا
  // (تتسع لزر الإزالة)، فلا يرتفع شيء ولا ينزل بين الحالات.
  Widget _tile(Lib lib, int index) {
    final key = pkgKey(lib.name);
    final raw = _packages[key];
    // المرافقة (لم يطلبها المستخدم) لا تُعامل كمثبتة في بطاقتها
    final installed = (raw != null && raw.requested) ? raw : null;
    final companion = (raw != null && !raw.requested) ? raw : null;
    final cat = _catalogFor(lib.name);
    final job = libInstaller.jobFor(key);

    final Widget zone;
    final String zoneKey;
    if (job != null && job.state != JobState.done) {
      zoneKey = 'job-${job.state.name}';
      zone = LibJobZone(
        job: job,
        onDetails: job.state == JobState.failed ? () => showInstallDetails(context, job) : null,
        onDismiss: job.state == JobState.failed ? () => libInstaller.dismiss(key) : null,
      );
    } else if (installed != null) {
      zoneKey = 'installed';
      zone = _installedZone(installed);
    } else if (job != null) {
      zoneKey = 'done';
      zone = LibJobZone(job: job);
    } else if (companion != null) {
      zoneKey = 'companion';
      zone = _companionZone(companion);
    } else {
      zoneKey = 'idle';
      zone = _idleZone(cat);
    }

    return Padding(
      key: ValueKey('lib-$key'),
      padding: const EdgeInsets.only(bottom: 10),
      child: Appear(
        index: index,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          decoration: _box(C.surface, raised: true),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(lib.name,
                            textDirection: TextDirection.ltr,
                            style: mono.copyWith(fontSize: 15)),
                        const SizedBox(height: 2),
                        Text(lib.desc,
                            style: const TextStyle(fontSize: 12, color: C.muted)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 112,
                    height: 42,
                    child: Center(child: _trailing(lib, installed, cat, job)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 36,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: KeyedSubtree(key: ValueKey(zoneKey), child: zone),
                ),
              ),
              // الإصدار تحت البطاقة (في قسم «المثبتة» فقط حتى لا تتحرك البطاقات)
              if (installed != null && _shown.contains(key))
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    _versionLine(installed, cat),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: C.dim),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _companionRow(InstalledPackage p) {
    final by = p.requiredBy.join('، ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(
                p.name,
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: mono.copyWith(fontSize: 14),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              p.version,
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 11, color: C.dim),
            ),
          ]),
          if (by.isNotEmpty)
            Text('تحتاجها: $by',
                style: const TextStyle(fontSize: 11, color: C.dim)),
        ],
      ),
    );
  }

  // قسم مطوي أسفل القائمة: المكتبات التي ثُبّتت تلقائيًا مع غيرها (بلا زر إزالة منفرد)
  Widget _companionsSection(List<InstalledPackage> items) {
    return Container(
      decoration: _box(C.surface, raised: true),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _companionsOpen = !_companionsOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                const Icon(Icons.link_rounded, color: C.muted, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('مكتبات مرافقة (${items.length})',
                      style: const TextStyle(fontSize: 13, color: C.muted)),
                ),
                Icon(
                  _companionsOpen
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: C.muted,
                  size: 22,
                ),
              ]),
            ),
          ),
          if (_companionsOpen) ...[
            Container(height: 1, color: C.border),
            for (final p in items) _companionRow(p),
          ],
        ],
      ),
    );
  }

  Widget _list(LibInstaller installer) {
    final catalogKeys = <String>{for (final l in catalog) pkgKey(l.name)};
    final customInstalled = _packages.values
        .where((p) =>
            _shown.contains(pkgKey(p.name)) && !catalogKeys.contains(pkgKey(p.name)))
        .toList();
    final shownCatalog =
        catalog.where((l) => _shown.contains(pkgKey(l.name))).toList();
    final restCatalog =
        catalog.where((l) => !_shown.contains(pkgKey(l.name))).toList();
    // مكتبات خارج الكتالوج قيد التثبيت: تظهر في آخر القائمة فلا تدفع ما فوقها
    final customJobs = installer.jobs
        .where((j) => !catalogKeys.contains(j.key) && !_shown.contains(j.key))
        .toList();
    final companions = _packages.values.where((p) => !p.requested).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    var i = 0;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (customInstalled.isNotEmpty || shownCatalog.isNotEmpty) ...[
          const Text('المثبتة', style: TextStyle(color: C.muted, fontSize: 13)),
          const SizedBox(height: 10),
          for (final p in customInstalled)
            _tile(Lib(p.name, 'مكتبة أضفتها بنفسك', p.name.replaceAll('-', '_')), i++),
          for (final lib in shownCatalog) _tile(lib, i++),
          const SizedBox(height: 10),
        ],
        const Text('المكتبات الأساسية', style: TextStyle(color: C.muted, fontSize: 13)),
        const SizedBox(height: 10),
        for (final lib in restCatalog) _tile(lib, i++),
        if (customJobs.isNotEmpty) ...[
          const SizedBox(height: 4),
          const Text('قيد التثبيت', style: TextStyle(color: C.muted, fontSize: 13)),
          const SizedBox(height: 10),
          for (final j in customJobs)
            _tile(Lib(j.name, 'مكتبة أضفتها بنفسك', j.name.replaceAll('-', '_')), i++),
        ],
        const SizedBox(height: 14),
        OButton(
          label: '+ تنزيل مكتبة غير موجودة',
          icon: Icons.download_rounded,
          height: 50,
          radius: 12,
          onPressed: _downloadUnknown,
        ),
        const SizedBox(height: 12),
        if (companions.isNotEmpty) ...[
          _companionsSection(companions),
          const SizedBox(height: 12),
        ],
        if (_packages.isNotEmpty)
          Center(
            child: Text(
              'مساحة المكتبات: ${formatBytes(_packages.values.fold<int>(0, (sum, p) => sum + p.size))}',
              style: const TextStyle(fontSize: 12, color: C.dim),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => InstallerBuilder(
        builder: (context, installer) => Scaffold(
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
                        onPressed: (_refreshing || installer.busy) ? null : () => _refresh(),
                        icon: _refreshing
                            ? const SizedBox(
                                width: 19,
                                height: 19,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.refresh_rounded),
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator(color: C.accent))
                      : _list(installer),
                ),
              ],
            ),
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
                          contextMenuBuilder: arContextMenu,
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
        contextMenuBuilder: arContextMenu,
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

// جزء نصي له لون (أو لا): يُقسَّم لاحقًا عند حدود التظليل
class _Seg {
  const _Seg(this.start, this.end, this.style);
  final int start, end;
  final TextStyle? style;
}

class CodeController extends TextEditingController {
  CodeController(String text)
      : super.fromValue(TextEditingValue(
            text: text, selection: TextSelection.collapsed(offset: text.length)));
  static final _tok = RegExp(
      r'''(#[^\n]*)|("[^"\n]*"|'[^'\n]*')|(\b\d+(?:\.\d+)?\b)|(\b[A-Za-z_][A-Za-z0-9_]*\b)''');

  // تظليل مؤقت لسطر (عند الانتقال من سطر خطأ) ونتائج البحث
  TextRange? _lineMark;
  List<TextRange> _matches = const <TextRange>[];
  int _current = -1;

  bool get hasLineMark => _lineMark != null;

  void setLineMark(TextRange? range) {
    _lineMark = range;
    notifyListeners();
  }

  void setMatches(List<TextRange> matches, int current) {
    _matches = matches;
    _current = current;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan(
      {required BuildContext context,
      TextStyle? style,
      required bool withComposing}) {
    final t = text;
    final segs = <_Seg>[];
    var i = 0;
    for (final m in _tok.allMatches(t)) {
      if (m.start > i) segs.add(_Seg(i, m.start, null));
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
      segs.add(_Seg(m.start, m.end,
          col == null ? null : TextStyle(color: col, fontStyle: fs)));
      i = m.end;
    }
    if (i < t.length) segs.add(_Seg(i, t.length, null));

    final lineMark = _lineMark;
    if (lineMark == null && _matches.isEmpty) {
      return TextSpan(style: style, children: [
        for (final s in segs)
          TextSpan(text: t.substring(s.start, s.end), style: s.style),
      ]);
    }

    // علامة لكل حرف: 1 نتيجة بحث، 2 سطر منتقل إليه، 3 النتيجة الحالية (الأعلى أولوية)
    final marks = List<int>.filled(t.length, 0);
    void paint(TextRange r, int value) {
      final from = r.start < 0 ? 0 : r.start;
      final to = r.end > t.length ? t.length : r.end;
      for (var j = from; j < to; j++) {
        marks[j] = value;
      }
    }

    for (final r in _matches) {
      paint(r, 1);
    }
    if (lineMark != null) paint(lineMark, 2);
    if (_current >= 0 && _current < _matches.length) paint(_matches[_current], 3);

    final out = <TextSpan>[];
    for (final s in segs) {
      var a = s.start;
      while (a < s.end) {
        final mark = marks[a];
        var b = a + 1;
        while (b < s.end && marks[b] == mark) {
          b++;
        }
        TextStyle? st = s.style;
        if (mark != 0) {
          final bg = mark == 1
              ? C.warn.withValues(alpha: .28)
              : mark == 2
                  ? C.accent.withValues(alpha: .28)
                  : C.warn.withValues(alpha: .62);
          st = (st ?? const TextStyle()).copyWith(backgroundColor: bg);
        }
        out.add(TextSpan(text: t.substring(a, b), style: st));
        a = b;
      }
    }
    return TextSpan(style: style, children: out);
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
  const ScriptScreen({super.key, required this.script, this.initialLine});
  final Script script;
  // عند الفتح من سطر خطأ: رقم السطر الذي ينتقل إليه المحرر بعد التحميل
  final int? initialLine;

  @override
  State<ScriptScreen> createState() => _ScriptScreenState();
}

class _ScriptScreenState extends State<ScriptScreen>
    with WidgetsBindingObserver {
  // المحررات المفتوحة الآن (مسار السكربت ← حالته): كي لا يُفتح محرر ثانٍ لنفس الملف
  static final Map<String, _ScriptScreenState> open =
      <String, _ScriptScreenState>{};
  static const _maxHits = 3000;

  final _code = CodeController('');
  final _focus = FocusNode();
  final _undo = UndoHistoryController();
  final _scroll = ScrollController();
  final _fieldKey = GlobalKey();
  final _viewKey = GlobalKey();
  final _searchCtl = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _timer, _markTimer, _searchTimer, _hashTimer;
  String? _lastSaved;
  bool _loading = true, _warned = false;
  ModalRoute<dynamic>? route;

  // البحث داخل المحرر
  bool _searching = false;
  List<TextRange> _hits = const <TextRange>[];
  int _hit = -1;

  @override
  void initState() {
    super.initState();
    open[widget.script.path] = this;
    runHub.addListener(_onHub);
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    route = ModalRoute.of(context);
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
      _refreshHash();
      _code.addListener(_onChanged);
      setState(() => _loading = false);
      final line = widget.initialLine;
      if (line != null) jumpToLine(line, delay: const Duration(milliseconds: 380));
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
    _scheduleHash();
    if (_code.hasLineMark) {
      _markTimer?.cancel();
      _code.setLineMark(null); // مواضع التظليل لم تعد صحيحة بعد التعديل
    }
    if (_searching && _searchCtl.text.isNotEmpty) _scheduleSearch(jump: false);
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
    if (identical(open[widget.script.path], this)) open.remove(widget.script.path);
    runHub.removeListener(_onHub);
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _markTimer?.cancel();
    _searchTimer?.cancel();
    _hashTimer?.cancel();
    _flush();
    _code.removeListener(_onChanged);
    _code.dispose();
    _focus.dispose();
    _undo.dispose();
    _scroll.dispose();
    _searchCtl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _leave() {
    _flush();
    Navigator.pop(context);
  }

  void _onHub() {
    if (mounted) setState(() {});
  }

  // بصمة النص الحالي في المحرر. تُحسب بعد توقف الكتابة بحوالي 300ms (لا مع كل حرف)،
  // وفورًا عند التحميل وعند الضغط على الزر الأسفل.
  String? _hashText, _hashValue;

  void _refreshHash() {
    final text = widget.script.code;
    if (identical(_hashText, text) && _hashValue != null) return;
    _hashText = text;
    _hashValue = textFingerprint(text);
  }

  void _scheduleHash() {
    _hashTimer?.cancel();
    _hashTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(_refreshHash);
    });
  }

  // جلسة هذا السكربت (شغّالة أو منتهية محتفظ بإخراجها) إذا كان نص المحرر حرفيًا نص تشغيلها،
  // وإلا null. تعديل حرف واحد يقطعها، والتراجع عن التعديل يعيدها.
  RunInfo? _enterableRun() {
    final info = runHub.infoFor(widget.script.path);
    final saved = info?.textHash;
    if (info == null || saved == null) return null;
    return _hashValue == saved ? info : null;
  }

  bool get _canEnter => _enterableRun() != null;

  // «دخول» يفتح الجلسة القائمة. «تشغيل» تشغيل جديد يمر من بوابة RunSlot
  Future<void> _openOutput() async {
    await _save();
    if (!mounted) return;
    _focus.unfocus();
    _hashTimer?.cancel();
    _refreshHash(); // القرار على النص الحالي بالضبط، لا على بصمة قديمة ما زال مؤقتها ينتظر
    final session = _enterableRun();
    if (session != null) {
      Navigator.push(context,
          smooth(OutputScreen(script: widget.script, attachRunId: session.runId)));
      return;
    }
    if (!await claimRunSlot(context, widget.script)) return;
    if (!mounted) return;
    Navigator.push(context, smooth(OutputScreen(script: widget.script)));
  }

  // ───── الانتقال إلى سطر (من سطر خطأ في Traceback) ─────
  // يضع المؤشر في بداية السطر، ويمرّره إلى منتصف الشاشة، ويظلّله ثانيتين تقريبًا.
  // لا تُفتح لوحة المفاتيح. رقم أكبر من عدد الأسطر ينتقل إلى آخر سطر دون شرح.
  void jumpToLine(int line, {Duration delay = const Duration(milliseconds: 300)}) {
    Future<void>.delayed(delay, () async {
      for (var n = 0; n < 20 && mounted && _loading; n++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (!mounted || _loading) return;
      final text = _code.text;
      final wanted = line < 1 ? 1 : line;
      var start = 0;
      var current = 1;
      while (current < wanted) {
        final nl = text.indexOf('\n', start);
        if (nl < 0) break;
        start = nl + 1;
        current++;
      }
      var end = text.indexOf('\n', start);
      if (end < 0) end = text.length;
      _code.selection = TextSelection.collapsed(offset: start);
      _code.setLineMark(end > start ? TextRange(start: start, end: end) : null);
      _scrollToOffset(start);
      _markTimer?.cancel();
      _markTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) _code.setLineMark(null);
      });
    });
  }

  // يجد حالة الحقل الداخلي للمحرر (للوصول إلى موضع المؤشر على الشاشة)
  EditableTextState? _findEditable() {
    EditableTextState? found;
    void visit(Element el) {
      if (found != null) return;
      if (el is StatefulElement && el.state is EditableTextState) {
        found = el.state as EditableTextState;
        return;
      }
      el.visitChildren(visit);
    }

    final ctx = _fieldKey.currentContext;
    if (ctx is Element) visit(ctx);
    return found;
  }

  // يمرّر المحرر بحيث يصبح الموضع في منتصف المساحة الظاهرة (يراعي التفاف الأسطر الطويلة)
  void _scrollToOffset(int offset) {
    try {
      final editable = _findEditable();
      final view = _viewKey.currentContext?.findRenderObject();
      if (editable == null || view is! RenderBox || !_scroll.hasClients) return;
      final render = editable.renderEditable;
      if (!render.hasSize) return;
      final caret = render.getLocalRectForCaret(TextPosition(offset: offset));
      final caretY = render.localToGlobal(caret.center).dy;
      final centerY = view.localToGlobal(Offset(0, view.size.height / 2)).dy;
      final pos = _scroll.position;
      final target = (pos.pixels + caretY - centerY)
          .clamp(pos.minScrollExtent, pos.maxScrollExtent)
          .toDouble();
      unawaited(_scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      ));
    } catch (_) {
      // التمرير تحسين فقط؛ لا نكسر المحرر إن تعذّر حسابه
    }
  }

  // ───── البحث داخل المحرر (بحث فقط، بدون استبدال) ─────
  void _toggleSearch() {
    if (_searching) {
      _closeSearch();
      return;
    }
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
    if (_searchCtl.text.isNotEmpty) _runSearch(jump: false);
  }

  void _closeSearch() {
    _searchTimer?.cancel();
    _searchFocus.unfocus();
    _code.setMatches(const <TextRange>[], -1);
    setState(() {
      _searching = false;
      _hits = const <TextRange>[];
      _hit = -1;
    });
  }

  void _scheduleSearch({required bool jump}) {
    _searchTimer?.cancel();
    _searchTimer = Timer(Duration(milliseconds: jump ? 150 : 250), () {
      if (mounted) _runSearch(jump: jump);
    });
  }

  void _runSearch({required bool jump}) {
    final q = _searchCtl.text;
    if (!_searching || q.isEmpty) {
      _code.setMatches(const <TextRange>[], -1);
      setState(() {
        _hits = const <TextRange>[];
        _hit = -1;
      });
      return;
    }
    // غير حساس لحالة الأحرف؛ RegExp.escape يجعل الرموز الخاصة نصًا عاديًا
    final hits = <TextRange>[];
    try {
      final re = RegExp(RegExp.escape(q), caseSensitive: false);
      for (final m in re.allMatches(_code.text)) {
        hits.add(TextRange(start: m.start, end: m.end));
        if (hits.length >= _maxHits) break;
      }
    } catch (_) {}
    var idx = -1;
    if (hits.isNotEmpty) {
      final caret = _code.selection.isValid ? _code.selection.start : 0;
      idx = hits.indexWhere((h) => h.start >= caret);
      if (idx < 0) idx = 0;
    }
    setState(() {
      _hits = hits;
      _hit = idx;
    });
    _code.setMatches(hits, idx);
    if (jump) _selectHit(idx);
  }

  // يحدّد النتيجة ويمرّر إليها؛ تغيير التحديد فقط، فلا يدخل في سجل التراجع والإعادة
  void _selectHit(int i) {
    if (i < 0 || i >= _hits.length) return;
    final h = _hits[i];
    _code.selection = TextSelection(baseOffset: h.start, extentOffset: h.end);
    _scrollToOffset(h.start);
  }

  void _stepHit(int delta) {
    final n = _hits.length;
    if (n == 0) return;
    final base = _hit < 0 ? (delta > 0 ? -1 : 0) : _hit;
    final next = (base + delta + n) % n;
    setState(() => _hit = next);
    _code.setMatches(_hits, next);
    _selectHit(next);
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

  Widget _searchBar() {
    final total = _hits.length;
    final hasQuery = _searchCtl.text.isNotEmpty;
    final counter = !hasQuery
        ? ''
        : total == 0
            ? '0/0'
            : '${_hit + 1}/$total${total >= _maxHits ? '+' : ''}';
    final enabled = total > 0;
    return Container(
      height: 48,
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.only(right: 12, left: 2),
      decoration: _box(C.surface),
      child: Row(children: [
        Expanded(
          child: TextField(
            contextMenuBuilder: arContextMenu,
            controller: _searchCtl,
            focusNode: _searchFocus,
            onChanged: (_) => _scheduleSearch(jump: true),
            onEditingComplete: () => _stepHit(1),
            textInputAction: TextInputAction.search,
            autocorrect: false,
            enableSuggestions: false,
            cursorColor: C.accent,
            style: const TextStyle(fontSize: 15),
            decoration: const InputDecoration.collapsed(
              hintText: 'ابحث في السكربت',
              hintStyle: TextStyle(color: C.dim),
            ),
          ),
        ),
        SizedBox(
          width: 58,
          child: Text(
            counter,
            textAlign: TextAlign.center,
            textDirection: TextDirection.ltr,
            style: TextStyle(
                fontSize: 13,
                color: hasQuery && total == 0 ? C.error : C.muted),
          ),
        ),
        _historyBtn(Icons.keyboard_arrow_up_rounded, 'السابق', enabled,
            () => _stepHit(-1)),
        _historyBtn(Icons.keyboard_arrow_down_rounded, 'التالي', enabled,
            () => _stepHit(1)),
        _historyBtn(Icons.close_rounded, 'إغلاق البحث', true, _closeSearch),
      ]),
    );
  }

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
                PressFx(
                  scale: .88,
                  child: IconButton(
                    tooltip: 'بحث',
                    color: _searching ? C.accent : C.text,
                    onPressed: _loading ? null : _toggleSearch,
                    icon: const Icon(Icons.search_rounded),
                  ),
                ),
                ValueListenableBuilder<UndoHistoryValue>(
                  valueListenable: _undo,
                  builder: (_, v, __) => Row(mainAxisSize: MainAxisSize.min, children: [
                    _historyBtn(Icons.redo, 'إعادة', v.canRedo, _undo.redo),
                    _historyBtn(Icons.undo, 'تراجع', v.canUndo, _undo.undo),
                  ]),
                ),
              ],
            ),
            if (_searching) _searchBar(),
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
                        label: _canEnter ? 'دخول' : 'تشغيل',
                        icon: _canEnter
                            ? Icons.login_rounded
                            : Icons.play_arrow_rounded,
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
              key: _viewKey,
              controller: _scroll,
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
                    key: _fieldKey,
                    contextMenuBuilder: arContextMenu,
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

/// يحوّل دفعات stdout/stderr إلى أسطر بالمنطق نفسه في الإخراج الحي والسجل الدائم.
void appendOutputEventLines(List<Line> lines, String text, int kind,
    {int maxLines = 5000}) {
  if (text.isEmpty) return;
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // ادمج مع آخر سطر من النوع نفسه، لكن اجمع أحرف الدفعة في StringBuffer لتفادي نسخ
  // السلسلة مع كل حرف (خصوصًا عند قراءة دفعات السجل الكبيرة أو السطر الواحد الطويل).
  final buffer = StringBuffer();
  if (lines.isNotEmpty && lines.last.kind == kind) {
    buffer.write(lines.removeLast().text);
  }
  for (var i = 0; i < normalized.length; i++) {
    final ch = normalized[i];
    if (ch == '\n') {
      lines.add(Line(buffer.toString(), kind));
      buffer.clear();
    } else {
      buffer.write(ch);
    }
  }
  lines.add(Line(buffer.toString(), kind));
  if (lines.length > maxLines) {
    lines.removeRange(0, lines.length - maxLines);
  }
}

Color _lineColor(int k) => k == 1
    ? C.dim
    : k == 2
        ? C.accent
        : k == 3
            ? C.error
            : C.text;

// سجل JSONL كما وصل من LogStore. تُتجاهل الأسطر غير المكتملة/التالفة بدل تعطيل الشاشة.
class _StoredLogRecord {
  const _StoredLogRecord({
    required this.type,
    this.runId = '',
    this.timeMs = 0,
    this.kind = '',
    this.text = '',
    this.code,
  });

  final String type; // start / event / end
  final String runId;
  final int timeMs;
  final String kind;
  final String text;
  final int? code;

  static List<_StoredLogRecord> parsePage(String text) {
    final result = <_StoredLogRecord>[];
    for (final line in text.split('\n')) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) continue;
        final m = Map<String, dynamic>.from(decoded);
        if (m['run'] is String && m['start'] is num) {
          result.add(_StoredLogRecord(
            type: 'start',
            runId: m['run'].toString(),
            timeMs: (m['start'] as num).toInt(),
          ));
        } else if (m['end'] is String && m['t'] is num) {
          result.add(_StoredLogRecord(
            type: 'end',
            runId: m['end'].toString(),
            timeMs: (m['t'] as num).toInt(),
            code: (m['code'] as num?)?.toInt(),
          ));
        } else if (m['k'] is String && m['t'] is num && m['s'] is String) {
          result.add(_StoredLogRecord(
            type: 'event',
            timeMs: (m['t'] as num).toInt(),
            kind: m['k'].toString(),
            text: m['s'].toString(),
          ));
        }
      } catch (_) {
        // قتل التطبيق في منتصف الكتابة قد ترك سطرًا ناقصًا؛ السجل التالي يبقى قابلًا للقراءة.
      }
    }
    return result;
  }
}

class _LogDisplayItem {
  const _LogDisplayItem.line(this.text, this.kind)
      : isHeader = false,
        subtitle = '',
        headerColor = C.muted;
  const _LogDisplayItem.header(this.text, this.subtitle, this.headerColor)
      : isHeader = true,
        kind = 0;

  final String text;
  final int kind;
  final bool isHeader;
  final String subtitle;
  final Color headerColor;
}

String _logDate(int milliseconds) {
  final t = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

String _logDuration(int startMs, int endMs) {
  final total = ((endMs - startMs) / 1000).floor().clamp(0, 1 << 31);
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  if (hours > 0) return '${hours}س ${minutes}د ${seconds}ث';
  if (minutes > 0) return '${minutes}د ${seconds}ث';
  return '${seconds}ث';
}

class LogScreen extends StatefulWidget {
  const LogScreen({super.key, required this.script});
  final Script script;

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  static const int _pageBytes = 256 * 1024;
  static const int _copyLimit = 400000;

  final _scroll = ScrollController();
  List<_StoredLogRecord> _records = <_StoredLogRecord>[];
  int _sizeBytes = 0;
  int? _epoch;
  int? _before;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingOlder = false;
  bool _readyToPaginate = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_loadLatest());
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  String get _sizeLabel =>
      '${(_sizeBytes / (1024 * 1024)).toStringAsFixed(1)} من 20 MB';

  void _onScroll() {
    if (!_readyToPaginate || !_scroll.hasClients || _loading || _loadingOlder || !_hasMore) return;
    if (_scroll.position.pixels < 100) unawaited(_loadOlder());
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
      _readyToPaginate = true;
    });
  }

  Future<void> _loadLatest({bool showLoading = true}) async {
    if (!mounted) return;
    if (showLoading) {
      setState(() {
        _loading = true;
        _readyToPaginate = false;
      });
    }
    try {
      final page = await bayanPython.logsPage(widget.script.path, maxBytes: _pageBytes);
      if (!mounted) return;
      setState(() {
        _records = _StoredLogRecord.parsePage(page.text);
        _sizeBytes = page.size;
        _epoch = page.epoch;
        _before = page.start;
        _hasMore = page.hasMore && page.start > 0;
        _loading = false;
      });
      _scrollToLatest();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('تعذّر قراءة سجل الإخراج: ${errText(e)}');
    }
  }

  Future<void> _loadOlder() async {
    if (!_hasMore || _loadingOlder || _loading || _before == null) return;
    final oldPixels = _scroll.hasClients ? _scroll.position.pixels : 0.0;
    final oldMax = _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
    setState(() => _loadingOlder = true);
    try {
      final page = await bayanPython.logsPage(
        widget.script.path,
        before: _before,
        maxBytes: _pageBytes,
        epoch: _epoch,
      );
      if (!mounted) return;
      if (page.stale) {
        setState(() => _loadingOlder = false);
        await _loadLatest();
        _snack('تغيّر السجل؛ تم تحديثه من أحدث البيانات');
        return;
      }
      final older = _StoredLogRecord.parsePage(page.text);
      setState(() {
        _records = <_StoredLogRecord>[...older, ..._records];
        _sizeBytes = page.size;
        _epoch = page.epoch;
        _before = page.start;
        _hasMore = page.hasMore && page.start > 0;
        _loadingOlder = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final extra = _scroll.position.maxScrollExtent - oldMax;
        _scroll.jumpTo((oldPixels + extra)
            .clamp(0.0, _scroll.position.maxScrollExtent)
            .toDouble());
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingOlder = false);
      _snack('تعذّر تحميل السجل الأقدم: ${errText(e)}');
    }
  }

  Future<void> _refresh() async => _loadLatest();

  Future<void> _clearLog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.surface,
        title: const Text('مسح السجل'),
        content: Text(
          'سيُمسح سجل الإخراج الدائم (${_sizeLabel}). لا يمكن التراجع عن هذا المسح.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('مسح السجل')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final ok = await bayanPython.logsClear(widget.script.path);
      if (!mounted) return;
      if (!ok) _snack('تعذّر مسح السجل');
      await _loadLatest();
    } catch (e) {
      if (mounted) _snack('تعذّر مسح السجل: ${errText(e)}');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  List<_LogDisplayItem> _displayItems() {
    final starts = <String, _StoredLogRecord>{};
    final ends = <String, _StoredLogRecord>{};
    for (final r in _records) {
      if (r.type == 'start') starts[r.runId] = r;
      if (r.type == 'end') ends[r.runId] = r;
    }

    final output = <_LogDisplayItem>[];
    var i = 0;
    while (i < _records.length) {
      final r = _records[i];
      if (r.type == 'start') {
        final end = ends[r.runId];
        String status;
        Color color;
        int endMs;
        String codeText;
        if (end != null) {
          endMs = end.timeMs;
          final code = end.code ?? -1;
          status = code == 0 ? 'انتهى' : code == 130 ? 'موقوف' : 'خطأ';
          color = code == 0 ? C.ok : code == 130 ? C.warn : C.error;
          codeText = 'رمز الخروج: $code';
        } else {
          final active = runHub.infoFor(widget.script.path);
          final live = active != null && active.runId == r.runId && active.isLive;
          endMs = live ? DateTime.now().millisecondsSinceEpoch : r.timeMs;
          status = live ? 'جاري' : 'خطأ (لا يوجد سطر نهاية)';
          color = live ? C.ok : C.error;
          codeText = live ? 'قيد التشغيل' : 'نهاية غير محفوظة';
        }
        output.add(_LogDisplayItem.header(
          'تشغيل · ${_logDate(r.timeMs)}',
          'المدة: ${_logDuration(r.timeMs, endMs)} · الحالة: $status · $codeText',
          color,
        ));
        i++;
        continue;
      }
      if (r.type == 'end') {
        if (!starts.containsKey(r.runId)) {
          final code = r.code ?? -1;
          final status = code == 0 ? 'انتهى' : code == 130 ? 'موقوف' : 'خطأ';
          final color = code == 0 ? C.ok : code == 130 ? C.warn : C.error;
          output.add(_LogDisplayItem.header(
            'تشغيل · البداية غير متوفرة',
            '${_logDate(r.timeMs)} · الحالة: $status · رمز الخروج: $code',
            color,
          ));
        }
        i++;
        continue;
      }

      if (r.kind == 'o' || r.kind == 'e') {
        final lines = <Line>[];
        while (i < _records.length) {
          final part = _records[i];
          if (part.type != 'event' || (part.kind != 'o' && part.kind != 'e')) break;
          appendOutputEventLines(lines, part.text, part.kind == 'e' ? 3 : 0,
              maxLines: 1000000);
          i++;
        }
        for (final line in lines) {
          output.add(_LogDisplayItem.line(line.text, line.kind));
        }
        continue;
      }
      output.add(_LogDisplayItem.line(r.text, r.kind == 'i' ? 2 : 1));
      i++;
    }
    return output;
  }

  String _copyText(List<_StoredLogRecord> records) {
    final out = StringBuffer();
    final starts = <String, _StoredLogRecord>{};
    for (final r in records) {
      if (r.type == 'start') starts[r.runId] = r;
    }
    for (final r in records) {
      switch (r.type) {
        case 'start':
          out.write('\n──────── تشغيل · ${_logDate(r.timeMs)} ────────\n');
          break;
        case 'event':
          if (r.kind == 's' || r.kind == 'i') {
            out.write('\n${r.text}\n');
          } else {
            out.write(r.text);
          }
          break;
        case 'end':
          if (!starts.containsKey(r.runId)) out.write('\n[رمز الخروج: ${r.code ?? -1}]\n');
          final start = starts[r.runId];
          if (start != null) {
            // يطبع سطر الحالة مرة واحدة هنا، مع إبقاء سطر البداية مستقلًا.
            final code = r.code ?? -1;
            final state = code == 0 ? 'انتهى' : code == 130 ? 'موقوف' : 'خطأ';
            out.write('\n[$state · رمز الخروج: $code]\n');
          }
          break;
      }
    }
    return out.toString();
  }

  Future<void> _copyLog() async {
    try {
      var fetched = <_StoredLogRecord>[];
      int? before;
      int? epoch;
      var hasMore = true;
      var attempts = 0;
      var staleRetries = 0;
      while (hasMore && attempts < 32) {
        final page = await bayanPython.logsPage(
          widget.script.path,
          before: before,
          maxBytes: 1024 * 1024,
          epoch: epoch,
        );
        attempts++;
        if (page.stale) {
          if (staleRetries++ >= 2) break;
          fetched = <_StoredLogRecord>[];
          before = null;
          epoch = null;
          hasMore = true;
          continue;
        }
        fetched.insertAll(0, _StoredLogRecord.parsePage(page.text));
        epoch = page.epoch;
        before = page.start;
        hasMore = page.hasMore && page.start > 0;
        final approxChars = fetched.fold<int>(0, (n, r) => n + r.text.length + 64);
        if (approxChars >= _copyLimit) break;
      }
      if (!mounted) return;
      var text = _copyText(fetched);
      if (text.isEmpty) {
        _snack('لا يوجد سجل للنسخ');
        return;
      }
      var truncated = false;
      if (text.length > _copyLimit) {
        var from = text.length - _copyLimit;
        if (from > 0 && from < text.length) {
          final unit = text.codeUnitAt(from);
          if (unit >= 0xDC00 && unit <= 0xDFFF) from++;
        }
        text = text.substring(from);
        truncated = true;
      }
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        _snack(truncated
            ? 'نُسخ آخر 400 ألف حرف تقريبًا لتجنب حد حافظة أندرويد'
            : 'تم نسخ السجل');
      }
    } catch (e) {
      if (mounted) _snack('تعذّر نسخ السجل: ${errText(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _displayItems();
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Header(
              title: widget.script.name,
              back: true,
              mono: true,
              onBack: () => Navigator.pop(context),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(
                      'حجم السجل: $_sizeLabel',
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: C.muted, fontSize: 12),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton.icon(
                          onPressed: _loading ? null : _copyLog,
                          icon: const Icon(Icons.content_copy_outlined, size: 17),
                          label: const Text('نسخ', maxLines: 1),
                        ),
                      ),
                      Expanded(
                        child: TextButton.icon(
                          onPressed: _loading ? null : _clearLog,
                          icon: const Icon(Icons.delete_sweep_outlined, size: 17),
                          label: const Text('مسح السجل', maxLines: 1),
                        ),
                      ),
                      Expanded(
                        child: TextButton.icon(
                          onPressed: _loading ? null : _refresh,
                          icon: const Icon(Icons.refresh_rounded, size: 17),
                          label: const Text('تحديث', maxLines: 1),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_loadingOlder) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: C.accent))
                  : _records.isEmpty
                      ? const Center(
                          child: Text('ما في سجل بعد', style: TextStyle(color: C.muted)),
                        )
                      : SelectionArea(
                          contextMenuBuilder: arSelectionContextMenu,
                          child: Directionality(
                            textDirection: TextDirection.ltr,
                            child: ListView.builder(
                              controller: _scroll,
                              padding: const EdgeInsets.fromLTRB(14, 8, 14, 18),
                              itemCount: items.length,
                              itemBuilder: (context, index) {
                                final item = items[index];
                                if (item.isHeader) {
                                  return Container(
                                    margin: const EdgeInsets.only(top: 10, bottom: 8),
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: C.surface,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: C.border),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        Text(item.text,
                                            textDirection: TextDirection.rtl,
                                            style: mono.copyWith(
                                                fontWeight: FontWeight.w600,
                                                color: item.headerColor,
                                                fontSize: 12)),
                                        const SizedBox(height: 2),
                                        Text(item.subtitle,
                                            textDirection: TextDirection.rtl,
                                            style: const TextStyle(
                                                color: C.muted, fontSize: 11)),
                                      ],
                                    ),
                                  );
                                }
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 1),
                                  child: Text(
                                    item.text.isEmpty ? ' ' : item.text,
                                    style: mono.copyWith(color: _lineColor(item.kind)),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class OutputScreen extends StatefulWidget {
  const OutputScreen({super.key, required this.script, this.attachRunId});
  final Script script;

  /// null: تشغيل جديد. غير null: دخول لهذه الجلسة القائمة (حيّة أو منتهية) بلا تشغيل أي شيء.
  final String? attachRunId;

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
  // true أثناء معالجة حدث أُعيد من مخزن الجلسة: لا نمرّر الشاشة مع كل حدث
  bool _bulk = false;
  // بطاقات المكتبات الناقصة تحت الخطأ
  final _missing = <MissingLib>[];
  // سبب الخطأ مكتبة ناقصة وليس كود المستخدم: أسطر File "…" تُعرض نصًا أحمر عاديًا
  // (بلا رابط) ما دام الفحص لم يقل إن المكتبة غير متاحة. تبقى كذلك بعد نجاح التثبيت،
  // وتتصفّر عند بدء تشغيل جديد.
  bool _plainFrames = false;
  final _removing = <String>{};
  StreamSubscription<int>? _installerSub;

  @override
  void initState() {
    super.initState();
    _runner = ScriptRunner(scriptPath: widget.script.path);
    _events = _runner.events.listen(_onEvent, onError: (Object error, StackTrace stack) {
      _add('$error', 3);
      if (mounted) setState(() {});
    });
    _installerSub = libInstaller.changes.listen(_onInstaller);
    WidgetsBinding.instance
        .addPostFrameCallback((_) {
      final id = widget.attachRunId;
      if (id == null) {
        unawaited(_startRun());
      } else {
        unawaited(_enterSession(id));
      }
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    _installerSub?.cancel();
    // الخروج يفصل الاستماع فقط: السكربت يكمل شغله
    unawaited(_runner.dispose());
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  ScriptRunnerState get _runnerState => _runner.state;

  void _onEvent(BayanEvent e) {
    if (!mounted) return;
    _bulk = e.isReplay;
    switch (e.type) {
      case 'started':
      case 'error':
      case 'input':
      case 'state':
        setState(() {});
        if (e.type == 'error' && e.text.isNotEmpty) _add(e.text, 3);
        if (e.type == 'input' && e.text.isNotEmpty) _add(e.text, 2);
        break;
      case 'truncated':
        _add('… الأقدم غير متوفر في الذاكرة', 1);
        break;
      case 'stdout':
        _appendOutput(e.text, 0);
        break;
      case 'stderr':
        _appendOutput(e.text, 3);
        break;
      case 'missing':
        _onMissing(e.text);
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
        _stopRequested = false;
        setState(() {});
        break;
    }
    _bulk = false;
  }

  void _add(String text, [int kind = 0]) {
    if (!mounted || text.isEmpty) return;
    setState(() => _lines.add(Line(text, kind)));
    if (_bulk) return;
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
    setState(() => appendOutputEventLines(_lines, text, kind));
    if (_bulk) return;
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
      _missing.clear();
      _plainFrames = false;
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

  // دخول لجلسة قائمة (حيّة أو منتهية) بدل تشغيل جديد: يعرض إخراجها المحفوظ ثم يتابع البث الحي
  Future<void> _enterSession(String runId) async {
    if (!mounted || _starting) return;
    setState(() {
      _lines.clear();
      _rawOutput.clear();
      _missing.clear();
      _plainFrames = false;
    });
    _add(r'$ python ' + widget.script.name, 1);
    final found = await _runner.attach(runId);
    if (!mounted) return;
    if (!found) {
      _add('انتهت هذه الجلسة وحُذف إخراجها. اضغط "إعادة تشغيل" لتشغيله من جديد.', 1);
    }
    setState(() {});
    _scrollToEnd();
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
    // تشغيل جديد يمر من بوابة RunSlot (إن كان سكربت آخر يعمل تُسأل قبل إيقافه)
    if (!await claimRunSlot(context, widget.script, confirmOwnOldRun: false)) return;
    if (!mounted) return;
    await _startRun();
  }

  // ───── مكتبات ناقصة (F2) ─────
  void _onInstaller(int _) {
    if (!mounted || _missing.isEmpty) return;
    for (final m in List<MissingLib>.of(_missing)) {
      final job = libInstaller.jobFor(pkgKey(m.package));
      if (job != null && job.state == JobState.done && _removing.add(m.package)) {
        // بعد النجاح تختفي البطاقة ويبقى النص المطبوع فقط (بلا إعادة تشغيل تلقائية)
        Timer(const Duration(milliseconds: 900), () {
          _removing.remove(m.package);
          if (!mounted) return;
          setState(() => _missing.removeWhere((x) => x.package == m.package));
        });
      }
    }
  }

  void _onMissing(String payload) {
    final items = <MissingLib>[];
    try {
      final decoded = jsonDecode(payload);
      if (decoded is List) {
        for (final raw in decoded) {
          if (raw is! Map) continue;
          final pkg = raw['package']?.toString() ?? '';
          final module = raw['module']?.toString() ?? pkg;
          if (pkg.isNotEmpty) {
            items.add(MissingLib(pkg, module, failed: raw['failed'] == true));
          }
        }
      }
    } catch (_) {}
    if (items.isEmpty) return;
    setState(() {
      _missing
        ..clear()
        ..addAll(items);
      _plainFrames = items.any((m) => m.failed);
    });
    _scrollToEnd();
    unawaited(_checkAvailability(items));
  }

  // هل توجد نسخة تعمل على أندرويد؟ إن لم توجد تقول البطاقة ذلك بدل زر يفشل
  Future<void> _checkAvailability(List<MissingLib> items) async {
    try {
      final results =
          await bayanPython.checkAvailability(items.map((m) => m.package).toList());
      if (!mounted) return;
      setState(() {
        for (final r in results) {
          for (final m in items) {
            if (pkgKey(m.package) == pkgKey(r.name)) {
              m.available = r.available;
              m.reason = r.reason;
              m.version = r.version;
            }
          }
        }
        for (final m in items) {
          m.checking = false;
        }
        // مكتبة مكتوبة خطأ أو غير مدعومة: الخطأ فعلًا في السكربت، فتعود الروابط
        if (items.any(_missing.contains)) {
          _plainFrames = items.any((m) => m.failed && m.available != false);
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        for (final m in items) {
          m.checking = false;
        }
      });
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Widget _missingFooter() => Directionality(
        textDirection: TextDirection.rtl,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final m in _missing) MissingLibCard(key: ValueKey(m.package), item: m),
            ],
          ),
        ),
      );

  // ───── الضغط على سطر الخطأ يفتح المحرر عند ذلك السطر (F1) ─────
  Future<void> _openFrame(FrameRef frame) async {
    final target = await store.scriptAtRelative(frame.relative);
    if (!mounted) return;
    if (target == null) {
      _snack('الملف غير موجود');
      return;
    }
    final nav = Navigator.of(context);
    final editor = _ScriptScreenState.open[target.path];
    if (editor != null && editor.mounted) {
      // محرر هذا الملف مفتوح فعلًا في المكدس: نرجع إليه (pop) بدل فتح نسخة ثانية.
      // الرجوع لا يوقف السكربت الجاري (الخروج من الإخراج يفصل الاستماع فقط).
      final route = editor.route;
      if (route != null) {
        nav.popUntil((r) => identical(r, route));
      } else {
        nav.pop();
      }
      editor.jumpToLine(frame.line);
      return;
    }
    // سكربت آخر (أو لا محرر مفتوح له): نفتح محرره فوق الإخراج، والرجوع يعيدنا إليه
    unawaited(nav.push(smooth<void>(ScriptScreen(script: target, initialLine: frame.line))));
  }

  Widget _frameLine(Line line, FrameRef frame) {
    const tint = C.accentEdge;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: C.accent.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => unawaited(_openFrame(frame)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    line.text,
                    style: mono.copyWith(
                      color: tint,
                      decoration: TextDecoration.underline,
                      decorationColor: tint.withValues(alpha: .5),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.open_in_new_rounded, size: 14, color: tint),
              ],
            ),
          ),
        ),
      ),
    );
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
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Header(
              title: widget.script.name,
              back: true,
              mono: true,
              onBack: () => Navigator.pop(context),
            ),
            Expanded(child: _consoleBox(waiting)),
            _actionBar(idle),
          ],
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
                    tooltip: 'مسح الشاشة',
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
            child: _lines.isEmpty && _missing.isEmpty
                ? Center(
                    child: Text(
                      _runner.isRunning ? 'جاري تشغيل Python…' : 'اضغط "إعادة تشغيل" ليظهر الإخراج هنا',
                      style: const TextStyle(fontSize: 13, color: C.dim),
                    ),
                  )
                : SelectionArea(
                    contextMenuBuilder: arSelectionContextMenu,
                    child: Directionality(
                      textDirection: TextDirection.ltr,
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(14),
                        itemCount: _lines.length + (_missing.isEmpty ? 0 : 1),
                        itemBuilder: (_, i) {
                          if (i >= _lines.length) return _missingFooter();
                          final line = _lines[i];
                          // سطر File "…", line N داخل Bayan 777 قابل للضغط
                          final frame =
                              (line.kind == 3 && !_plainFrames) ? parseFrame(line.text) : null;
                          if (frame != null) return _frameLine(line, frame);
                          return Text(
                            line.text,
                            style: mono.copyWith(color: _lineColor(line.kind)),
                          );
                        },
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
                      contextMenuBuilder: arContextMenu,
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
