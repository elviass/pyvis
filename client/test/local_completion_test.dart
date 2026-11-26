import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';
import 'package:pyvis_editor/local_completion.dart';
import 'package:pyvis_editor/python_analysis_service.dart';
import 'package:pyvis_editor/editor_decorations.dart';
import 'package:pyvis_editor/main.dart';
import 'basic_workflows_test.dart' show openFixture, realIo;

class LoopbackHttp extends HttpOverrides {}

class ControlledModel extends InlineCompletionModel {
  final requests =
      <({String prefix, String suffix, Completer<String?> reply})>[];
  bool get isObserved => hasListeners;
  @override
  bool get available => true;
  @override
  String get status => '本地续写就绪';
  @override
  void cancel() {}
  @override
  Future<String?> complete(String prefix, String suffix) {
    final reply = Completer<String?>();
    requests.add((prefix: prefix, suffix: suffix, reply: reply));
    return reply.future;
  }
}

class StreamingModel extends ControlledModel {
  final chunks = StreamController<String>();
  @override
  Stream<String> predictions(String prefix, String suffix) => chunks.stream;
}

void main() {
  testWidgets(
      'local FIM results remain previews, reject stale input and undo once',
      (tester) async {
    final model = ControlledModel();
    addTearDown(model.dispose);
    await openFixture(tester, {'main.py': 'scores = [1, 2]\nfor'},
        app: PyvisApp(aiEnabled: true, inlineModel: model));
    final code = tester.widget<CodeEditor>(find.byType(CodeEditor));
    final editor = code.controller!;
    final decoration = code.paragraphDecorator! as EditorDecorations;
    code.focusNode!.requestFocus();
    editor.selection = const CodeLineSelection.collapsed(index: 1, offset: 3);
    await tester.pump(const Duration(milliseconds: 400));
    expect(model.requests, hasLength(1));
    expect(model.requests.first.prefix, 'scores = [1, 2]\nfor');
    expect(decoration.ghost, isNull,
        reason: 'Model mode must not use a canned template');
    editor.replaceSelection(' index');
    await tester.pump(const Duration(milliseconds: 400));
    expect(model.requests, hasLength(2));
    model.requests.first.reply.complete(' item in scores:\n    print(item)');
    await realIo(tester, () async {});
    expect(decoration.ghost, isNull);
    expect(editor.text, 'scores = [1, 2]\nfor index');
    model.requests.last.reply.complete(' in scores:\n    print(index)');
    for (var i = 0; i < 30 && decoration.ghost == null; i++) {
      await realIo(tester, () async {});
    }
    expect(decoration.ghost?.suffix, ' in scores:\n    print(index)');
    expect(editor.text, 'scores = [1, 2]\nfor index');
    editor.replaceSelection(' in ');
    expect(decoration.ghost?.suffix, 'scores:\n    print(index)');
    await tester.pump(const Duration(milliseconds: 120));
    expect(model.requests, hasLength(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(
        editor.text, 'scores = [1, 2]\nfor index in scores:\n    print(index)');
    const menu = MethodChannel('dev.pyvis/editor_commands');
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(menu.name,
        menu.codec.encodeMethodCall(const MethodCall('editUndo')), (_) {});
    await tester.pumpAndSettle();
    expect(editor.text, 'scores = [1, 2]\nfor index in ');
    expect(tester.takeException(), isNull);
    expect(model.isObserved, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(model.isObserved, isFalse);
    void ownerListener() {}

    model.addListener(ownerListener);
    expect(model.isObserved, isTrue);
    model.removeListener(ownerListener);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('shows a validated streamed block before inference finishes',
      (tester) async {
    final model = StreamingModel();
    addTearDown(model.dispose);
    await openFixture(tester, {'main.py': 'items = [1, 2]\nfor item'},
        app: PyvisApp(aiEnabled: true, inlineModel: model));
    final code = tester.widget<CodeEditor>(find.byType(CodeEditor));
    final decoration = code.paragraphDecorator! as EditorDecorations;
    code.focusNode!.requestFocus();
    code.controller!.selection =
        const CodeLineSelection.collapsed(index: 1, offset: 8);
    await tester.pump(const Duration(milliseconds: 99));
    expect(model.chunks.hasListener, isFalse);
    await tester.pump(const Duration(milliseconds: 2));
    expect(model.chunks.hasListener, isTrue);
    model.chunks.add(' in items:');
    await realIo(tester, () async {});
    expect(decoration.ghost, isNull);
    model.chunks.add(' in items:\n    print(item)');
    for (var i = 0; i < 30 && decoration.ghost == null; i++) {
      await realIo(tester, () async {});
    }
    expect(decoration.ghost?.suffix, ' in items:\n    print(item)');
    expect(model.chunks.isClosed, isFalse);
    expect(model.chunks.hasListener, isFalse);
    unawaited(model.chunks.close());
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  test('real local model produces a validated Python continuation', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final engine = LocalCompletionModel(
          executable: File(
                  '../runtime/local_completion/macos-arm64/llama-b12470/llama-server')
              .absolute
              .path,
          model: File(
                  '../runtime/local_completion/${LocalCompletionModel.modelFilename}')
              .absolute
              .path);
      final checker = PythonAnalysisService();
      addTearDown(engine.dispose);
      addTearDown(checker.dispose);
      const source = 'Grades = {"Alice": 90, "Bob": 85}\n\nfor';
      final prediction = await engine.complete(source, '');
      expect(prediction, isNotNull);
      final valid = await checker.request({
        'action': 'validate_inline',
        'source': source,
        'line': 3,
        'column': 3,
        'prediction': prediction
      });
      expect(valid['prediction'], isNotNull);
      expect(prediction, contains('Grades'));
      expect(engine.status, contains('就绪'));
      await engine.stop();
      expect(engine.status, '本地续写待机');
    }, LoopbackHttp());
  },
      timeout: const Timeout(Duration(seconds: 60)),
      skip: !Platform.isMacOS ||
          !File('../runtime/local_completion/${LocalCompletionModel.modelFilename}')
              .existsSync());

  test('prediction protocol rejects markup and control tokens', () {
    expect(cleanInlinePrediction('```python\npass\n```'), isNull);
    expect(cleanInlinePrediction('<|fim_suffix|>'), isNull);
    expect(cleanInlinePrediction(' '), isNull);
    expect(cleanInlinePrediction(' item in values:\n    print(item)\n'),
        ' item in values:\n    print(item)');
  });
}
