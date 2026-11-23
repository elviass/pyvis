import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pyvis_editor/editor_settings.dart';
import 'package:re_editor/re_editor.dart';
import 'basic_workflows_test.dart' show openFixture;

void main() {
  testWidgets(
      'right-edge settings opens three levels and reaches real preferences',
      (tester) async {
    await openFixture(tester, {'main.py': 'print(1)\n'});
    expect(find.byTooltip('通知'), findsNothing);
    expect(find.byTooltip('学习提问'), findsOneWidget);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('新建 Python 文件'), findsOneWidget);
    expect(find.text('保存执行记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑器'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('常规'));
    await tester.pumpAndSettle();
    final leaf = find.text('代码检查…');
    expect(leaf, findsOneWidget);
    final rect = tester.getRect(leaf);
    final view = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(view.width));
    expect(rect.bottom, lessThanOrEqualTo(view.height));
    await tester.tap(leaf);
    await tester.pumpAndSettle();
    expect(find.byType(EditorSettingsDialog), findsOneWidget);
    expect(find.text('编辑器  ›  检查'), findsOneWidget);
    expect(find.text('类型和函数调用'), findsOneWidget);
    final apply = find.widgetWithText(OutlinedButton, '应用');
    expect(tester.widget<OutlinedButton>(apply).onPressed, isNull);
    await tester.tap(find.text('常规'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用软换行'));
    await tester.tap(find.text('显示行号'));
    await tester.tap(find.text('自动补全括号和引号'));
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(apply).onPressed, isNotNull);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    expect(find.byType(EditorSettingsDialog), findsOneWidget);
    expect(tester.widget<OutlinedButton>(apply).onPressed, isNull);
    await tester.tap(find.byTooltip('后退'));
    await tester.pumpAndSettle();
    expect(find.text('编辑器  ›  检查'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(EditorSettingsDialog), findsNothing);
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    expect(editor.wordWrap, isTrue);
    expect(editor.autocompleteSymbols, isFalse);
    expect(find.byType(DefaultCodeLineNumber), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
