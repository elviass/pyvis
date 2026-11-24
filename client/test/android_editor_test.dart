import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pyvis_editor/editor_chrome.dart';
import 'package:pyvis_editor/python_completion.dart';
import 'package:re_editor/re_editor.dart';

import 'basic_workflows_test.dart' show openFixture;

void main() {
  final android = TargetPlatformVariant.only(TargetPlatform.android);

  testWidgets('selection menu stays off the selection and above the keyboard',
      (tester) async {
    tester.view.physicalSize = const Size(360, 680);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final code = CodeLineEditingController();
    final visible = ValueNotifier(true);
    addTearDown(code.dispose);
    addTearDown(visible.dispose);
    var copies = 0;
    final menu = EditorContextMenuController(
        () => [
              EditorMenuEntry('copy', '复制', () => copies++),
              EditorMenuEntry('format', '格式化', () {}),
            ],
        () {});
    final anchor = GlobalKey();
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(key: anchor))));
    final context = anchor.currentContext!;
    addTearDown(() => menu.hide(context));
    final toolbar = find.byKey(const ValueKey('android-selection-menu'));

    Future<Rect> show(double top, double bottom) async {
      menu.show(
          context: context,
          controller: code,
          anchors: TextSelectionToolbarAnchors(
              primaryAnchor: Offset(350, top),
              secondaryAnchor: Offset(350, bottom)),
          layerLink: LayerLink(),
          visibility: visible);
      await tester.pumpAndSettle();
      return tester.getRect(toolbar);
    }

    final upper = await show(20, 48);
    expect(upper.top, greaterThan(48));
    expect(upper.right, lessThan(360));
    final lower = await show(350, 382);
    expect(lower.bottom, lessThan(350));
    await tester.tap(find.byTooltip('更多编辑操作'));
    await tester.pumpAndSettle();
    expect(find.text('格式化'), findsOneWidget);
    expect(tester.getRect(toolbar).bottom, lessThan(350));
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(copies, 1);
    expect(toolbar, findsNothing);
  }, variant: android);

  testWidgets(
      'virtual Tab indents and accepts completion without leaving the editor',
      (tester) async {
    await openFixture(tester, {'main.py': 'x = 1\n'}, size: const Size(400, 780));
    final widget = tester.widget<CodeEditor>(find.byType(CodeEditor));
    final editor = widget.controller!;
    final focus = widget.focusNode!;
    focus.requestFocus();
    editor.selection = const CodeLineSelection.collapsed(index: 1, offset: 0);
    await tester.pumpAndSettle();
    final tab = find.byKey(const ValueKey('android-virtual-tab'));
    await tester.tap(tab);
    await tester.pumpAndSettle();
    expect(editor.text, 'x = 1\n    ');
    expect(focus.hasFocus, isTrue);

    editor.undo();
    editor.replaceSelection('pri');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.byType(PythonCompletionPopup), findsOneWidget);
    await tester.tap(tab);
    await tester.pumpAndSettle();
    expect(editor.text, 'x = 1\nprint()');
    expect(focus.hasFocus, isTrue);
    final undo = find.byKey(const ValueKey('android-virtual-undo'));
    final redo = find.byKey(const ValueKey('android-virtual-redo'));
    expect(tester.widget<IconButton>(redo).onPressed, isNull);
    await tester.tap(undo);
    await tester.pumpAndSettle();
    expect(editor.text, 'x = 1\npri');
    await tester.tap(redo);
    await tester.pumpAndSettle();
    expect(editor.text, 'x = 1\nprint()');
    expect(focus.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
  }, variant: android);
}
