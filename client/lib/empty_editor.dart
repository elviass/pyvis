import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'pyvis_theme.dart';

enum EmptyEditorAction {
  search('随处搜索'),
  file('转到文件'),
  recent('最近的文件'),
  navigate('导航栏');

  const EmptyEditorAction(this.label);
  final String label;
}

class EmptyEditor extends StatefulWidget {
  final bool mac, active;
  final ValueChanged<EmptyEditorAction> onAction;
  final ValueChanged<List<String>> onDrop;
  const EmptyEditor(
      {super.key,
      required this.mac,
      required this.active,
      required this.onAction,
      required this.onDrop});
  @override
  State<EmptyEditor> createState() => _EmptyEditorState();
}

class _EmptyEditorState extends State<EmptyEditor> {
  Duration? lastShift;
  bool hovering = false;
  KeyEventResult handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final shift = event.logicalKey == LogicalKeyboardKey.shiftLeft ||
        event.logicalKey == LogicalKeyboardKey.shiftRight;
    final previous = lastShift;
    lastShift = shift ? event.timeStamp : null;
    if (shift &&
        previous != null &&
        event.timeStamp - previous < const Duration(milliseconds: 400)) {
      lastShift = null;
      widget.onAction(EmptyEditorAction.search);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.active && (ModalRoute.isCurrentOf(context) ?? true);
    return DropTarget(
        enable: active,
        onDragEntered: (_) => setState(() => hovering = true),
        onDragExited: (_) => setState(() => hovering = false),
        onDragDone: (details) {
          setState(() => hovering = false);
          widget.onDrop(details.files.map((f) => f.path).toList());
        },
        child: CallbackShortcuts(
            bindings: {
              for (final (key, action) in [
                (LogicalKeyboardKey.keyP, EmptyEditorAction.file),
                (LogicalKeyboardKey.keyE, EmptyEditorAction.recent),
                (LogicalKeyboardKey.semicolon, EmptyEditorAction.navigate)
              ])
                SingleActivator(key,
                        meta: widget.mac,
                        control: !widget.mac,
                        shift: action == EmptyEditorAction.navigate):
                    () => widget.onAction(action)
            },
            child: Focus(
                autofocus: active,
                onKeyEvent: handleKey,
                child: Container(
                  constraints: const BoxConstraints.expand(),
                  decoration: BoxDecoration(
                    color: PyvisColors.background,
                    border:
                        hovering ? Border.all(color: PyvisColors.accent) : null,
                  ),
                ))));
  }
}
