import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:pyvis_editor/python_completion.dart';
import 'package:pyvis_editor/python_analysis_service.dart';
import 'package:pyvis_editor/line_theater.dart';
import 'basic_workflows_test.dart' show openFixture, realIo, waitForRealIo;

void desktopTest(String description, WidgetTesterCallback callback) =>
    testWidgets(description, callback,
        variant: TargetPlatformVariant.only(TargetPlatform.macOS));

void main() {
  test(
      'completion excludes comments, strings, unknown members and sibling locals',
      () {
    final controller = CodeLineEditingController();
    addTearDown(controller.dispose);
    final builder = PythonPromptsBuilder(controller);
    expect(
        builder.suggestions('pri', 0, 3).map((p) => p.word), contains('print'));
    expect(builder.suggestions('# pri', 0, 5), isEmpty);
    expect(builder.suggestions('"pri', 0, 4), isEmpty);
    expect(builder.suggestions("'''text\npri", 1, 3), isEmpty);
    expect(builder.suggestions('unknown.ap', 0, 10), isEmpty);
    builder.analysis = {
      'symbols': [
        {'name': 'private_local', 'kind': '变量', 'start': 1, 'end': 2},
        {'name': 'price', 'kind': '变量', 'start': 0, 'end': 0}
      ]
    };
    expect(
        builder
            .suggestions('def f():\n    private_local=1\npri', 2, 3)
            .map((p) => p.word),
        isNot(contains('private_local')));
    final builtin = PythonPromptsBuilder(controller)
        .suggestions('print(1)\npri', 1, 3)
        .firstWhere((p) => p.word == 'print');
    expect(builtin.autocomplete.word, 'print()');
    expect(builtin.autocomplete.selection.baseOffset, 6);
    expect(
        PythonPromptsBuilder(controller)
            .suggestions('pri(', 0, 3)
            .firstWhere((p) => p.word == 'print')
            .autocomplete
            .word,
        'print');
  });

  test('real Python analysis supplies scoped names and inferred list methods',
      () async {
    final service = PythonAnalysisService();
    addTearDown(service.dispose);
    final controller = CodeLineEditingController();
    addTearDown(controller.dispose);
    final builder = PythonPromptsBuilder(controller);
    builder.analysis =
        await service.analyze('items=[]\nitems.', '/lesson/main.py');
    expect(
        builder.suggestions('items=[]\nitems.ap', 1, 8).single.word, 'append');
    expect(builder.suggestions('items=[]\nitems.', 1, 6).map((p) => p.word),
        contains('append'));
    final check = await service
        .check({'/lesson/main.py': 'return 1'}, '/lesson/main.py', '/lesson');
    expect((check['diagnostics'] as List).single['severity'], 'error');
  });

  desktopTest(
      'typing opens real completion overlay; Enter inserts parentheses and undo restores input',
      (tester) async {
    final controller = CodeLineEditingController();
    final focus = FocusNode();
    final keys = PythonCompletionActions(controller);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CodeAutocomplete(
                promptsBuilder: PythonPromptsBuilder(controller),
                viewBuilder: (context, notifier, onSelected) {
                  keys.attach(notifier, onSelected);
                  return PythonCompletionPopup(
                      notifier: notifier,
                      onSelected: onSelected,
                      onClosed: () => keys.detach(notifier));
                },
                child: CodeEditor(
                    controller: controller,
                    shortcutOverrideActions: keys.actions,
                    focusNode: focus,
                    autofocus: true)))));
    focus.requestFocus();
    await tester.pump();
    final connection = tester.testTextInput.log
        .lastWhere((call) => call.method == 'TextInput.setClient')
        .arguments[0];
    final editing = tester.testTextInput.editingState!;
    final offset = editing['selectionExtent'] as int;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
            SystemChannels.textInput.name,
            SystemChannels.textInput.codec.encodeMethodCall(
                MethodCall('TextInputClient.updateEditingStateWithDeltas', [
              connection,
              {
                'deltas': [
                  {
                    'oldText': editing['text'],
                    'deltaText': 'pri',
                    'deltaStart': offset,
                    'deltaEnd': offset,
                    'selectionBase': offset + 3,
                    'selectionExtent': offset + 3,
                    'selectionAffinity': 'TextAffinity.downstream',
                    'selectionIsDirectional': false,
                    'composingBase': -1,
                    'composingExtent': -1
                  }
                ]
              }
            ])),
            (_) {});
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pumpAndSettle();
    expect(controller.text, 'pri');
    expect(controller.selection.extentOffset, 3);
    expect(find.byType(PythonCompletionPopup), findsOneWidget);
    expect(find.textContaining('print', findRichText: true), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.text, 'print()');
    expect(controller.selection.extentOffset, 6);
    controller.undo();
    await tester.pumpAndSettle();
    expect(controller.text, 'pri');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PythonCompletionPopup), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    focus.dispose();
  });

  desktopTest(
      'preflight blocks execution before a side effect and locates the syntax error',
      (tester) async {
    final directory = await openFixture(tester, {
      'main.py':
          'from pathlib import Path\nPath(__file__ + ".executed").write_text("bad")\nif True\n    pass\n'
    });
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('直接运行').first);
    });
    expect(find.textContaining('运行前检查未通过'), findsOneWidget);
    expect(find.textContaining("expected ':'"), findsOneWidget);
    expect(find.byType(LineTheater), findsNothing);
    final controller =
        tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
    expect(controller.selection.extentIndex, 2);
    await tester.runAsync(() async {
      expect(await directory.list().any((f) => f.path.endsWith('.executed')),
          false);
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  desktopTest(
      'preflight catches local import errors, but unrelated files do not block running',
      (tester) async {
    await openFixture(tester, {
      'main.py': 'from helper import value\nprint(value)\n',
      'helper.py': 'return 1\n'
    });
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('演示运行').first);
    });
    expect(find.textContaining('运行前检查未通过'), findsOneWidget);
    expect(find.textContaining('helper.py:1:1'), findsOneWidget);
    expect(find.byType(LineTheater), findsNothing);
    final helper =
        tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
    helper.text = 'value=7\n';
    await tester.pump();
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('直接运行').first);
    });
    expect(find.byType(CodeEditor), findsOneWidget);
    expect(find.byType(LineTheater), findsNothing);
    await waitForRealIo(tester, find.text('7\n', findRichText: true));
    await tester.tap(find.text('代码流程图'));
    await tester.pumpAndSettle();
    final corrected =
        tester.widget<LineTheater>(find.byType(LineTheater)).events;
    expect(
        corrected
            .where((e) => e['kind'] == 'output')
            .map((e) => e['text'])
            .join(),
        '7\n');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await openFixture(tester,
        {'main.py': 'print("valid entry")\n', 'unused.py': 'return 1\n'});
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('直接运行').first);
    });
    expect(find.byType(CodeEditor), findsOneWidget);
    expect(find.byType(LineTheater), findsNothing);
    await waitForRealIo(tester, find.text('valid entry\n', findRichText: true));
    await tester.tap(find.text('代码流程图'));
    await tester.pumpAndSettle();
    final events = tester.widget<LineTheater>(find.byType(LineTheater)).events;
    expect(
        events.where((e) => e['kind'] == 'output').map((e) => e['text']).join(),
        'valid entry\n');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  desktopTest(
      'live checks refresh on unsaved edits and clear stale diagnostics',
      (tester) async {
    await openFixture(tester, {'main.py': 'x=1\n'});
    final controller =
        tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
    controller.text = 'if True\n    pass\n';
    await tester.pump();
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('检查代码'));
    });
    for (var attempt = 0;
        attempt < 30 && find.textContaining("expected ':'").evaluate().isEmpty;
        attempt++) {
      await realIo(tester, () async {});
    }
    expect(find.textContaining("expected ':'"), findsOneWidget);
    controller.text = 'if True:\n    pass\n';
    await tester.pump();
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('检查代码'));
    });
    expect(find.textContaining("expected ':'"), findsNothing);
    for (var attempt = 0;
        attempt < 30 && find.text('未发现问题').evaluate().isEmpty;
        attempt++) {
      await realIo(tester, () async {});
    }
    expect(find.text('未发现问题'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
