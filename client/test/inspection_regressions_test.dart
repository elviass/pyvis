import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:pyvis_editor/editor_decorations.dart';
import 'package:pyvis_editor/inspection_style.dart';
import 'basic_workflows_test.dart' show openFixture, realIo;

Future<void> waitCheck(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 30 && !ready(); i++) {
    await realIo(tester, () async {});
  }
  expect(ready(), isTrue);
}

void main() {
  testWidgets(
      'actual checks render distinct type warning, unused code and spelling presentations',
      (tester) async {
    await openFixture(tester, {
      'main.py': 'import math\n# helo\nvalue: int = "text"\nprint(value)\n'
    });
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('检查代码'));
    });
    final code = tester.widget<CodeEditor>(find.byType(CodeEditor));
    final decoration = code.paragraphDecorator! as EditorDecorations;
    await waitCheck(
        tester, () => decoration.diagnostics.any((d) => d['code'] == 'Typo'));
    final unused =
        decoration.diagnostics.firstWhere((d) => d['code'] == 'F401');
    final typo = decoration.diagnostics.firstWhere((d) => d['code'] == 'Typo');
    final type = decoration.diagnostics
        .firstWhere((d) => d['code'] == 'invalid-assignment');
    expect(InspectionStyle.forIssue(unused).faded, isTrue);
    expect(InspectionStyle.forIssue(unused).wave, isFalse);
    expect(InspectionStyle.forIssue(typo).color, InspectionStyle.typo.color);
    expect(InspectionStyle.forIssue(type).color, InspectionStyle.warning.color);
    expect(find.byKey(const ValueKey('inspection-mark-1')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'adding a spelling word is an explicit intention and leaves source unchanged',
      (tester) async {
    const source = 'print("helo")\n';
    await openFixture(tester, {'main.py': source});
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('检查代码'));
    });
    final code = tester.widget<CodeEditor>(find.byType(CodeEditor));
    final decoration = code.paragraphDecorator! as EditorDecorations;
    await waitCheck(
        tester, () => decoration.diagnostics.any((d) => d['code'] == 'Typo'));
    code.focusNode!.requestFocus();
    code.controller!.selection =
        const CodeLineSelection.collapsed(index: 0, offset: 9);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(find.text('将 helo 加入词典'), findsOneWidget);
    await realIo(tester, () async {
      await tester.tap(find.text('将 helo 加入词典'));
    });
    await waitCheck(tester, () => decoration.diagnostics.isEmpty);
    expect(code.controller!.text, source);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
