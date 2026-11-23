import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:pyvis_editor/editor_chrome.dart';
import 'package:pyvis_editor/python_syntax.dart';
import 'basic_workflows_test.dart' show openFixture;

void main() {
  test('overview retains multiline strings and syntax token colors', () {
    const source =
        'text = """hello\nworld"""\nfor value in [1]:\n    print(value)\n';
    final runs = pythonMiniMapRuns(source);
    expect(
        runs.any(
            (r) => r.line == 1 && r.color == pythonTokenTheme['string']!.color),
        isTrue);
    expect(
        runs.any((r) =>
            r.line == 2 && r.color == pythonTokenTheme['keyword']!.color),
        isTrue);
    expect(
        runs.any(
            (r) => r.line == 2 && r.color == pythonTokenTheme['number']!.color),
        isTrue);
    expect(
        runs.any((r) =>
            r.line == 3 && r.color == pythonTokenTheme['built_in']!.color),
        isTrue);
  });
  testWidgets('clicking the overview reveals a folded source line',
      (tester) async {
    await openFixture(tester, {
      'main.py':
          'value = 1\nif value:\n    print(1)\n    print(2)\n    print(3)\nprint(4)\n'
    });
    final code = tester.widget<CodeEditor>(find.byType(CodeEditor));
    code.controller!.collapseChunk(1, 5);
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byType(EditorMiniMap));
    await tester.tapAt(Offset(rect.left + 30, rect.top + 4 * 2 + 1));
    await tester.pumpAndSettle();
    final s = code.controller!.selection;
    expect(code.controller!.index2lineIndex(s.extentIndex), 4);
    expect(code.controller!.codeLines[s.extentIndex].text, '    print(3)');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  testWidgets('only the inner editor scrollbar scrolls beside the minimap',
      (tester) async {
    await openFixture(tester, {
      'main.py': '${List.generate(240, (i) => 'value_$i = $i').join('\n')}\n'
    });
    final code = tester.widget<CodeEditor>(find.byType(CodeEditor));
    final thumb = find.byKey(const ValueKey('editor-overview-thumb'));
    expect(thumb, findsOneWidget);
    final innerScrollbar = find.descendant(
        of: find.byType(CodeEditor),
        matching: find.byWidgetPredicate((widget) =>
            widget is RawScrollbar &&
            widget.scrollbarOrientation == ScrollbarOrientation.right));
    expect(innerScrollbar, findsNothing);
    final rect = tester.getRect(thumb);
    final minimap = tester.getRect(find.byType(EditorMiniMap));
    expect(rect.left, greaterThanOrEqualTo(minimap.right));
    final before = code.scrollController!.verticalScroller.offset;
    await tester.drag(thumb, const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(code.scrollController!.verticalScroller.offset, greaterThan(before));
    code.controller!.text = 'print(1)\n';
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-overview-thumb')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
