import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

// ───────── الألوان والأنماط ─────────
class C {
  static const bg = Color(0xFF0B0F0E);
  static const surface = Color(0xFF121816);
  static const border = Color(0xFF22302B);
  static const text = Color(0xFFE8F0EC);
  static const muted = Color(0xFF93A79E);
  static const dim = Color(0xFF7A8F86);
  static const accent = Color(0xFF5BE38A);
  static const onAccent = Color(0xFF04130A);
  static const console = Color(0xFF070A09);
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

const channelUrl = 'https://youtube.com/channel/UC4Ox1C-_DWCbIeiWJ_6rV9Q';

// ───────── البيانات (وهمية الآن) ─────────
class Script {
  Script(this.name, this.code, this.lastRun);
  String name;
  String code;
  String lastRun;
}

final scripts = ValueNotifier<List<Script>>([
  Script(
      'main.py',
      'name = input("ما اسمك؟ ")\nprint("أهلاً", name)\nfor i in range(3):\n    print(i)',
      'آخر تشغيل: قبل 5 دقائق'),
  Script('bot.py', 'print("bot")', 'آخر تشغيل: أمس'),
  Script('test.py', 'print("test")', 'آخر تشغيل: قبل 3 أيام'),
]);

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
        ),
        builder: (context, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
        home: const HomeScreen(),
      );
}

// ───────── مكونات مشتركة ─────────
class Header extends StatelessWidget {
  const Header(
      {super.key,
      required this.title,
      this.back = false,
      this.mono = false,
      this.onMenu});
  final String title;
  final bool back, mono;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) => Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: C.border))),
        child: Row(children: [
          if (back)
            IconButton(
                tooltip: 'رجوع',
                color: C.text,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back)),
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
          if (onMenu != null)
            IconButton(
                tooltip: 'القائمة',
                color: C.text,
                onPressed: onMenu,
                icon: const Icon(Icons.more_vert)),
        ]),
      );
}

class PButton extends StatelessWidget {
  const PButton({super.key, required this.label, this.icon, this.onPressed});
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 52,
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: C.accent,
            foregroundColor: C.onAccent,
            disabledBackgroundColor: C.accent.withValues(alpha: .35),
            disabledForegroundColor: C.onAccent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
            Text(label),
          ]),
        ),
      );
}

// ───────── الشاشة الرئيسية ─────────
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        endDrawer: const AppDrawer(),
        body: SafeArea(
          child: Column(children: [
            Builder(
                builder: (c) => Header(
                    title: 'سكربتاتي',
                    onMenu: () => Scaffold.of(c).openEndDrawer())),
            Expanded(
              child: ValueListenableBuilder<List<Script>>(
                valueListenable: scripts,
                builder: (c, list, _) => ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    PButton(
                        label: 'سكربت جديد',
                        icon: Icons.add,
                        onPressed: () => Navigator.push(
                            c,
                            MaterialPageRoute(
                                builder: (_) => const CreateScreen()))),
                    const SizedBox(height: 28),
                    const Text('السكربتات التي شغّلتها',
                        style: TextStyle(color: C.muted, fontSize: 13)),
                    const SizedBox(height: 12),
                    for (final s in list)
                      Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: ScriptTile(script: s)),
                  ],
                ),
              ),
            ),
          ]),
        ),
      );
}

class ScriptTile extends StatelessWidget {
  const ScriptTile({super.key, required this.script});
  final Script script;

  @override
  Widget build(BuildContext context) => Material(
        color: C.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: C.border)),
        child: InkWell(
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => ScriptScreen(script: script))),
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
                      Text(script.name,
                          textDirection: TextDirection.ltr,
                          style: mono.copyWith(fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(script.lastRun,
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

// ───────── القائمة الجانبية ─────────
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

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
                  Material(
                    color: C.accent.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(10),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => Navigator.pop(context),
                      child: const SizedBox(
                        height: 48,
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Row(children: [
                            Icon(Icons.description_outlined,
                                color: C.accent, size: 20),
                            SizedBox(width: 12),
                            Text('السكربتات',
                                style: TextStyle(
                                    color: C.accent,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      ),
                    ),
                  ),
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
                            const Icon(Icons.smart_display_outlined,
                                color: C.accent, size: 30),
                            const SizedBox(width: 12),
                            const Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('قناتي على يوتيوب',
                                      style: TextStyle(
                                          fontSize: 12, color: C.muted)),
                                  Text('بيان',
                                      style: TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w600)),
                                ]),
                          ]),
                          const SizedBox(height: 14),
                          SizedBox(
                            height: 44,
                            child: OutlinedButton(
                              onPressed: () => launchUrl(Uri.parse(channelUrl),
                                  mode: LaunchMode.externalApplication),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: C.accent,
                                side: const BorderSide(color: C.accent),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                                textStyle: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600),
                              ),
                              child: const Text('فتح القناة'),
                            ),
                          ),
                        ]),
                  ),
                ]),
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

  @override
  void dispose() {
    _name.dispose();
    _paste.dispose();
    super.dispose();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  void _create() {
    var n = _name.text.trim();
    if (n.isEmpty) {
      _snack('اكتب اسم السكربت أولاً');
      return;
    }
    if (!n.endsWith('.py')) n += '.py';
    final code = _paste.text.isEmpty ? 'print("hello")' : _paste.text;
    scripts.value = [Script(n, code, 'لم يُشغَّل بعد'), ...scripts.value];
    Navigator.pop(context);
  }

  Widget _seg(String label, bool active, VoidCallback onTap) => Expanded(
        child: SizedBox(
          height: 44,
          child: TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              backgroundColor: active ? C.accent : Colors.transparent,
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
                            focusedBorder: _ob.copyWith(
                                borderSide: const BorderSide(color: C.accent)),
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
                      Expanded(child: _pasteMode ? _pasteBox() : _fileBox()),
                      const SizedBox(height: 16),
                      PButton(label: 'إنشاء', onPressed: _create),
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
          focusedBorder:
              _ob.copyWith(borderSide: const BorderSide(color: C.accent)),
        ),
      );

  Widget _fileBox() => Container(
        decoration: _box(C.surface),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.folder_open_outlined, color: C.muted, size: 40),
            const SizedBox(height: 12),
            const Text('اختر ملف بايثون من جهازك',
                style: TextStyle(color: C.muted)),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => _snack('اختيار الملفات سيُفعَّل لاحقاً'),
              style: OutlinedButton.styleFrom(
                foregroundColor: C.accent,
                side: const BorderSide(color: C.accent),
                minimumSize: const Size(140, 44),
              ),
              child: const Text('اختيار ملف'),
            ),
          ]),
        ),
      );
}

// ───────── شاشة السكربت (محرر + كونسول وهمي) ─────────
class CodeController extends TextEditingController {
  CodeController(String text) : super(text: text);
  static final _str = RegExp(r'''("[^"\n]*"|'[^'\n]*')''');

  @override
  TextSpan buildTextSpan(
      {required BuildContext context,
      TextStyle? style,
      required bool withComposing}) {
    final spans = <TextSpan>[];
    var i = 0;
    for (final m in _str.allMatches(text)) {
      if (m.start > i) spans.add(TextSpan(text: text.substring(i, m.start)));
      spans.add(TextSpan(text: m[0], style: const TextStyle(color: C.accent)));
      i = m.end;
    }
    if (i < text.length) spans.add(TextSpan(text: text.substring(i)));
    return TextSpan(style: style, children: spans);
  }
}

enum RunState { idle, running, waiting }

class Line {
  Line(this.text, [this.kind = 0]);
  final String text;
  final int kind; // 0 عادي، 1 خافت، 2 مميز
}

class ScriptScreen extends StatefulWidget {
  const ScriptScreen({super.key, required this.script});
  final Script script;

  @override
  State<ScriptScreen> createState() => _ScriptScreenState();
}

class _ScriptScreenState extends State<ScriptScreen> {
  late final CodeController _code = CodeController(widget.script.code);
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _lines = <Line>[];
  RunState _state = RunState.idle;
  int _runId = 0;
  Completer<String>? _wait;

  @override
  void initState() {
    super.initState();
    _code.addListener(() => widget.script.code = _code.text);
  }

  @override
  void dispose() {
    _runId++;
    _code.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _add(String t, [int kind = 0]) {
    if (!mounted) return;
    setState(() => _lines.add(Line(t, kind)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  // تشغيل وهمي: لا ينفذ أي كود فعلياً
  Future<void> _run() async {
    FocusScope.of(context).unfocus();
    final id = ++_runId;
    bool alive() => mounted && id == _runId;
    setState(() {
      _lines.clear();
      _state = RunState.running;
    });
    _add('\$ python ${widget.script.name}', 1);
    await Future.delayed(const Duration(milliseconds: 600));
    if (!alive()) return;

    final prompt = RegExp(r'''input\(\s*["']([^"']*)["']''')
        .firstMatch(widget.script.code)
        ?.group(1);
    if (prompt != null) {
      _add(prompt);
      _wait = Completer<String>();
      setState(() => _state = RunState.waiting);
      final answer = await _wait!.future;
      if (!alive()) return;
      _add('> $answer', 2);
      setState(() => _state = RunState.running);
      await Future.delayed(const Duration(milliseconds: 500));
      if (!alive()) return;
    }
    _add('(مخرجات تجريبية - التنفيذ الفعلي لاحقاً)', 1);
    _add('[انتهى بكود 0]', 1);
    widget.script.lastRun = 'آخر تشغيل: الآن';
    scripts.value = List.of(scripts.value);
    setState(() => _state = RunState.idle);
  }

  void _send() {
    final t = _input.text;
    if (_state != RunState.waiting || t.trim().isEmpty) return;
    _input.clear();
    _wait?.complete(t);
    _wait = null;
  }

  void _stop() {
    if (_state == RunState.idle) return;
    _runId++;
    _wait?.complete('');
    _wait = null;
    _add('[تم الإيقاف]', 1);
    setState(() => _state = RunState.idle);
  }

  @override
  Widget build(BuildContext context) {
    final idle = _state == RunState.idle;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Header(title: widget.script.name, back: true, mono: true),
          Expanded(flex: 4, child: _editor()),
          Expanded(flex: 5, child: _consoleBox()),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Row(children: [
              Expanded(
                  child: PButton(
                      label: 'تشغيل',
                      icon: Icons.play_arrow_rounded,
                      onPressed: idle ? _run : null)),
              const SizedBox(width: 12),
              SizedBox(
                width: 120,
                height: 52,
                child: OutlinedButton(
                  onPressed: idle ? null : _stop,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: C.text,
                    side: const BorderSide(color: Color(0xFF3A4A44)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    textStyle: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.stop_rounded, size: 20),
                        SizedBox(width: 8),
                        Text('إيقاف'),
                      ]),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _editor() => Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        decoration: _box(C.surface),
        clipBehavior: Clip.antiAlias,
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
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: false,
                  cursorColor: C.accent,
                  style: mono,
                  decoration: const InputDecoration.collapsed(hintText: null),
                ),
              ),
            ]),
          ),
        ),
      );

  Widget _consoleBox() {
    final waiting = _state == RunState.waiting;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      decoration: _box(C.console),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: C.border))),
          child: const Text('الإخراج · تشغيل تجريبي',
              style: TextStyle(fontSize: 12, color: C.muted)),
        ),
        Expanded(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(14),
              itemCount: _lines.length,
              itemBuilder: (_, i) {
                final l = _lines[i];
                return Text(l.text,
                    style: mono.copyWith(
                        color: l.kind == 1
                            ? C.dim
                            : l.kind == 2
                                ? C.accent
                                : C.text));
              },
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: C.border))),
          child: Row(children: [
            Expanded(
              child: SizedBox(
                height: 44,
                child: TextField(
                  controller: _input,
                  enabled: waiting,
                  onSubmitted: (_) => _send(),
                  textInputAction: TextInputAction.send,
                  style: const TextStyle(fontSize: 14),
                  cursorColor: C.accent,
                  decoration: InputDecoration(
                    hintText: 'اكتب هنا ثم أرسل',
                    hintStyle: const TextStyle(color: C.dim),
                    isDense: true,
                    filled: true,
                    fillColor: C.surface,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    border: _ob,
                    enabledBorder: _ob,
                    disabledBorder: _ob,
                    focusedBorder: _ob.copyWith(
                        borderSide: const BorderSide(color: C.accent)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              button: true,
              label: 'إرسال',
              child: Material(
                color: waiting ? C.accent : C.accent.withValues(alpha: .35),
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: _send,
                  child: const SizedBox(
                      width: 44,
                      height: 44,
                      child:
                          Icon(Icons.send_rounded, size: 20, color: C.onAccent)),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}
