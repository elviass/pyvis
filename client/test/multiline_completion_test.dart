import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:pyvis_editor/editor_decorations.dart';
import 'package:pyvis_editor/python_completion.dart';

void main() {
  test('continuations preserve typed names, comma spacing and an existing body',
      () {
    final editor = CodeLineEditingController();
    addTearDown(editor.dispose);
    final context = {
      'symbols': [
        {'name': 'Grades', 'detail': 'dict', 'line': 1}
      ]
    };
    for (final typed in [
      'for',
      'for ',
      'for key,value',
      'for key,value in Gra',
      'for key,value in Grades.i'
    ]) {
      editor.text = 'Grades={}\n$typed';
      editor.selection =
          CodeLineSelection.collapsed(index: 1, offset: typed.length);
      final ghost = inlineSuggestion(editor, context);
      expect(ghost, isNotNull, reason: typed);
      expect(
          '$typed${ghost!.suffix}',
          startsWith(typed.contains('key,value')
              ? 'for key,value in Grades.items():'
              : 'for key, value in Grades.items():'));
    }
    editor.text = 'Grades={}\nfor student\n    print(student)';
    editor.selection = const CodeLineSelection.collapsed(index: 1, offset: 11);
    expect(inlineSuggestion(editor, context)!.suffix, ' in Grades:');
  });

  testWidgets(
      'inline context is independent of diagnostics and survives typing only on the current line',
      (tester) async {
    final editor = CodeLineEditingController.fromText('Grades={}\n');
    final focus = FocusNode();
    final decorations = EditorDecorations(editor, focus);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CodeEditor(
                controller: editor,
                focusNode: focus,
                paragraphDecorator: decorations))));
    focus.requestFocus();
    editor.selection = const CodeLineSelection.collapsed(index: 1, offset: 0);
    decorations.setContext({
      'symbols': [
        {'name': 'Grades', 'detail': 'dict', 'line': 1}
      ]
    }, editor.text);
    editor.replaceSelection('for');
    await tester.pumpAndSettle();
    expect(decorations.ghost?.suffix, contains('Grades.items()'));
    editor.text = 'items=[]\nfor';
    editor.selection = const CodeLineSelection.collapsed(index: 1, offset: 3);
    await tester.pumpAndSettle();
    expect(decorations.ghost, isNull);
    decorations.setContext({
      'symbols': [
        {'name': 'items', 'detail': 'list', 'line': 1}
      ]
    }, editor.text);
    await tester.pumpAndSettle();
    expect(decorations.ghost?.suffix, ' item in items:\n    print(item)');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    decorations.dispose();
    focus.dispose();
    editor.dispose();
  });

  testWidgets(
      'multiline preview does not change source; Tab accepts and undo restores',
      (tester) async {
    final editor = CodeLineEditingController();
    editor.text = 'Grades={"Alice": 90}\nfor\nprint("end")';
    editor.selection = const CodeLineSelection.collapsed(index: 1, offset: 3);
    final focus = FocusNode();
    final decorations = EditorDecorations(editor, focus);
    final keys = PythonCompletionActions(editor,
        acceptInline: decorations.acceptInline,
        dismissInline: decorations.dismissInline);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CodeEditor(
                controller: editor,
                focusNode: focus,
                paragraphDecorator: decorations,
                shortcutOverrideActions: keys.actions))));
    focus.requestFocus();
    decorations.setAnalysis(
        {
          'symbols': [
            {'name': 'Grades', 'detail': 'dict', 'line': 1}
          ]
        },
        editor.text,
        []);
    await tester.pumpAndSettle();
    final original = editor.text;
    expect(decorations.ghost!.suffix,
        ' key, value in Grades.items():\n    print(key, value)');
    expect(editor.text, original);
    expect(focus.hasFocus, isTrue);
    expect(editor.isComposing, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(editor.text,
        'Grades={"Alice": 90}\nfor key, value in Grades.items():\n    print(key, value)\nprint("end")');
    editor.undo();
    await tester.pumpAndSettle();
    expect(editor.text, original);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(decorations.ghost, isNull);
    expect(editor.text, original);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    decorations.dispose();
    focus.dispose();
    editor.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  test('nested multiline suggestion retains indentation and excludes strings',
      () {
    final editor = CodeLineEditingController();
    addTearDown(editor.dispose);
    editor.text = 'if True:\n    try';
    editor.selection = const CodeLineSelection.collapsed(index: 1, offset: 7);
    expect(inlineSuggestion(editor, {})!.suffix,
        ':\n        pass\n    except Exception as error:\n        print(error)');
    editor.text = '"""\ntry';
    editor.selection = const CodeLineSelection.collapsed(index: 1, offset: 3);
    expect(inlineSuggestion(editor, {}), isNull);
  });
}
