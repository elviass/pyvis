import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:pyvis_editor/editor_decorations.dart';
import 'package:pyvis_editor/python_completion.dart';
import 'package:pyvis_editor/find_panel.dart';
import 'basic_workflows_test.dart' show openFixture, realIo;

Future<void> waitForHint(WidgetTester tester, Finder hint) async {
  // A cold offline semantic engine can finish after the default fixture wait,
  // particularly while the full suite starts other Python workers in parallel.
  for (var i = 0; i < 40 && hint.evaluate().isEmpty; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
  }
}

void main() {
  test(
      'first/last/visible lines and narrow viewports keep hints off source and lookup',
      () {
    const viewport = Rect.fromLTWH(50, 4, 300, 280);
    for (final top in [5.0, 100.0, 260.0]) {
      final caret = Rect.fromLTWH(330, top, 1, 22);
      final hint = placeParameterHint(caret, const Size(280, 30), viewport)!;
      expect(hint.left, greaterThanOrEqualTo(viewport.left));
      expect(hint.right, lessThanOrEqualTo(viewport.right));
      expect(hint.top, greaterThanOrEqualTo(viewport.top));
      expect(hint.bottom, lessThanOrEqualTo(viewport.bottom));
      expect(hint.overlaps(Rect.fromLTWH(50, top, 300, 22)), false);
    }
    const caret = Rect.fromLTWH(75, 5, 1, 22);
    const popup = Rect.fromLTWH(75, 27, 200, 120);
    final hint =
        placeParameterHint(caret, const Size(280, 30), viewport, avoid: popup)!;
    expect(hint.overlaps(popup), false);
    expect(hint.top, greaterThan(popup.bottom));
    expect(
        placeParameterHint(
            caret, const Size(280, 30), const Rect.fromLTWH(50, 4, 300, 40),
            avoid: popup),
        isNull);
  });

  testWidgets(
      'real editor first-line signature stays outside input; popup and find do not cover it',
      (tester) async {
    await openFixture(tester, {'main.py': ''});
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.focusNode!.requestFocus();
    await tester.pump();
    editor.controller!.replaceSelection('print(');
    await tester.pumpAndSettle();
    await realIo(tester, () async {});
    final hint = find.byKey(const ValueKey('parameter-hint'));
    await waitForHint(tester, hint);
    expect(hint, findsOneWidget);
    Rect currentLine() {
      final paragraph = tester
          .widget<DefaultCodeLineNumber>(find.byType(DefaultCodeLineNumber))
          .notifier
          .value!
          .paragraphs
          .first;
      final point = paragraph.getOffset(const TextPosition(offset: 6))!;
      final editorBounds = tester.getRect(find.byType(CodeEditor));
      return Rect.fromLTWH(
          editorBounds.left,
          editorBounds.top + paragraph.offset.dy + point.dy,
          editorBounds.width,
          paragraph.preferredLineHeight);
    }

    expect(tester.getRect(hint).overlaps(currentLine()), false);
    editor.controller!.replaceSelection('pri');
    await tester.pumpAndSettle();
    await realIo(tester, () async {});
    await waitForHint(tester, hint);
    expect(find.byType(PythonCompletionPopup), findsOneWidget);
    expect(hint, findsOneWidget);
    expect(
        tester
            .getRect(hint)
            .overlaps(tester.getRect(find.byType(PythonCompletionPopup))),
        false);
    expect(tester.getRect(hint).overlaps(currentLine()), false);
    editor.findController!.findMode();
    await tester.pumpAndSettle();
    expect(hint, findsNothing);
    expect(tester.getSize(find.byType(EditorFindPanel)).height, 38);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
