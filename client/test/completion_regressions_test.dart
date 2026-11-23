import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:pyvis_editor/python_completion.dart';
import 'package:pyvis_editor/editor_decorations.dart';
import 'basic_workflows_test.dart' show openFixture, realIo;

void desktopTest(String name, WidgetTesterCallback callback) =>
    testWidgets(name, callback,
        variant: TargetPlatformVariant.only(TargetPlatform.macOS));

Future<void> macSelector(WidgetTester tester, String selector) async {
  final client = tester.testTextInput.log
      .lastWhere((call) => call.method == 'TextInput.setClient')
      .arguments[0];
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec
          .encodeMethodCall(MethodCall('TextInputClient.performSelectors', [
        client,
        [selector]
      ])),
      (_) {});
  await tester.pumpAndSettle();
}

void main() {
  desktopTest(
      'main app: typing for shows a real context inline continuation with lookup',
      (tester) async {
    await openFixture(tester, {'main.py': 'Grades = {"Alice": 90}\n\n'});
    final widget = tester.widget<CodeEditor>(find.byType(CodeEditor));
    final controller = widget.controller!;
    widget.focusNode!.requestFocus();
    controller.selection =
        const CodeLineSelection.collapsed(index: 2, offset: 0);
    await tester.pump();
    controller.replaceSelection('for');
    await tester.pump(const Duration(milliseconds: 400));
    final decorations = widget.paragraphDecorator! as EditorDecorations;
    for (var i = 0;
        i < 30 &&
            (decorations.ghost == null ||
                find.byType(PythonCompletionPopup).evaluate().isEmpty);
        i++) {
      await realIo(tester, () async {});
    }
    expect(decorations.ghost?.suffix,
        ' key, value in Grades.items():\n    print(key, value)');
    expect(find.byType(PythonCompletionPopup), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(controller.text,
        'Grades = {"Alice": 90}\n\nfor key, value in Grades.items():\n    print(key, value)');
    controller.undo();
    await tester.pumpAndSettle();
    expect(controller.text, 'Grades = {"Alice": 90}\n\nfor');
    await macSelector(tester, 'insertTab:');
    expect(controller.text,
        'Grades = {"Alice": 90}\n\nfor key, value in Grades.items():\n    print(key, value)');
    await macSelector(tester, 'deleteBackward:');
    expect(controller.codeLines.last.text, '    print(key, value');
    await macSelector(tester, 'selectAll:');
    expect(controller.selection.isCollapsed, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  desktopTest(
      'main app: direct text changes trigger lookup and Tab confirms it',
      (tester) async {
    await openFixture(tester, {'main.py': ''});
    final widget = tester.widget<CodeEditor>(find.byType(CodeEditor));
    widget.focusNode!.requestFocus();
    await tester.pump();
    widget.controller!.replaceSelection('pri');
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pumpAndSettle();
    expect(find.byType(PythonCompletionPopup), findsOneWidget);
    await realIo(tester, () async {});
    expect(find.byType(PythonCompletionPopup), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(widget.controller!.text, 'print()');
    expect(widget.controller!.selection.extentOffset, 6);
    expect(find.byType(PythonCompletionPopup), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(PythonCompletionPopup), findsNothing);
    widget.controller!.undo();
    await tester.pumpAndSettle();
    expect(widget.controller!.text, 'pri');
    await tester.pumpWidget(const SizedBox());
  });

  for (final useTab in [true, false]) {
    desktopTest(
        '${useTab ? 'Tab replaces' : 'Enter preserves'} right identifier and existing parentheses',
        (tester) async {
      final editor = CodeLineEditingController();
      final focus = FocusNode();
      final popup = CodeAutocompleteController();
      final builder = PythonPromptsBuilder(editor);
      final keys = PythonCompletionActions(editor, popup: popup);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: CodeAutocomplete(
                  controller: popup,
                  promptsBuilder: builder,
                  viewBuilder: (_, notifier, selected) => PythonCompletionPopup(
                      notifier: notifier, onSelected: selected),
                  child: CodeEditor(
                      controller: editor,
                      focusNode: focus,
                      shortcutOverrideActions: keys.actions)))));
      focus.requestFocus();
      await tester.pump();
      editor.text = 'prialready(1)';
      editor.selection = const CodeLineSelection.collapsed(index: 0, offset: 3);
      await tester.pump();
      popup.request();
      await tester.pumpAndSettle();
      expect(find.byType(PythonCompletionPopup), findsOneWidget);
      await tester.sendKeyEvent(
          useTab ? LogicalKeyboardKey.tab : LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(editor.text, useTab ? 'print(1)' : 'print()already(1)');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
      focus.dispose();
    });
  }

  desktopTest('async refresh keeps selected word; Esc cancels pending lookup',
      (tester) async {
    final editor = CodeLineEditingController();
    final focus = FocusNode();
    final popup = CodeAutocompleteController();
    final builder = PythonPromptsBuilder(editor);
    final keys = PythonCompletionActions(editor, popup: popup);
    builder.analysis = {
      'builtins': [
        {'name': 'price', 'kind': '变量'},
        {'name': 'print', 'kind': '内置函数'}
      ]
    };
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CodeAutocomplete(
                controller: popup,
                promptsBuilder: builder,
                viewBuilder: (_, notifier, selected) => PythonCompletionPopup(
                    notifier: notifier, onSelected: selected),
                child: CodeEditor(
                    controller: editor,
                    focusNode: focus,
                    shortcutOverrideActions: keys.actions)))));
    focus.requestFocus();
    await tester.pump();
    editor.replaceSelection('pri');
    await tester.pump(const Duration(milliseconds: 80));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(popup.notifier!.value.prompts[popup.notifier!.value.index].word,
        'print');
    final element = tester.element(find.byType(PythonCompletionPopup));
    builder.analysis = {
      'builtins': [
        {'name': 'private', 'kind': '变量'},
        {'name': 'price', 'kind': '变量'},
        {'name': 'print', 'kind': '内置函数'}
      ]
    };
    popup.refresh();
    await tester.pump();
    expect(tester.element(find.byType(PythonCompletionPopup)), same(element));
    expect(popup.notifier!.value.prompts[popup.notifier!.value.index].word,
        'print');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    popup.refresh();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(PythonCompletionPopup), findsNothing);
    editor.replaceSelection('n');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(PythonCompletionPopup), findsNothing);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
    focus.dispose();
  });

  test(
      'composition owns Tab, Enter and arrows; no completion inside declarations/import calls',
      () {
    final editor = CodeLineEditingController();
    addTearDown(editor.dispose);
    editor.text = 'pri';
    editor.composing = const TextRange(start: 0, end: 3);
    final keys = PythonCompletionActions(editor);
    expect(
        keys.actions[CodeShortcutIndentIntent]!
            .consumesKey(const CodeShortcutIndentIntent()),
        false);
    expect(
        keys.actions[CodeShortcutNewLineIntent]!
            .consumesKey(const CodeShortcutNewLineIntent()),
        false);
    final builder = PythonPromptsBuilder(editor);
    expect(builder.suggestions(editor.text, 0, 3), isEmpty);
    editor.composing = TextRange.empty;
    expect(builder.suggestions('def pri', 0, 7), isEmpty);
    builder.analysis = {
      'symbols': [
        {'name': 'sqrt', 'kind': '函数'}
      ]
    };
    expect(
        builder
            .suggestions('from math import sq', 0, 19)
            .single
            .autocomplete
            .word,
        'sqrt');
  });

  test(
      'semantic member suggestions support chained expressions and complete exact callable names',
      () {
    final editor = CodeLineEditingController();
    addTearDown(editor.dispose);
    final builder = PythonPromptsBuilder(editor);
    builder.semanticSource = 'values[0].';
    builder.semanticLine = 0;
    builder.semanticColumn = 10;
    builder.semanticCompletions = [
      {'name': 'upper', 'kind': '方法'}
    ];
    expect(builder.suggestions('values[0].', 0, 10).single.word, 'upper');
    expect(
        builder.suggestions('print', 0, 5).single.autocomplete.word, 'print()');
    expect(builder.suggestions('print(', 0, 5), isEmpty);
    editor.text = 'if True:\n    try\n        work()';
    editor.selection = const CodeLineSelection.collapsed(index: 1, offset: 7);
    expect(inlineSuggestion(editor, {})?.suffix, ':');
  });
}
