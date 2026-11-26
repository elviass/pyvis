import 'learning_ai.dart';
import 'learning_ai_view.dart';
import 'dart:convert';
import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'editor_commands.dart';

class EditorPreferences {
  double fontSize;
  bool softWrap, miniMap, lineNumbers, highlightCurrentLine, autoClosePairs;
  bool warnBeforeSharingAiContext;
  Set<String> inspections;
  Set<String> dictionaryWords;
  EditorPreferences(
      {this.fontSize = 14,
      this.softWrap = false,
      this.miniMap = true,
      this.lineNumbers = true,
      this.highlightCurrentLine = true,
      this.autoClosePairs = true,
      this.warnBeforeSharingAiContext = true,
      Set<String>? inspections,
      Set<String>? dictionaryWords})
      : inspections = inspections ??
            {'syntax', 'types', 'references', 'unused', 'style', 'spelling'},
        dictionaryWords = dictionaryWords ?? <String>{};
  factory EditorPreferences.fromJson(Map json) => EditorPreferences(
      fontSize: (json['font_size'] is num
              ? (json['font_size'] as num).toDouble()
              : 14)
          .clamp(10, 28)
          .toDouble(),
      softWrap: json['soft_wrap'] == true,
      miniMap: json['mini_map'] != false,
      lineNumbers: json['line_numbers'] != false,
      highlightCurrentLine: json['highlight_current_line'] != false,
      autoClosePairs: json['auto_close_pairs'] != false,
      warnBeforeSharingAiContext: json['warn_before_sharing_ai_context'] != false,
      dictionaryWords:
          (json['dictionary_words'] as List? ?? []).whereType<String>().toSet(),
      inspections: json['inspections'] is List
          ? {
              ...(json['inspections'] as List).whereType<String>(),
              if (json['inspection_version'] != 2) 'spelling'
            }
          : null);
  Map<String, dynamic> toJson() => {
        'inspection_version': 2,
        'dictionary_words': dictionaryWords.toList(),
        'font_size': fontSize,
        'soft_wrap': softWrap,
        'mini_map': miniMap,
        'line_numbers': lineNumbers,
        'highlight_current_line': highlightCurrentLine,
        'auto_close_pairs': autoClosePairs,
        'warn_before_sharing_ai_context': warnBeforeSharingAiContext,
        'inspections': inspections.toList()
      };
  static File? get file {
    if (Platform.environment['FLUTTER_TEST'] == 'true') return null;
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null) return null;
    final support = Platform.isMacOS
        ? '$home/Library/Application Support'
        : Platform.environment['APPDATA'] ?? '$home/.local/share';
    return File('$support/Pyvis/editor-settings.json');
  }

  static Future<EditorPreferences?> load() async {
    final target = file;
    if (target == null || !await target.exists()) return null;
    return EditorPreferences.fromJson(
        jsonDecode(await target.readAsString()) as Map);
  }

  Future<void> save() async {
    final target = file;
    if (target == null) return;
    await target.parent.create(recursive: true);
    await target.writeAsString(jsonEncode(toJson()), flush: true);
  }
}

String inspectionGroup(Map issue) {
  final code = '${issue['code']}';
  if (code == 'Typo') return 'spelling';
  if (code == 'F401' || code == 'F841') return 'unused';
  if (code == 'UndefinedName' ||
      code.contains('reference') ||
      code.contains('import')) {
    return 'references';
  }
  if (issue['engine'] == 'ty') return 'types';
  if (code.startsWith('E') || code.startsWith('W')) return 'style';
  return 'syntax';
}

class EditorSettingsDialog extends StatefulWidget {
  final EditorPreferences preferences;
  final AiConfigStore? aiStore;
  final bool aiEnabled;
  final bool mac;
  final int initialPage;
  final Future<bool> Function(EditorPreferences)? onApply;
  const EditorSettingsDialog(
      {super.key,
      required this.preferences,
      required this.mac,
      this.aiEnabled = false,
      this.onApply,
      this.aiStore,
      this.initialPage = 0});
  @override
  State<EditorSettingsDialog> createState() => _EditorSettingsDialogState();
}

// Settings use a darker surface than the app's floating menus.
abstract final class _SettingsColors {
  static const background = Color(0xff191a1c);
  static const navigation = Color(0xff212326);
  static const divider = Color(0xff26282c);
  static const controlBorder = Color(0xff40434a);
  static const text = Color(0xffd1d3d9);
  static const muted = Color(0xff9fa2a8);
  static const accent = Color(0xff3871e1);
  static const selection = Color(0xff2a4371);
}

class _EditorSettingsDialogState extends State<EditorSettingsDialog> {
  late final EditorPreferences draft;
  late final TextEditingController fontSize;
  final search = TextEditingController();
  int page = 0;
  final history = <int>[];
  int historyIndex = 0;
  bool editorExpanded = true;
  bool applying = false;
  late Map<String, dynamic> applied;
  List<String> get titles =>
      ['字体', '常规', '检查', Platform.isAndroid ? '触控操作' : '键位', '模型'];
  @override
  void initState() {
    super.initState();
    page = widget.initialPage.clamp(0, 4);
    history.add(page);
    draft = EditorPreferences.fromJson(widget.preferences.toJson());
    applied = draft.toJson();
    fontSize = TextEditingController(text: draft.fontSize.round().toString());
  }

  void navigate(int index) {
    if (page == index) return;
    setState(() {
      history.removeRange(historyIndex + 1, history.length);
      history.add(index);
      historyIndex++;
      page = index;
      if (page != 3) editorExpanded = true;
    });
  }

  void stepHistory(int step) => setState(() {
        historyIndex += step;
        page = history[historyIndex];
        if (page != 3) editorExpanded = true;
      });

  bool get modified {
    final inspections = applied['inspections'] as List<String>;
    return draft.fontSize != applied['font_size'] ||
        draft.softWrap != applied['soft_wrap'] ||
        draft.miniMap != applied['mini_map'] ||
        draft.lineNumbers != applied['line_numbers'] ||
        draft.highlightCurrentLine != applied['highlight_current_line'] ||
        draft.autoClosePairs != applied['auto_close_pairs'] ||
        inspections.length != draft.inspections.length ||
        !draft.inspections.containsAll(inspections);
  }

  Future<void> apply() async {
    final callback = widget.onApply;
    if (callback == null || applying) return;
    final snapshot = draft.toJson();
    setState(() => applying = true);
    try {
      final saved = await callback(EditorPreferences.fromJson(snapshot));
      if (mounted && saved) applied = snapshot;
    } finally {
      if (mounted) setState(() => applying = false);
    }
  }

  @override
  void dispose() {
    fontSize.dispose();
    search.dispose();
    super.dispose();
  }

  Widget option(String label, bool value, ValueChanged<bool> onChanged,
          {String? detail}) =>
      Padding(
        padding: const EdgeInsets.only(left: 16, bottom: 2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            borderRadius: BorderRadius.circular(3),
            onTap: () => setState(() => onChanged(!value)),
            child: Row(children: [
              SizedBox(
                width: 24,
                height: 28,
                child: Checkbox(
                  value: value,
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(3)),
                  side: const BorderSide(color: Color(0xff5f6269)),
                  fillColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.selected)
                          ? _SettingsColors.accent
                          : _SettingsColors.navigation),
                  onChanged: (value) => setState(() => onChanged(value!)),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 13))),
            ]),
          ),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(30, 1, 0, 6),
              child: Text(detail,
                  style: const TextStyle(
                      fontSize: 12, height: 1.4, color: _SettingsColors.muted)),
            ),
        ]),
      );

  Widget section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(width: 10),
          const Expanded(child: Divider(color: _SettingsColors.controlBorder)),
        ]),
      );

  Widget navigation(int index) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Semantics(
          selected: page == index,
          button: true,
          child: Material(
            color:
                page == index ? _SettingsColors.selection : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            child: InkWell(
              onTap: () => navigate(index),
              borderRadius: BorderRadius.circular(4),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 24),
                child: Padding(
                  padding:
                      EdgeInsets.only(left: index == 3 ? 14 : 32, right: 8),
                  child: Row(children: [
                    Expanded(
                        child: Text(titles[index],
                            style: const TextStyle(fontSize: 13))),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );

  Widget field(String label, Widget child) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 6,
            children: [
              SizedBox(width: 60, child: Text(label)),
              child,
            ]),
      );

  Widget content() {
    final keymap = PyCharmKeymap(widget.mac);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (page == 0) ...[
        section('编辑器字体'),
        field(
            '字体：',
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                  color: _SettingsColors.background,
                  border: Border.all(color: _SettingsColors.controlBorder),
                  borderRadius: BorderRadius.circular(4)),
              child: const Text('JetBrains Mono',
                  style: TextStyle(fontFamily: 'JetBrains Mono', fontSize: 13)),
            )),
        field(
            '大小：',
            SizedBox(
                width: 68,
                child: TextField(
                  controller: fontSize,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 7)),
                  onChanged: (text) {
                    final value = double.tryParse(text);
                    if (value != null && value >= 10 && value <= 28) {
                      setState(() => draft.fontSize = value);
                    }
                  },
                  onEditingComplete: () {
                    fontSize.text = draft.fontSize.round().toString();
                    FocusScope.of(context).unfocus();
                  },
                ))),
        const Text('字号范围 10–28',
            style: TextStyle(fontSize: 12, color: _SettingsColors.muted)),
        const SizedBox(height: 24),
        section('预览'),
        Container(
          constraints: const BoxConstraints(minHeight: 164),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
              color: _SettingsColors.background,
              border: Border.all(color: _SettingsColors.controlBorder),
              borderRadius: BorderRadius.circular(4)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
                width: 40,
                alignment: Alignment.topRight,
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.only(right: 8),
                decoration: const BoxDecoration(
                  border:
                      Border(right: BorderSide(color: _SettingsColors.divider)),
                ),
                child: Text('1\n2\n3\n4\n5',
                    style: TextStyle(
                        fontFamily: 'JetBrains Mono',
                        fontSize: draft.fontSize,
                        height: 1.57,
                        color: _SettingsColors.muted))),
            Expanded(
                child: SingleChildScrollView(
              padding: const EdgeInsets.only(right: 12),
              scrollDirection: Axis.horizontal,
              child: Text.rich(
                  TextSpan(children: const [
                    TextSpan(
                        text: 'def ',
                        style: TextStyle(color: Color(0xffcf8e6d))),
                    TextSpan(
                        text: 'calculate',
                        style: TextStyle(color: Color(0xffffc66d))),
                    TextSpan(text: '(price, count):\n    '),
                    TextSpan(
                        text: 'return ',
                        style: TextStyle(color: Color(0xffcf8e6d))),
                    TextSpan(text: 'price * count\n\n'),
                    TextSpan(text: 'total = calculate('),
                    TextSpan(
                        text: '20, 3',
                        style: TextStyle(color: Color(0xff2aacb8))),
                    TextSpan(text: ')\n'),
                    TextSpan(
                        text: 'print',
                        style: TextStyle(color: Color(0xff8888c6))),
                    TextSpan(text: '(total)'),
                  ]),
                  style: TextStyle(
                      fontFamily: 'JetBrains Mono',
                      fontSize: draft.fontSize,
                      height: 1.57)),
            )),
          ]),
        ),
      ],
      if (page == 1) ...[
        section('自动换行'),
        option('使用软换行', draft.softWrap, (value) => draft.softWrap = value,
            detail: '长行在编辑区边缘折行，文件内容不变。'),
        const SizedBox(height: 20),
        section('编辑器显示'),
        option('显示行号', draft.lineNumbers, (value) => draft.lineNumbers = value),
        option('高亮当前行', draft.highlightCurrentLine,
            (value) => draft.highlightCurrentLine = value),
        option('显示代码缩略图', draft.miniMap, (value) => draft.miniMap = value,
            detail: '在宽窗口的代码编辑区右侧显示。'),
        const SizedBox(height: 20),
        section('输入辅助'),
        option('自动补全括号和引号', draft.autoClosePairs,
            (value) => draft.autoClosePairs = value,
            detail: '输入左括号或引号时自动插入配对符号。'),
      ],
      if (page == 2) ...[
        section('Python 检查'),
        const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text('选择在编辑时显示的问题类型。',
                style: TextStyle(fontSize: 12, color: _SettingsColors.muted))),
        for (final entry in const {
          'types': '类型和函数调用',
          'references': '名称与导入解析',
          'unused': '未使用的导入和变量',
          'style': '代码风格',
          'spelling': '拼写（绿色波浪线）',
        }.entries)
          option(entry.value, draft.inspections.contains(entry.key), (value) {
            if (value) {
              draft.inspections.add(entry.key);
            } else {
              draft.inspections.remove(entry.key);
            }
          }),
        const SizedBox(height: 16),
        const Text('运行前始终检查 Python 语法和缩进。',
            style: TextStyle(fontSize: 12, color: _SettingsColors.muted)),
      ],
      if (page == 3 && Platform.isAndroid) ...[
        section('手机操作'),
        for (final entry in const {
          '编辑代码': '点按代码定位光标，长按选择文字。剪切、复制和粘贴在选区旁显示，其余编辑操作在 ⋯ 里。',
          'Tab 键': '聚焦代码后，点按编辑区底部的 Tab 接受补全，或按当前设置插入缩进。',
          '撤回和恢复': '点按编辑区底部的左箭头撤回编辑，点按右箭头恢复已撤回的编辑。',
          '编辑器操作': '点按文件标签栏右侧的 ⋮，使用格式化、重命名、查看文档和转到行。',
          '代码补全': '点按候选列表中的名称插入代码。',
          '保存文件': '点按顶部 ⋮，选择保存。',
          '检查问题': '点按编辑区右上角的问题提示，使用上下箭头切换问题。',
          '运行代码': '点按顶部三角形运行按钮。',
          '节点图': '单指拖动空白平移，双指缩放，拖动节点标题移动节点。点按展开按钮进入代码块。',
        }.entries)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.key,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(entry.value),
                  ])),
      ],
      if (page == 3 && !Platform.isAndroid) ...[
        section('快捷键方案'),
        field('方案：', Text(widget.mac ? 'macOS 默认' : 'Windows 默认')),
        Container(
            decoration: BoxDecoration(
                border: Border.all(color: _SettingsColors.controlBorder)),
            child: Column(children: [
              Container(
                  color: _SettingsColors.navigation,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: const Row(
                      children: [Expanded(child: Text('操作')), Text('快捷键')])),
              for (final entry in const {
                EditorCommand.duplicate: '复制行',
                EditorCommand.format: '重新格式化代码',
                EditorCommand.imports: '优化导入',
                EditorCommand.definition: '转到声明',
                EditorCommand.documentation: '快速文档',
                EditorCommand.parameters: '参数信息',
                EditorCommand.intentions: '上下文操作',
                EditorCommand.nextIssue: '下一个问题',
                EditorCommand.goToLine: '转到行:列',
              }.entries)
                Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(children: [
                      Expanded(
                          child: Text(entry.value,
                              style: const TextStyle(fontSize: 12))),
                      Text(keymap.label(entry.key),
                          style: const TextStyle(
                              fontSize: 12, color: _SettingsColors.muted)),
                    ])),
            ])),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < 650;
    const keywords = [
      '字体 字号 大小 JetBrains Mono font',
      '常规 显示 软换行 自动换行 行号 高亮 当前行 代码缩略图 输入辅助 括号 引号',
      '检查 Python 类型 导入 变量 风格 拼写',
      '触控 操作 手机 保存 运行 节点图 键位 快捷键 macOS Windows',
      '模型 API AI 提供商 服务地址 密钥 学习问答',
    ];
    final query = search.text.trim().toLowerCase();
    final matches = titles.indexed
        .where((item) => keywords[item.$1].toLowerCase().contains(query))
        .toList();
    final theme = Theme.of(context);
    const inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(4)),
      borderSide: BorderSide(color: _SettingsColors.controlBorder),
    );
    return PopScope(
        canPop: !applying,
        child: Theme(
            data: theme.copyWith(
              colorScheme: theme.colorScheme.copyWith(
                primary: _SettingsColors.accent,
                onPrimary: Colors.white,
                onSurface: _SettingsColors.text,
              ),
              textTheme: theme.textTheme.apply(
                bodyColor: _SettingsColors.text,
                displayColor: _SettingsColors.text,
              ),
              dividerTheme:
                  theme.dividerTheme.copyWith(color: _SettingsColors.divider),
              inputDecorationTheme: theme.inputDecorationTheme.copyWith(
                fillColor: _SettingsColors.background,
                hintStyle: const TextStyle(color: _SettingsColors.muted),
                prefixIconColor: _SettingsColors.muted,
                suffixIconColor: _SettingsColors.muted,
                enabledBorder: inputBorder,
                focusedBorder: inputBorder.copyWith(
                  borderSide: const BorderSide(color: _SettingsColors.accent),
                ),
              ),
            ),
            child: Dialog(
              surfaceTintColor: Colors.transparent,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(6)),
                side: BorderSide(color: _SettingsColors.controlBorder),
              ),
              clipBehavior: Clip.antiAlias,
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              backgroundColor: _SettingsColors.background,
              child: SizedBox(
                  width: 900,
                  height: (size.height - 48).clamp(0, page == 4 ? 800 : 690),
                  child: Column(children: [
                    SizedBox(
                        height: 36,
                        child: Row(children: [
                          const SizedBox(width: 16),
                          const Expanded(
                              child: Text('Pyvis 设置',
                                  style: TextStyle(fontSize: 13))),
                          IconButton(
                              tooltip: '关闭设置',
                              onPressed: applying
                                  ? null
                                  : () => Navigator.pop(context),
                              icon: const Icon(Icons.close, size: 16)),
                          const SizedBox(width: 4),
                        ])),
                    const Divider(),
                    Expanded(
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                          SizedBox(
                              width: narrow ? 112 : 186,
                              child: Column(children: [
                                Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: TextField(
                                      controller: search,
                                      onChanged: (_) => setState(() {}),
                                      onSubmitted: (_) {
                                        if (query.isNotEmpty &&
                                            matches.isNotEmpty) {
                                          navigate(matches.first.$1);
                                        }
                                      },
                                      decoration: InputDecoration(
                                          hintText: '搜索设置',
                                          prefixIcon: narrow
                                              ? null
                                              : const Icon(Icons.search,
                                                  size: 16),
                                          suffixIcon: query.isEmpty
                                              ? null
                                              : IconButton(
                                                  tooltip: '清除搜索',
                                                  padding: EdgeInsets.zero,
                                                  icon: const Icon(Icons.close,
                                                      size: 14),
                                                  onPressed: () => setState(
                                                      () => search.clear())),
                                          suffixIconConstraints:
                                              const BoxConstraints.tightFor(
                                                  width: 24, height: 24),
                                          prefixIconConstraints:
                                              const BoxConstraints(
                                                  minWidth: 28),
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 8, vertical: 7)),
                                    )),
                                Expanded(
                                    child: ListView(children: [
                                  if (matches.any((item) => item.$1 != 3))
                                    InkWell(
                                      onTap: () => setState(() =>
                                          editorExpanded = !editorExpanded),
                                      child: SizedBox(
                                          height: 26,
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12),
                                            child: Row(children: [
                                              Icon(
                                                  editorExpanded ||
                                                          query.isNotEmpty
                                                      ? Icons
                                                          .keyboard_arrow_down
                                                      : Icons.chevron_right,
                                                  size: 16),
                                              const SizedBox(width: 4),
                                              const Text('编辑器',
                                                  style:
                                                      TextStyle(fontSize: 13)),
                                            ]),
                                          )),
                                    ),
                                  if (editorExpanded || query.isNotEmpty)
                                    for (final item in matches
                                        .where((item) => item.$1 != 3))
                                      navigation(item.$1),
                                  if (matches.any((item) => item.$1 == 3)) ...[
                                    const SizedBox(height: 6),
                                    navigation(3),
                                  ],
                                  if (matches.isEmpty)
                                    const Padding(
                                        padding: EdgeInsets.all(12),
                                        child: Text('没有匹配项',
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: _SettingsColors.muted))),
                                ])),
                              ])),
                          const VerticalDivider(width: 1),
                          Expanded(
                              child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Container(
                                height: 40,
                                padding: EdgeInsets.symmetric(
                                    horizontal: narrow ? 14 : 20),
                                alignment: Alignment.centerLeft,
                                decoration: const BoxDecoration(
                                    border: Border(
                                        bottom: BorderSide(
                                            color: _SettingsColors.divider))),
                                child: Row(children: [
                                  Expanded(
                                      child: Text(
                                    page == 3
                                        ? titles[page]
                                        : '编辑器  ›  ${titles[page]}',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500),
                                  )),
                                  SizedBox(
                                      width: 26,
                                      height: 26,
                                      child: IconButton(
                                        padding: EdgeInsets.zero,
                                        tooltip: '后退',
                                        onPressed: historyIndex == 0
                                            ? null
                                            : () => stepHistory(-1),
                                        icon: const Icon(Icons.arrow_back,
                                            size: 15),
                                      )),
                                  SizedBox(
                                      width: 26,
                                      height: 26,
                                      child: IconButton(
                                        padding: EdgeInsets.zero,
                                        tooltip: '前进',
                                        onPressed:
                                            historyIndex + 1 == history.length
                                                ? null
                                                : () => stepHistory(1),
                                        icon: const Icon(Icons.arrow_forward,
                                            size: 15),
                                      )),
                                ]),
                              ),
                              Expanded(
                                  child: page == 4 && !widget.aiEnabled
                                      ? const Center(child: Text('开发中'))
                                      : page == 4
                                          ? Padding(
                                              padding: EdgeInsets.all(
                                                  narrow ? 14 : 20),
                                              child: AiSettingsPane(
                                                  store: widget.aiStore))
                                          : SingleChildScrollView(
                                              key: ValueKey(page),
                                              padding: EdgeInsets.all(
                                                  narrow ? 14 : 20),
                                              child: content())),
                            ],
                          )),
                        ])),
                    const Divider(),
                    Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (page != 4)
                                OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      backgroundColor:
                                          _SettingsColors.background,
                                      foregroundColor: _SettingsColors.text,
                                      side: const BorderSide(
                                          color: _SettingsColors.controlBorder),
                                    ),
                                    onPressed: applying
                                        ? null
                                        : () => Navigator.pop(context),
                                    child: const Text('取消')),
                              if (page != 4 && widget.onApply != null) ...[
                                const SizedBox(width: 8),
                                OutlinedButton(
                                  onPressed:
                                      modified && !applying ? apply : null,
                                  child: const Text('应用'),
                                ),
                              ],
                              const SizedBox(width: 8),
                              FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: _SettingsColors.accent,
                                    foregroundColor: Colors.white,
                                  ),
                                  onPressed: applying
                                      ? null
                                      : () => Navigator.pop(
                                          context, page == 4 ? null : draft),
                                  child: Text(page == 4 ? '关闭' : '确定')),
                            ])),
                  ])),
            )));
  }
}
