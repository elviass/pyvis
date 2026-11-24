import 'dart:io';
import 'dart:math' as math;
import 'ide_chrome.dart';
import 'pyvis_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform;
import 'package:re_editor/re_editor.dart';
import 'inspection_style.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/languages/python.dart' as python;
import 'python_syntax.dart';

class InspectionBadge extends StatelessWidget {
  final List<Map<String, dynamic>> diagnostics;
  final bool busy;
  final String? failure;
  final VoidCallback onOpen, onNext, onPrevious;
  const InspectionBadge(
      {super.key,
      required this.diagnostics,
      required this.busy,
      this.failure,
      required this.onOpen,
      required this.onNext,
      required this.onPrevious});
  @override
  Widget build(BuildContext context) {
    final errors = diagnostics.where((d) => d['severity'] == 'error').length;
    final warnings = diagnostics
        .where((d) => d['severity'] != 'error' && d['severity'] != 'typo')
        .length;
    final typos = diagnostics.where((d) => d['severity'] == 'typo').length;
    final description = busy
        ? '正在检查…'
        : failure != null
            ? '代码检查不可用：$failure'
            : diagnostics.isEmpty
                ? '未发现问题'
                : '$errors 个错误，$warnings 个警告${typos > 0 ? '，$typos 处拼写' : ''}';
    Widget count(IconData icon, Color color, int value) =>
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 3),
          Text('$value', style: const TextStyle(fontSize: 11))
        ]);
    return Material(
        color: const Color(0xee1e1f22),
        borderRadius: BorderRadius.circular(4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Tooltip(
              message: '检查代码',
              child: InkWell(
                  onTap: onOpen,
                  child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 5),
                      child: Semantics(
                          label: description,
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            if (busy)
                              const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                      value: .65, strokeWidth: 1.5))
                            else if (failure != null)
                              const Icon(Icons.error_outline,
                                  size: 15, color: Color(0xffdb5c5c))
                            else if (diagnostics.isEmpty)
                              const Icon(Icons.check,
                                  size: 17, color: Color(0xff57965c))
                            else ...[
                              if (errors > 0)
                                count(Icons.error_outline,
                                    const Color(0xffdb5c5c), errors),
                              if (errors > 0 && warnings > 0)
                                const SizedBox(width: 7),
                              if (warnings > 0)
                                count(Icons.warning_amber_rounded,
                                    InspectionStyle.warning.color, warnings),
                              if (typos > 0) ...[
                                if (errors + warnings > 0)
                                  const SizedBox(width: 7),
                                count(Icons.spellcheck,
                                    InspectionStyle.typo.color, typos),
                              ],
                            ],
                          ]))))),
          if (diagnostics.isNotEmpty) ...[
            Tooltip(
                message: Platform.isAndroid ? '上一个问题' : '上一个问题 · Shift+F2',
                child: InkWell(
                    onTap: onPrevious,
                    child: const SizedBox(
                        width: 20,
                        height: 25,
                        child: Icon(Icons.keyboard_arrow_up, size: 16)))),
            Tooltip(
                message: Platform.isAndroid ? '下一个问题' : '下一个问题 · F2',
                child: InkWell(
                    onTap: onNext,
                    child: const SizedBox(
                        width: 20,
                        height: 25,
                        child: Icon(Icons.keyboard_arrow_down, size: 16)))),
          ],
        ]));
  }
}

class MiniMapRun {
  final int line, start, end;
  final Color color;
  const MiniMapRun(this.line, this.start, this.end, this.color);
}

List<MiniMapRun> pythonMiniMapRuns(String source) {
  final syntax = Highlight()..registerLanguage('python', python.langPython);
  final result = syntax.highlight(code: source, language: 'python');
  final renderer = TextSpanRenderer(
      const TextStyle(color: PyvisColors.text), pythonTokenTheme);
  result.render(renderer);
  final runs = <MiniMapRun>[];
  var line = 0, column = 0;
  void walk(TextSpan span, Color inherited) {
    final color = span.style?.color ?? inherited;
    final pieces = (span.text ?? '').split('\n');
    for (var i = 0; i < pieces.length; i++) {
      if (i > 0) {
        line++;
        column = 0;
      }
      for (final word in RegExp(r'\S+').allMatches(pieces[i])) {
        runs.add(
            MiniMapRun(line, column + word.start, column + word.end, color));
      }
      column += pieces[i].length;
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (child is TextSpan) walk(child, color);
    }
  }

  if (renderer.span != null) walk(renderer.span!, PyvisColors.text);
  return runs;
}

class EditorMiniMap extends StatefulWidget {
  final CodeLineEditingController editor;
  final ValueListenable<int> geometry;
  final CodeIndicatorValueNotifier? Function() paragraphs;
  final ValueChanged<int> onSelectLine;
  const EditorMiniMap(
      {super.key,
      required this.editor,
      required this.geometry,
      required this.paragraphs,
      required this.onSelectLine});
  @override
  State<EditorMiniMap> createState() => _EditorMiniMapState();
}

class _EditorMiniMapState extends State<EditorMiniMap> {
  String? source;
  List<MiniMapRun> runs = [];
  double dragOffset = 0;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: Listenable.merge([widget.editor, widget.geometry]),
      builder: (context, _) => LayoutBuilder(builder: (context, constraints) {
            final editor = widget.editor;
            if (source != editor.text) {
              source = editor.text;
              runs = pythonMiniMapRuns(source!);
            }
            final count = source!.split('\n').length;
            final visible = (widget.paragraphs()?.value?.paragraphs ?? [])
                .where((p) => p.index < editor.codeLines.length)
                .toList();
            final first = visible.isEmpty
                ? 0
                : editor.index2lineIndex(visible.first.index);
            final last = visible.isEmpty
                ? 0
                : editor.index2lineIndex(visible.last.index);
            const lineHeight = 2.0;
            final overflow = (count * lineHeight - constraints.maxHeight)
                .clamp(0, double.infinity);
            final mapOffset = (overflow *
                    (first / (count - (last - first + 1)).clamp(1, count))
                        .clamp(0, 1))
                .toDouble();
            int sourceLine(double y, double offset) =>
                ((y + offset) / lineHeight).floor().clamp(0, count - 1);
            return MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) => widget.onSelectLine(
                        sourceLine(d.localPosition.dy, mapOffset)),
                    onPanStart: (d) {
                      dragOffset = mapOffset;
                      widget.onSelectLine(
                          sourceLine(d.localPosition.dy, dragOffset));
                    },
                    onPanUpdate: (d) => widget.onSelectLine(
                        sourceLine(d.localPosition.dy, dragOffset)),
                    child: CustomPaint(
                        painter: _MiniMapPainter(
                            runs,
                            mapOffset,
                            first,
                            last,
                            editor
                                .index2lineIndex(editor.selection.extentIndex)),
                        size: Size.infinite)));
          }));
}

class _MiniMapPainter extends CustomPainter {
  final List<MiniMapRun> runs;
  final double offset;
  final int first, last, current;
  _MiniMapPainter(this.runs, this.offset, this.first, this.last, this.current);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = PyvisColors.canvas);
    canvas.drawLine(Offset.zero, Offset(0, size.height),
        Paint()..color = const Color(0xff34353a));
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(
        Rect.fromLTRB(
            1, first * 2 - offset, size.width, (last + 1) * 2 - offset),
        Paint()..color = const Color(0x08ffffff));
    canvas.drawRect(Rect.fromLTWH(1, current * 2 - offset, size.width - 1, 2),
        Paint()..color = const Color(0xff293d68));
    for (final run in runs) {
      final y = run.line * 2 - offset;
      if (y < -2 || y > size.height) continue;
      canvas.drawRect(
          Rect.fromLTWH(5 + run.start * .8, y,
              ((run.end - run.start) * .8).clamp(.8, double.infinity), 1),
          Paint()..color = run.color.withValues(alpha: .8));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MiniMapPainter old) =>
      old.runs != runs ||
      old.offset != offset ||
      old.first != first ||
      old.last != last ||
      old.current != current;
}

class EditorMenuEntry {
  final String id, title, shortcut;
  final VoidCallback action;
  final bool enabled;
  const EditorMenuEntry(this.id, this.title, this.action,
      {this.shortcut = '', this.enabled = true});
}

class EditorContextMenuController implements SelectionToolbarController {
  final List<EditorMenuEntry> Function() entries;
  final VoidCallback onShow;
  final _menu = MenuController();
  final _anchor = GlobalKey();
  ValueNotifier<bool>? _visibility;
  OverlayEntry? _mobileMenu;

  Widget wrap(Widget child) => defaultTargetPlatform == TargetPlatform.android
      ? child
      : MenuAnchor(
          key: _anchor,
          controller: _menu,
          onClose: () {
            _visibility?.value = false;
            _visibility = null;
          },
          menuChildren: [
            for (final entry in entries()) ...[
              if (const {'definition', 'renameVariable', 'format', 'inspect'}
                  .contains(entry.id))
                const Divider(),
              if (entry.id == 'renameVariable')
                SubmenuButton(
                    menuChildren: [_button(entry)], child: const Text('重构'))
              else
                _button(entry)
            ]
          ],
          child: child);

  Widget _button(EditorMenuEntry entry) => MenuItemButton(
      onPressed: entry.enabled ? entry.action : null,
      trailingIcon: Platform.isAndroid || entry.shortcut.isEmpty
          ? null
          : Text(entry.shortcut,
              style: const TextStyle(fontSize: 11, color: PyvisColors.muted)),
      child: Text(entry.title));

  EditorContextMenuController(this.entries, this.onShow);
  @override
  void show(
      {required BuildContext context,
      required CodeLineEditingController controller,
      required TextSelectionToolbarAnchors anchors,
      Rect? renderRect,
      required LayerLink layerLink,
      required ValueNotifier<bool> visibility}) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      hide(context);
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) return;
      onShow();
      _mobileMenu = OverlayEntry(builder: (context) {
        return ValueListenableBuilder<bool>(
            valueListenable: visibility,
            builder: (context, visible, _) => visible
                ? _AndroidSelectionMenu(
                    entries: entries(),
                    anchors: anchors,
                    overlay: overlay,
                    dismiss: () => hide(context))
                : const SizedBox.shrink());
      });
      overlay.insert(_mobileMenu!);
      return;
    }
    final box = _anchor.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || _menu.isOpen) return;
    onShow();
    _visibility = visibility;
    _menu.open(position: box.globalToLocal(anchors.primaryAnchor));
  }

  @override
  void hide(BuildContext context) {
    final mobile = _mobileMenu;
    _mobileMenu = null;
    mobile?.remove();
    mobile?.dispose();
    // Desktop MenuAnchor manages clicks and focus while a submenu is open.
  }
}

class _AndroidSelectionMenu extends StatefulWidget {
  const _AndroidSelectionMenu({
    required this.entries,
    required this.anchors,
    required this.overlay,
    required this.dismiss,
  });

  final List<EditorMenuEntry> entries;
  final TextSelectionToolbarAnchors anchors;
  final OverlayState overlay;
  final VoidCallback dismiss;

  @override
  State<_AndroidSelectionMenu> createState() => _AndroidSelectionMenuState();
}

class _AndroidSelectionMenuState extends State<_AndroidSelectionMenu> {
  static const quickIds = {'cut', 'copy', 'paste'};
  bool expanded = false;

  Widget button(EditorMenuEntry entry, {bool list = false}) {
    return TextButton(
        style:
            list ? TextButton.styleFrom(alignment: Alignment.centerLeft) : null,
        onPressed: entry.enabled
            ? () {
                widget.dismiss();
                entry.action();
              }
            : null,
        child: Text(entry.title));
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.viewInsetsOf(context);
    final screen = MediaQueryData.fromView(View.of(context));
    final box = widget.overlay.context.findRenderObject() as RenderBox;
    final padding = screen.viewPadding;
    final safe = Rect.fromPoints(
        box.globalToLocal(Offset(padding.left, padding.top)),
        box.globalToLocal(Offset(screen.size.width - padding.right,
            screen.size.height - math.max(padding.bottom, insets.bottom))));
    final viewport = safe.intersect(Offset.zero & box.size).deflate(8);
    if (viewport.height < 48 || viewport.width <= 0) {
      return const SizedBox.shrink();
    }
    final top = box.globalToLocal(widget.anchors.primaryAnchor);
    final bottom = box.globalToLocal(
        widget.anchors.secondaryAnchor ?? widget.anchors.primaryAnchor);
    final quick = widget.entries.where((entry) => quickIds.contains(entry.id));
    final other = widget.entries.where((entry) => !quickIds.contains(entry.id));
    return CodeEditorTapRegion(
        onTapOutside: (_) => widget.dismiss(),
        child: CustomSingleChildLayout(
            delegate:
                _AndroidSelectionMenuLayout(viewport, top, bottom, expanded),
            child: Material(
                key: const ValueKey('android-selection-menu'),
                color: PyvisColors.raised,
                elevation: 5,
                borderRadius: BorderRadius.circular(10),
                clipBehavior: Clip.antiAlias,
                child: ExcludeFocus(
                    child: expanded
                        ? SizedBox(
                            width: 230,
                            child: SingleChildScrollView(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                  TextButton.icon(
                                      onPressed: () =>
                                          setState(() => expanded = false),
                                      icon: const Icon(Icons.arrow_back,
                                          size: 16),
                                      label: const Text('返回')),
                                  for (final entry in other)
                                    button(entry, list: true),
                                ])))
                        : SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              for (final entry in quick) button(entry),
                              if (other.isNotEmpty)
                                IconButton(
                                    tooltip: '更多编辑操作',
                                    onPressed: () =>
                                        setState(() => expanded = true),
                                    icon: const Icon(Icons.more_horiz)),
                            ]))))));
  }
}

class _AndroidSelectionMenuLayout extends SingleChildLayoutDelegate {
  const _AndroidSelectionMenuLayout(
      this.viewport, this.start, this.end, this.expanded);

  final Rect viewport;
  final Offset start, end;
  final bool expanded;
  static const gap = 10.0;

  double get above => start.dy.clamp(viewport.top, viewport.bottom) - gap;
  double get below => end.dy.clamp(viewport.top, viewport.bottom) + gap;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final space = math.max(above - viewport.top, viewport.bottom - below);
    return BoxConstraints(
        maxWidth: viewport.width,
        maxHeight: math
            .max(space, expanded ? 96.0 : 48.0)
            .clamp(0.0, math.min(viewport.height, expanded ? 280.0 : 48.0)));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final useAbove = above - viewport.top >= childSize.height ||
        (viewport.bottom - below < childSize.height &&
            above - viewport.top >= viewport.bottom - below);
    final anchor = useAbove ? start : end;
    final y = useAbove ? above - childSize.height : below;
    return Offset(
        (anchor.dx - childSize.width / 2)
            .clamp(viewport.left, viewport.right - childSize.width),
        y.clamp(viewport.top, viewport.bottom - childSize.height));
  }

  @override
  bool shouldRelayout(_AndroidSelectionMenuLayout oldDelegate) =>
      viewport != oldDelegate.viewport ||
      start != oldDelegate.start ||
      end != oldDelegate.end ||
      expanded != oldDelegate.expanded;
}

class EditorProblemsPane extends StatefulWidget {
  final List<Map<String, dynamic>> diagnostics;
  final String? failure;
  final ValueChanged<Map<String, dynamic>> onSelect;
  const EditorProblemsPane(
      {super.key,
      required this.diagnostics,
      this.failure,
      required this.onSelect});
  @override
  State<EditorProblemsPane> createState() => _EditorProblemsPaneState();
}

class _EditorProblemsPaneState extends State<EditorProblemsPane> {
  String filter = 'all';
  int selected = -1;
  @override
  Widget build(BuildContext context) {
    final issues = widget.diagnostics
        .where((d) =>
            filter == 'all' ||
            (filter == 'errors'
                ? d['severity'] == 'error'
                : filter == 'typos'
                    ? d['severity'] == 'typo'
                    : d['severity'] != 'error' && d['severity'] != 'typo'))
        .toList();
    final chosen =
        selected >= 0 && selected < issues.length ? issues[selected] : null;
    final errors =
        widget.diagnostics.where((d) => d['severity'] == 'error').length;
    final typos =
        widget.diagnostics.where((d) => d['severity'] == 'typo').length;
    final warnings = widget.diagnostics.length - errors - typos;
    final list = ListView.builder(
        itemCount: issues.length,
        itemExtent: 29,
        itemBuilder: (ctx, index) {
          final d = issues[index];
          return Tooltip(
              message: '${d['file']}:${d['line']}:${d['column']}',
              child: Material(
                  color: selected == index
                      ? const Color(0xff2d4b70)
                      : Colors.transparent,
                  child: InkWell(
                      onTap: () {
                        setState(() => selected = index);
                        widget.onSelect(d);
                      },
                      child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(children: [
                            Icon(
                                d['severity'] == 'error'
                                    ? Icons.error_outline
                                    : d['severity'] == 'typo'
                                        ? Icons.spellcheck
                                        : Icons.warning_amber_rounded,
                                size: 14,
                                color: InspectionStyle.forIssue(d).color),
                            const SizedBox(width: 7),
                            Expanded(
                                child: Text('${d['message']}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12))),
                            const SizedBox(width: 8),
                            Text(
                                '${d['file'].toString().split(RegExp(r'[/\\]')).last}:${d['line']}:${d['column']}',
                                style: const TextStyle(
                                    fontSize: 11, color: PyvisColors.muted)),
                          ])))));
        });
    return Material(
        color: PyvisColors.canvas,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
              height: 34,
              padding: const EdgeInsets.only(left: 13, right: 6),
              decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Color(0xff393b40)))),
              child: Row(children: [
                const Text('当前文件',
                    style: TextStyle(fontSize: 12, color: PyvisColors.accent)),
                const SizedBox(width: 18),
                Text(
                    '$errors 个错误 · $warnings 个警告${typos > 0 ? ' · $typos 处拼写' : ''}',
                    style: const TextStyle(
                        fontSize: 11, color: PyvisColors.muted)),
                const Spacer(),
                PopupMenuButton<String>(
                    tooltip: '筛选问题',
                    icon: const Icon(Icons.filter_list, size: 16),
                    initialValue: filter,
                    onSelected: (value) => setState(() {
                          filter = value;
                          selected = -1;
                        }),
                    itemBuilder: (ctx) => const [
                          IdeMenuItem(value: 'all', child: Text('全部问题')),
                          IdeMenuItem(value: 'errors', child: Text('仅错误')),
                          IdeMenuItem(value: 'warnings', child: Text('仅警告')),
                          IdeMenuItem(value: 'typos', child: Text('仅拼写'))
                        ]),
              ])),
          if (widget.failure != null)
            Padding(
                padding: const EdgeInsets.all(10),
                child: Text('部分检查未完成：${widget.failure}',
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xffdb5c5c)))),
          Expanded(
              child: issues.isEmpty
                  ? Center(
                      child: Text(widget.failure == null ? '未发现问题' : '检查尚未完成',
                          style: const TextStyle(
                              fontSize: 12, color: PyvisColors.muted)))
                  : LayoutBuilder(
                      builder: (ctx, constraints) => Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: list),
                                if (chosen != null &&
                                    constraints.maxWidth > 650) ...[
                                  const VerticalDivider(
                                      width: 1, color: Color(0xff393b40)),
                                  SizedBox(
                                      width: 280,
                                      child: SingleChildScrollView(
                                          padding: const EdgeInsets.all(12),
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                SelectableText(
                                                    '${chosen['hint']}',
                                                    style: const TextStyle(
                                                        fontSize: 12,
                                                        height: 1.5)),
                                                const SizedBox(height: 12),
                                                Text('${chosen['code']}',
                                                    style: const TextStyle(
                                                        fontSize: 11,
                                                        color:
                                                            PyvisColors.muted)),
                                              ]))),
                                ],
                              ]))),
        ]));
  }
}

/// Own the field until the dialog's route transition has fully unmounted it.
class EditorGoToLineDialog extends StatefulWidget {
  final String initial;
  final int lineCount;
  const EditorGoToLineDialog(
      {super.key, required this.initial, required this.lineCount});
  @override
  State<EditorGoToLineDialog> createState() => _EditorGoToLineDialogState();
}

class _EditorGoToLineDialogState extends State<EditorGoToLineDialog> {
  late final TextEditingController field =
      TextEditingController(text: widget.initial);
  String? error;
  bool closing = false;
  @override
  void initState() {
    super.initState();
    field.selection =
        TextSelection(baseOffset: 0, extentOffset: field.text.length);
  }

  void submit(String value) {
    final match =
        RegExp(r'^([1-9][0-9]*)(?::([1-9][0-9]*))?$').firstMatch(value.trim());
    final line = int.tryParse(match?.group(1) ?? '');
    if (line == null ||
        line > widget.lineCount ||
        (match?.group(2) != null && int.tryParse(match!.group(2)!) == null)) {
      setState(() => error = '请输入 1 至 ${widget.lineCount} 的行号，可附加列号');
      return;
    }
    close(value.trim());
  }

  void close([String? value]) {
    if (closing) return;
    closing = true;
    Navigator.pop(context, value);
  }

  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
      child: SizedBox(
          width: 310,
          child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('转到行:列',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 12),
                    TextField(
                        controller: field,
                        autofocus: true,
                        onSubmitted: submit,
                        onChanged: (_) {
                          if (error != null) setState(() => error = null);
                        },
                        decoration: InputDecoration(
                            hintText: '行:列', errorText: error, isDense: true)),
                    const SizedBox(height: 12),
                    Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                      TextButton(
                          onPressed: () => close(), child: const Text('取消')),
                      const SizedBox(width: 6),
                      FilledButton(
                          onPressed: () => submit(field.text),
                          child: const Text('转到'))
                    ])
                  ]))));
}

String renameErrorMessage(Object error) {
  if (error is StateError && error.message.startsWith('ValueError: ')) {
    final message = error.message.substring('ValueError: '.length);
    if (message.startsWith(RegExp(r'[\u4e00-\u9fff]'))) return message;
  }
  return '暂时无法分析变量，请稍后重试';
}

class RenameVariableDialog extends StatefulWidget {
  final String name, file;
  final int count;
  final Future<Map<String, dynamic>> Function(String) submit;
  const RenameVariableDialog(
      {super.key,
      required this.name,
      required this.file,
      required this.count,
      required this.submit});
  @override
  State<RenameVariableDialog> createState() => _RenameVariableDialogState();
}

class _RenameVariableDialogState extends State<RenameVariableDialog> {
  late String draft = widget.name;
  String? error;
  bool busy = false;
  bool get canSubmit =>
      !busy && draft.trim().isNotEmpty && draft != widget.name;

  Future<void> submit() async {
    if (!canSubmit) return;
    setState(() => busy = true);
    try {
      final result = await widget.submit(draft);
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context, result);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = renameErrorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
      backgroundColor: PyvisColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: SizedBox(
          width: 360,
          child: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                Padding(
                    padding: const EdgeInsets.fromLTRB(18, 15, 18, 12),
                    child: Row(children: [
                      const Icon(Icons.drive_file_rename_outline,
                          size: 17, color: PyvisColors.accent),
                      const SizedBox(width: 9),
                      const Text('重命名变量',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                    ])),
                const Divider(),
                Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${widget.file}  ·  共 ${widget.count} 处',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12, color: PyvisColors.muted)),
                          const SizedBox(height: 14),
                          const Text('新名称'),
                          const SizedBox(height: 6),
                          TextFormField(
                              initialValue: widget.name,
                              autofocus: true,
                              selectAllOnFocus: true,
                              readOnly: busy,
                              style: const TextStyle(
                                  fontFamily: 'JetBrains Mono', fontSize: 13),
                              decoration: InputDecoration(
                                  isDense: true,
                                  errorText: error,
                                  errorMaxLines: 3,
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 9)),
                              onChanged: (value) => setState(() {
                                    draft = value;
                                    error = null;
                                  }),
                              onFieldSubmitted: (_) => submit()),
                        ])),
                const Divider(),
                Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          OutlinedButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('取消')),
                          const SizedBox(width: 8),
                          FilledButton(
                              onPressed: canSubmit ? submit : null,
                              child: Text(busy ? '处理中…' : '重命名')),
                        ]))
              ]))));
}
