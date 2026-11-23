import 'pyvis_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';

class EditorFindPanel extends StatelessWidget implements PreferredSizeWidget {
  final CodeFindController controller;
  const EditorFindPanel({super.key, required this.controller});
  @override
  Size get preferredSize => Size.fromHeight(controller.value == null
      ? 0
      : controller.value!.replaceMode
          ? 76
          : 38);
  @override
  Widget build(BuildContext context) {
    final state = controller.value;
    if (state == null) return const SizedBox.shrink();
    return Material(
        color: PyvisColors.surface,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
              height: 38,
              child: Row(children: [
                IconButton(
                    tooltip: '展开替换',
                    onPressed: controller.toggleMode,
                    icon: Icon(
                        state.replaceMode
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 16)),
                Expanded(
                    child: TextField(
                        controller: controller.findInputController,
                        focusNode: controller.findInputFocusNode,
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(
                            isDense: true,
                            hintText: '查找',
                            border: InputBorder.none),
                        onSubmitted: (_) => controller.nextMatch())),
                Text(
                    state.option.regExp == null
                        ? '正则无效'
                        : '${state.result?.matches.length ?? 0} 处',
                    style: const TextStyle(fontSize: 11)),
                IconButton(
                    tooltip: '区分大小写',
                    isSelected: state.option.caseSensitive,
                    onPressed: controller.toggleCaseSensitive,
                    icon: const Icon(Icons.text_fields, size: 16)),
                IconButton(
                    tooltip: '正则表达式',
                    isSelected: state.option.regex,
                    onPressed: controller.toggleRegex,
                    icon: const Icon(Icons.code, size: 16)),
                IconButton(
                    tooltip: '上一个匹配',
                    onPressed: controller.previousMatch,
                    icon: const Icon(Icons.keyboard_arrow_up, size: 16)),
                IconButton(
                    tooltip: '下一个匹配',
                    onPressed: controller.nextMatch,
                    icon: const Icon(Icons.keyboard_arrow_down, size: 16)),
                IconButton(
                    tooltip: '关闭查找',
                    onPressed: controller.close,
                    icon: const Icon(Icons.close, size: 16)),
              ])),
          if (state.replaceMode)
            SizedBox(
                height: 38,
                child: Row(children: [
                  const SizedBox(width: 48),
                  Expanded(
                      child: TextField(
                          controller: controller.replaceInputController,
                          focusNode: controller.replaceInputFocusNode,
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(
                              isDense: true,
                              hintText: '替换为',
                              border: InputBorder.none))),
                  TextButton(
                      onPressed: controller.replaceMatch,
                      child: const Text('替换')),
                  TextButton(
                      onPressed: controller.replaceAllMatches,
                      child: const Text('全部替换'))
                ])),
        ]));
  }
}
