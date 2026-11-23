import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:pyvis_editor/editor_commands.dart';
import 'package:pyvis_editor/python_completion.dart';
import 'package:pyvis_editor/editor_chrome.dart';
import 'basic_workflows_test.dart' show openFixture, realIo;

Future<void> shortcut(WidgetTester tester, LogicalKeyboardKey key,
    {bool mac = true, bool alt = false, bool shift = false}) async {
  final primary =
      mac ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(primary);
  if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyUpEvent(primary);
  await tester.pumpAndSettle();
}

Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 40 && !ready(); i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
  }
}

void main() {
  for (final viaMenu in [false, true]) {
    testWidgets(
        'rename via ${viaMenu ? 'context submenu' : 'shortcut'} updates only its binding and supports undo',
        (tester) async {
      const original =
          'value = 1\ndef square(value):\n    return value * value  # value\nprint(value, "value")\n';
      await openFixture(tester, {'main.py': original});
      final editor = find.byType(CodeEditor);
      await tester.tap(editor);
      final controller = tester.widget<CodeEditor>(editor).controller!;
      if (viaMenu) {
        final field = find
            .byWidgetPredicate((w) => w.runtimeType.toString() == '_CodeField');
        final dynamic render = tester.renderObject(field);
        final Offset point = render.calculateTextPositionScreenOffset(
            const CodeLinePosition(index: 2, offset: 13), false);
        final mouse = await tester.startGesture(point + const Offset(1, 3),
            kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
        await mouse.up();
        await tester.pumpAndSettle();
        expect(find.text('重命名变量…'), findsNothing);
        await tester.tap(find.text('重构'));
        await tester.pumpAndSettle();
        await realIo(tester, () => tester.tap(find.text('重命名变量…')));
      } else {
        controller.selection =
            const CodeLineSelection.collapsed(index: 2, offset: 13);
        await realIo(tester, () async {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.f6);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        });
      }
      await waitFor(
          tester, () => find.byType(TextFormField).evaluate().isNotEmpty);
      if (viaMenu) {
        await tester.enterText(find.byType(TextFormField), 'for');
        await tester.pump();
        await realIo(tester, () => tester.tap(find.text('重命名')));
        await waitFor(
            tester, () => find.text('请输入有效的 Python 变量名').evaluate().isNotEmpty);
        expect(find.text('请输入有效的 Python 变量名'), findsOneWidget);
        expect(controller.text, original);
      }
      await tester.enterText(find.byType(TextFormField), 'amount');
      await tester.pump();
      await realIo(tester, () => tester.tap(find.text('重命名')));
      await waitFor(tester, () => controller.text.contains('square(amount)'));
      expect(controller.text,
          'value = 1\ndef square(amount):\n    return amount * amount  # value\nprint(value, "value")\n');
      controller.undo();
      expect(controller.text, original);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  testWidgets('rename on a builtin shows a dismissible editor hint',
      (tester) async {
    await openFixture(tester, {'main.py': 'print(1)\n'});
    final field = find.byType(CodeEditor);
    await tester.tap(field);
    tester.widget<CodeEditor>(field).controller!.selection =
        const CodeLineSelection.collapsed(index: 0, offset: 2);
    await realIo(tester, () async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f6);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    });
    final hint = find.text('请将光标放在当前文件定义的变量或参数上');
    await waitFor(tester, () => hint.evaluate().isNotEmpty);
    expect(hint, findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.byTooltip('关闭提示'));
    await tester.pumpAndSettle();
    expect(hint, findsNothing);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  test(
      'Mac and Windows keymaps use their native primary modifier and PyCharm line actions',
      () {
    for (final mac in [true, false]) {
      final map = PyCharmKeymap(mac);
      final copy = map.build(CodeShortcutType.copy)!.single as SingleActivator;
      expect(copy.meta, mac);
      expect(copy.control, !mac);
      final delete =
          map.build(CodeShortcutType.lineDelete)!.single as SingleActivator;
      expect(delete.trigger,
          mac ? LogicalKeyboardKey.backspace : LogicalKeyboardKey.keyY);
      final redo = map.build(CodeShortcutType.redo)!.single as SingleActivator;
      expect(redo.trigger, LogicalKeyboardKey.keyZ);
      expect(redo.shift, true);
      expect(map.build(CodeShortcutType.lineSelect), isEmpty);
      expect(map.build(CodeShortcutType.newLine)!.length, 2);
    }
  });
  test(
      'Python Enter indents suites and paired containers as one undo operation',
      () {
    final editor = CodeLineEditingController.fromText(
        'if value: # explanation', const CodeLineOptions(indentSize: 4));
    addTearDown(editor.dispose);
    editor.selection =
        CodeLineSelection.collapsed(index: 0, offset: editor.text.length);
    insertPythonNewLine(editor);
    expect(editor.text, 'if value: # explanation\n    ');
    editor.undo();
    expect(editor.text, 'if value: # explanation');
    editor.text = 'values = []';
    editor.selection = const CodeLineSelection.collapsed(index: 0, offset: 10);
    insertPythonNewLine(editor);
    expect(editor.text, 'values = [\n    \n]');
    expect(editor.selection.extentIndex, 1);
    expect(editor.selection.extentOffset, 4);
    editor.undo();
    expect(editor.text, 'values = []');
    editor.text = '"if value:"';
    editor.selection =
        CodeLineSelection.collapsed(index: 0, offset: editor.text.length);
    insertPythonNewLine(editor);
    expect(editor.text, '"if value:"\n');
  });
  test(
      'folding recognizes Python branches and recovers true source line indices',
      () {
    const source =
        'def f():\n    if True: # branch\n        return 1\n    return 0\nprint(f())\n';
    final editor = CodeLineEditingController.fromText(source);
    addTearDown(editor.dispose);
    final chunks = const PythonChunkAnalyzer().run(editor.codeLines);
    expect(chunks, contains(const CodeChunk(0, 4)));
    expect(chunks, contains(const CodeChunk(1, 3)));
    editor.collapseChunk(0, 4);
    expect(editor.index2lineIndex(1), 4);
    final builder = PythonPromptsBuilder(editor);
    editor.replaceSelection(
        'pri',
        const CodeLineSelection(
            baseIndex: 1, baseOffset: 0, extentIndex: 1, extentOffset: 10));
    expect(builder.suggestions(editor.text, 4, 3).map((p) => p.word),
        contains('print'));
    expect(revealSourceLine(editor, 2), 2);
    expect(editor.codeLines[2].text.trim(), 'return 1');
  });
  test(
      'f-string expressions and dictionary keys complete without literal corruption',
      () {
    expect(pythonCodePosition('f"literal {price.bi'), true);
    expect(pythonCodePosition('f"literal {{price.bi'), false);
    expect(pythonCodePosition('f"{data[\'name'), false);
    expect(pythonCodePosition('f"{data[\'name\']} literal'), false);
    final editor = CodeLineEditingController.fromText('Grades["na"]');
    addTearDown(editor.dispose);
    editor.selection = const CodeLineSelection.collapsed(index: 0, offset: 10);
    final builder = PythonPromptsBuilder(editor)
      ..semanticSource = editor.text
      ..semanticLine = 0
      ..semanticColumn = 10
      ..semanticCompletions = [
        {'name': '"name"', 'kind': '变量'}
      ];
    final candidate = builder.suggestions(editor.text, 0, 10).single;
    expect(candidate.autocomplete.word, 'name');
    expect(
        const PythonPrompt(word: 'empty', kind: '函数', hasParameters: false)
            .autocomplete
            .selection
            .extentOffset,
        7);
    final keyword = PythonPromptsBuilder(editor).suggestions('for', 0, 3).first;
    expect(keyword.word, 'for');
    expect(keyword.autocomplete.word, 'for ');
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets(
        'duplicate, comment and delete follow ${platform.name} shortcuts',
        (tester) async {
      await openFixture(tester, {'main.py': 'price = 20\n'});
      final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
      editor.focusNode!.requestFocus();
      editor.controller!.selection =
          const CodeLineSelection.collapsed(index: 0, offset: 5);
      await tester.pump();
      final mac = platform == TargetPlatform.macOS;
      await shortcut(tester, LogicalKeyboardKey.keyD, mac: mac);
      expect(editor.controller!.text, 'price = 20\nprice = 20\n');
      await shortcut(tester, LogicalKeyboardKey.slash, mac: mac);
      expect(editor.controller!.text, 'price = 20\n# price = 20\n');
      await shortcut(
          tester, mac ? LogicalKeyboardKey.backspace : LogicalKeyboardKey.keyY,
          mac: mac);
      expect(editor.controller!.text, 'price = 20\n');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(platform));
  }

  testWidgets(
      'format, definitions and safe fixes operate on the real editor and support undo',
      (tester) async {
    await openFixture(
        tester, {'main.py': 'values={\'name\':1}\nprint(values)\n'});
    var editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.focusNode!.requestFocus();
    await tester.pump();
    final original = editor.controller!.text;
    await shortcut(tester, LogicalKeyboardKey.keyL, alt: true);
    await waitFor(tester, () => editor.controller!.text != original);
    expect(editor.controller!.text, contains("'name': 1"));
    editor.controller!.undo();
    await tester.pumpAndSettle();
    expect(editor.controller!.text, original);
    editor.controller!.text = 'print(math.pi)\n';
    editor.controller!.selection =
        const CodeLineSelection.collapsed(index: 0, offset: 8);
    await tester.pumpAndSettle();
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('检查代码'));
    });
    await waitFor(
        tester, () => find.textContaining('未找到名称 math').evaluate().isNotEmpty);
    editor.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(find.text('导入 math'), findsOneWidget);
    await tester.tap(find.text('导入 math'));
    await tester.pumpAndSettle();
    expect(editor.controller!.text, 'import math\nprint(math.pi)\n');
    editor.controller!.undo();
    await tester.pumpAndSettle();
    expect(editor.controller!.text, 'print(math.pi)\n');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'quick documentation shows the resolved signature and source docstring',
      (tester) async {
    await openFixture(tester, {
      'main.py': 'def greet(name: str):\n'
          '    """Return a greeting for the given name."""\n'
          '    return name\n'
          'greet("Pyvis")\n',
    });
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.focusNode!.requestFocus();
    editor.controller!.selection =
        const CodeLineSelection.collapsed(index: 3, offset: 2);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await waitFor(tester, () => find.byTooltip('关闭文档').evaluate().isNotEmpty);
    expect(find.text('greet(name: str)'), findsOneWidget);
    expect(find.text('Return a greeting for the given name.'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byTooltip('关闭文档'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'go-to-line Enter closes its field after transition and preserves source',
      (tester) async {
    const source = 'a=1\nb=2\nc=3\nprint(a+b+c)\n';
    await openFixture(tester, {'main.py': source});
    final code = tester.widget<CodeEditor>(find.byType(CodeEditor));
    code.focusNode!.requestFocus();
    await tester.pump();
    await shortcut(tester, LogicalKeyboardKey.keyL);
    expect(find.text('转到行:列'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '4:1');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(code.controller!.selection.extentIndex, 3);
    expect(code.controller!.text, source);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('native macOS edit menu targets the editor and dialog field',
      (tester) async {
    await openFixture(tester, {'main.py': 'value=1\n'});
    final code = tester.widget<CodeEditor>(find.byType(CodeEditor));
    code.focusNode!.requestFocus();
    await tester.pump();
    code.controller!.replaceSelection('# ');
    await tester.pumpAndSettle();
    const menu = MethodChannel('dev.pyvis/editor_commands');
    Future<void> command(String name) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          menu.name, menu.codec.encodeMethodCall(MethodCall(name)), (_) {});
      await tester.pumpAndSettle();
    }

    await command('editUndo');
    expect(code.controller!.text, 'value=1\n');
    await command('editRedo');
    expect(code.controller!.text, '# value=1\n');
    await shortcut(tester, LogicalKeyboardKey.keyL);
    final field = tester.widget<TextField>(find.byType(TextField));
    await command('editSelectAll');
    expect(field.controller!.selection.baseOffset, 0);
    expect(field.controller!.selection.extentOffset,
        field.controller!.text.length);
    expect(code.controller!.text, '# value=1\n');
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'compact check status reports semantic errors and F2 navigates without full-width banners',
      (tester) async {
    await openFixture(
        tester, {'main.py': 'value: int = "text"\nprint(value.missing)\n'});
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('检查代码'));
    });
    await waitFor(tester,
        () => find.textContaining('not assignable').evaluate().isNotEmpty);
    expect(find.byType(InspectionBadge), findsOneWidget);
    expect(find.textContaining('not assignable'), findsOneWidget);
    var editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.focusNode!.requestFocus();
    editor.controller!.selection =
        const CodeLineSelection.collapsed(index: 0, offset: 0);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    expect(editor.controller!.selection.extentIndex, 0);
    expect(editor.controller!.selection.extentOffset, 13);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    expect(editor.controller!.selection.extentIndex, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
