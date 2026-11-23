import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pyvis_editor/learning_ai.dart';
import 'package:pyvis_editor/learning_ai_view.dart';
import 'package:pyvis_editor/main.dart';
import 'package:re_editor/re_editor.dart';
import 'basic_workflows_test.dart' show openFixture;

Future<void> enterAi(WidgetTester tester, Finder field, String text) async {
  await Scrollable.ensureVisible(tester.element(field), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.enterText(field, text);
}

Future<void> tapAi(WidgetTester tester, Finder target) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(target);
}

class _CatalogStore extends AiConfigStore {
  @override
  Future<AiProfiles?> loadModelCatalog() async => const AiProfiles([
        AiProfile('service', '测试服务', 'custom', AiConfig('', 'alpha', ''),
            modelIds: ['alpha', 'beta']),
      ], 'service');
}

class _StreamingStore extends _CatalogStore {
  @override
  Future<AiProfiles> loadProfiles({bool allowInteraction = true}) async =>
      (await loadModelCatalog())!;
}

class _PendingAnswer extends AiRequest {
  final done = Completer<String>();
  late void Function(String) emit;

  @override
  Future<String> send(
      AiConfig config, String question, Map<String, String> attachments,
      {void Function(String)? onText}) {
    emit = onText!;
    return done.future;
  }
}

void main() {
  testWidgets('reply continues while the learning panel is hidden',
      (tester) async {
    final request = _PendingAnswer();
    final messages = <AiMessage>[];
    final hidden = ValueNotifier(false);
    addTearDown(hidden.dispose);
    final panel = LearningAiPanel(
        available: const {},
        messages: messages,
        store: _StreamingStore(),
        createRequest: () => request);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ValueListenableBuilder<bool>(
                valueListenable: hidden,
                builder: (_, hide, child) =>
                    Offstage(offstage: hide, child: child),
                child: panel))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('提问方式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('读懂代码'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    request.emit('第一个变量');
    await tester.pump();
    expect(find.text('第一个变量'), findsOneWidget);
    hidden.value = true;
    await tester.pump();
    request.emit('是 x。');
    request.done.complete('第一个变量是 x。');
    await tester.pumpAndSettle();
    hidden.value = false;
    await tester.pumpAndSettle();
    expect(find.text('第一个变量是 x。'), findsOneWidget);
    expect(messages.length, 2);
  });
  testWidgets('settings masks key, saves and reloads via secure store',
      (tester) async {
    String? saved;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AiConfigStore.channel, (call) async {
      if (call.method == 'save') {
        saved = call.arguments as String;
        return null;
      }
      return saved;
    });
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(child: AiSettingsPane(custom: true)))));
    await tester.pumpAndSettle();
    await enterAi(tester, find.byKey(const ValueKey('ai-endpoint')),
        'https://example.com/v1');
    await enterAi(tester, find.byKey(const ValueKey('ai-model')), 'mock');
    await enterAi(tester, find.byKey(const ValueKey('ai-key')), 'test-secret');
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ai-key')))
            .obscureText,
        true);
    await tester.ensureVisible(find.text('保存模型配置'));
    await tapAi(tester, find.text('保存模型配置'));
    await tester.pumpAndSettle();
    expect(find.text('配置已安全保存。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(child: AiSettingsPane(custom: true)))));
    await tester.pumpAndSettle();
    expect(find.text('mock'), findsOneWidget);
    expect(find.text('默认模型'), findsOneWidget);
  });
  testWidgets(
      'provider presets clear foreign keys and profiles save independently',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? saved;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AiConfigStore.channel, (call) async {
      if (call.method == 'save') {
        saved = call.arguments as String;
        return null;
      }
      return saved;
    });
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: AiSettingsPane()))));
    await tester.pumpAndSettle();
    await tapAi(tester, find.text('自定义设置'));
    await tester.pumpAndSettle();
    await enterAi(tester, find.byKey(const ValueKey('ai-endpoint')),
        'https://first.example/v1');
    await enterAi(tester, find.byKey(const ValueKey('ai-model')), 'first');
    await enterAi(tester, find.byKey(const ValueKey('ai-key')), 'first-key');
    await tapAi(tester, find.text('保存模型配置'));
    await tester.pumpAndSettle();
    await tapAi(tester, find.text('添加服务商'));
    await tester.pumpAndSettle();
    await enterAi(tester, find.byKey(const ValueKey('ai-key')), 'foreign-key');
    await tapAi(tester, find.text('官方 · OpenAI'));
    await tester.pumpAndSettle();
    await tapAi(tester, find.text('官方 · DeepSeek').last);
    await tester.pumpAndSettle();
    await tapAi(tester, find.text('自定义设置'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ai-endpoint')))
            .controller!
            .text,
        'https://api.deepseek.com/v1');
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ai-key')))
            .controller!
            .text,
        isEmpty);
    await enterAi(tester, find.byKey(const ValueKey('ai-model')), 'second');
    await enterAi(tester, find.byKey(const ValueKey('ai-key')), 'second-key');
    await tapAi(tester, find.text('保存模型配置'));
    await tester.pumpAndSettle();
    final profiles = await AiConfigStore().loadProfiles();
    expect(profiles.profiles.length, 2);
    expect(profiles.profiles.first.config.key, 'first-key');
    expect(profiles.active!.config.key, 'second-key');
    expect(
        find.textContaining('当前问答服务：官方 · DeepSeek · second'), findsOneWidget);
  });
  testWidgets(
      'sibling tabs retain drafts, custom IDs persist, and cards edit correct category',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? raw;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AiConfigStore.channel, (call) async {
      if (call.method == 'save') {
        raw = call.arguments as String;
        return null;
      }
      return raw;
    });
    await tester.pumpWidget(const MaterialApp(home: AiSettingsDialog()));
    await tester.pumpAndSettle();
    await enterAi(tester, find.byKey(const ValueKey('ai-key')), 'provider-key');
    await tapAi(tester, find.text('自定义模型 API'));
    await tester.pumpAndSettle();
    expect(find.text('官方 · OpenAI'), findsNothing);
    await enterAi(
        tester, find.byKey(const ValueKey('ai-provider-id')), 'acme-gateway');
    await enterAi(tester, find.byKey(const ValueKey('ai-name')), '我的网关');
    await enterAi(tester, find.byKey(const ValueKey('ai-endpoint')),
        'https://gateway.example/v1');
    await enterAi(tester, find.byKey(const ValueKey('ai-key')), 'custom-key');
    await enterAi(
        tester, find.byKey(const ValueKey('ai-model')), 'custom-model');
    await tapAi(tester, find.text('模型提供商'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ai-key')))
            .controller!
            .text,
        'provider-key');
    await tapAi(tester, find.text('自定义模型 API'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ai-provider-id')))
            .controller!
            .text,
        'acme-gateway');
    await tapAi(tester, find.text('保存模型配置'));
    await tester.pumpAndSettle();
    expect((await AiConfigStore().loadProfiles()).active!.customId,
        'acme-gateway');
    await tapAi(tester, find.text('模型提供商'));
    await tester.pumpAndSettle();
    await tapAi(tester, find.text('编辑'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '自定义模型 API'))
            .selected,
        true);
    await enterAi(tester, find.byKey(const ValueKey('ai-name')), '未保存名称');
    await tapAi(tester, find.text('取消'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ai-name')))
            .controller!
            .text,
        '我的网关');
    await tapAi(tester, find.text('添加自定义 API'));
    await tester.pumpAndSettle();
    await enterAi(
        tester, find.byKey(const ValueKey('ai-provider-id')), 'acme-gateway');
    await enterAi(tester, find.byKey(const ValueKey('ai-endpoint')),
        'https://second.example/v1');
    await enterAi(tester, find.byKey(const ValueKey('ai-key')), 'second-key');
    await enterAi(tester, find.byKey(const ValueKey('ai-model')), 'model');
    await tapAi(tester, find.text('保存模型配置'));
    await tester.pumpAndSettle();
    expect(find.text('Provider ID 已存在，请使用其他标识。'), findsOneWidget);
    expect((await AiConfigStore().loadProfiles()).profiles.length, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('saved model IDs are independently selectable in learning Q&A',
      (tester) async {
    final store = AiConfigStore();
    String? raw;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AiConfigStore.channel, (call) async {
      if (call.method == 'save') {
        raw = call.arguments as String;
        return null;
      }
      return raw;
    });
    await store.saveProfiles(const AiProfiles([
      AiProfile('primary', '服务 A', 'openai',
          AiConfig('https://a.example/v1', 'alpha', 'key-a'),
          modelIds: ['alpha', 'beta']),
      AiProfile('secondary', '服务 B', 'custom',
          AiConfig('https://b.example/v1', 'alpha', 'key-b')),
    ], 'primary'));
    expect((await store.loadProfiles()).active!.modelIds, ['alpha', 'beta']);

    await tester.pumpWidget(MaterialApp(
        home:
            LearningAiPanel(available: const {}, messages: [], store: store)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('服务 A / alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('服务 A / beta').last);
    await tester.pumpAndSettle();
    expect(find.text('服务 A / beta'), findsOneWidget);
    await tester.tap(find.text('服务 A / beta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('服务 B / alpha').last);
    await tester.pumpAndSettle();
    expect(find.text('服务 B / alpha'), findsOneWidget);
  });

  testWidgets('right rail opens learning questions as an editor tab',
      (tester) async {
    await openFixture(tester, {'main.py': 'print(1)\n'},
        app: const PyvisApp(aiEnabled: true));
    final barrierCount = find.byType(ModalBarrier).evaluate().length;
    await tester.tap(find.byTooltip('学习提问'));
    await tester.pumpAndSettle();
    expect(find.byType(LearningAiPanel), findsOneWidget);
    expect(find.text('学习提问'), findsOneWidget);
    expect(find.byTooltip('模型 API 配置'), findsNothing);
    expect(find.byTooltip('移回侧栏'), findsOneWidget);
    expect(find.text('返回侧栏'), findsOneWidget);
    expect(find.byType(ModalBarrier).evaluate().length, barrierCount);
    final editor = find.byType(CodeEditor);
    expect(editor, findsNothing);
    final question =
        find.widgetWithText(TextField, '输入您的任务，使用 @ 添加文件或使用 / 输入命令');
    await tester.enterText(question, '未发送的问题');
    await tester.tap(find.text('返回侧栏'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(question).controller!.text, '未发送的问题');
    expect(editor.hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('收起学习提问'));
    await tester.pumpAndSettle();
    expect(find.byType(LearningAiPanel), findsNothing);
    expect(editor.hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('学习提问'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(question).controller!.text, '未发送的问题');
    expect(editor, findsNothing);
  });

  testWidgets('@ references use current editor content and can be removed',
      (tester) async {
    await openFixture(tester, {'main.py': 'print(1)\n'},
        app: const PyvisApp(aiEnabled: true));
    final editor =
        tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
    editor.text = 'print(99)\n';
    await tester.tap(find.byTooltip('学习提问'));
    await tester.pumpAndSettle();
    final input = find.widgetWithText(TextField, '输入您的任务，使用 @ 添加文件或使用 / 输入命令');
    await tester.enterText(input, '解释 @main.py');
    await tester.pumpAndSettle();
    await tapAi(tester, find.widgetWithText(TextButton, '文件 · main.py'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, '解释 ');
    expect(find.text('本次附带 1 项上下文'), findsOneWidget);

    await tapAi(tester, find.widgetWithText(InputChip, '文件 · main.py'));
    await tester.pumpAndSettle();
    expect(find.text('print(99)\n'), findsOneWidget);
    await tapAi(tester, find.text('返回提问'));
    await tester.pumpAndSettle();
    tester
        .widget<InputChip>(find.widgetWithText(InputChip, '文件 · main.py'))
        .onDeleted!();
    await tester.pumpAndSettle();
    expect(find.byType(InputChip), findsNothing);
    expect(find.textContaining('项上下文'), findsNothing);
    editor.selection = const CodeLineSelection(
        baseIndex: 0, baseOffset: 0, extentIndex: 0, extentOffset: 5);
    await tester.enterText(input, '解释 @代码');
    await tester.pumpAndSettle();
    await tapAi(tester, find.widgetWithText(TextButton, '代码 · main.py:L1–1'));
    await tester.pumpAndSettle();
    await tapAi(tester, find.widgetWithText(InputChip, '代码 · main.py:L1–1'));
    await tester.pumpAndSettle();
    expect(find.text('print'), findsOneWidget);
  });

  testWidgets(
      'project files and selected editor code can be dropped into questions',
      (tester) async {
    await openFixture(tester, {'main.py': 'print(1)\n'},
        app: const PyvisApp(aiEnabled: true));
    await tester.tap(find.byTooltip('学习提问'));
    await tester.pumpAndSettle();
    // The panel opens as an editor tab; move it back to the side so the
    // editor stays visible as a drop source.
    await tester.tap(find.text('返回侧栏'));
    await tester.pumpAndSettle();
    final panel = find.byType(LearningAiPanel);

    Future<void> dragIntoPanel(Offset start) async {
      final target = tester.getCenter(panel);
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveTo(target);
      await tester.pump();
      expect(find.text('松开以添加引用'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
    }

    final file = find
        .byWidgetPredicate((widget) =>
            widget is Draggable<LearningReference> &&
            widget.data?.label == '文件 · main.py')
        .first;
    await dragIntoPanel(tester.getCenter(file));
    expect(find.widgetWithText(InputChip, '文件 · main.py'), findsOneWidget);

    final editor =
        tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
    editor.selection = const CodeLineSelection(
        baseIndex: 0, baseOffset: 0, extentIndex: 0, extentOffset: 5);
    await tester.pumpAndSettle();
    final sourceField = find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_CodeField');
    final editorBounds = tester.getRect(sourceField);
    final selectedPoint = editorBounds.topLeft + const Offset(20, 14);
    await dragIntoPanel(selectedPoint);
    final code = find.widgetWithText(InputChip, '代码 · main.py:L1–1');
    expect(code, findsOneWidget);
    expect(find.text('本次附带 2 项上下文'), findsOneWidget);
    await tapAi(tester, code);
    await tester.pumpAndSettle();
    expect(find.text('print'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('native copy and paste moves selected code into the question',
      (tester) async {
    String? clipboard;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      } else if (call.method == 'Clipboard.getData') {
        return {'text': clipboard};
      }
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await openFixture(tester, {'main.py': 'print(1)\n'},
        app: const PyvisApp(aiEnabled: true));
    await tester.tap(find.byTooltip('学习提问'));
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(EditorPage));
    state.editorFocus.requestFocus();
    state.editor.selection = const CodeLineSelection(
        baseIndex: 0, baseOffset: 0, extentIndex: 0, extentOffset: 5);
    await tester.pumpAndSettle();
    await state.performNativeEdit('editCopy');
    expect(clipboard, 'print');
    final input = find.widgetWithText(TextField, '输入您的任务，使用 @ 添加文件或使用 / 输入命令');
    await tester.enterText(input, '解释 ');
    await state.performNativeEdit('editPaste');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, '解释 print');
  });

  testWidgets('learning questions request keychain authorization only on click',
      (tester) async {
    final interactions = <bool>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AiConfigStore.channel, (call) async {
      final interactive = call.arguments as bool;
      interactions.add(interactive);
      if (!interactive) throw PlatformException(code: 'keychain_locked');
      return '{"endpoint":"https://example.com/v1","model":"mock","key":"fixture"}';
    });
    await tester.pumpWidget(
        MaterialApp(home: LearningAiPanel(available: const {}, messages: [])));
    await tester.pumpAndSettle();
    expect(interactions, [false]);
    expect(find.text('解锁模型配置'), findsOneWidget);
    await tester.tap(find.text('解锁模型配置'));
    await tester.pumpAndSettle();
    expect(interactions, [false, true]);
    expect(find.textContaining('/ mock'), findsOneWidget);
    expect(find.text('解锁模型配置'), findsNothing);
  });

  testWidgets('switching cached models does not access keychain',
      (tester) async {
    final interactions = <bool>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AiConfigStore.channel, (call) async {
      interactions.add(call.arguments as bool);
      throw PlatformException(code: 'keychain_locked');
    });
    await tester.pumpWidget(MaterialApp(
        home: LearningAiPanel(
      available: const {},
      messages: [],
      store: _CatalogStore(),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试服务 / alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试服务 / beta').last);
    await tester.pumpAndSettle();
    expect(find.text('测试服务 / beta'), findsOneWidget);
    expect(interactions, isEmpty);

    await enterAi(tester, find.byType(TextField), '保留这条问题');
    await tapAi(tester, find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(interactions, [false]);
    expect(find.text('解锁模型配置'), findsOneWidget);
    expect(find.text('测试服务 / beta'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '保留这条问题');
  });

  testWidgets('missing config preserves question for recovery', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AiConfigStore.channel, (_) async => null);
    await tester.pumpWidget(
        MaterialApp(home: LearningAiPanel(available: const {}, messages: [])));
    await enterAi(tester, find.byType(TextField), '为什么');
    await tapAi(tester, find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(find.textContaining('尚未配置模型，请'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '为什么');
  });
  testWidgets(
      'editor carries selection, exact diagnostic and current step only on opt in',
      (tester) async {
    await openFixture(tester, {'main.py': 'x = 1\nprint(x)\n'},
        app: const PyvisApp(aiEnabled: true));
    final dynamic state = tester.state(find.byType(EditorPage));
    state.editor.selection = const CodeLineSelection(
        baseIndex: 0, baseOffset: 0, extentIndex: 0, extentOffset: 5);
    state.events = <Map<String, dynamic>>[
      {'seq': 1, 'line': 1, 'event': 'line', 'frames': []}
    ];
    state.openLearningAi(diagnostic: <String, dynamic>{
      'line': 7,
      'message': 'specific diagnostic'
    });
    await tester.pumpAndSettle();
    final dialog = tester.widget<LearningAiPanel>(find.byType(LearningAiPanel));
    expect(dialog.available['选中的代码'], 'x = 1');
    expect(dialog.available['当前错误'], contains('specific diagnostic'));
    expect(dialog.available['当前演示步骤'], contains('"seq": 1'));
    for (final check
        in tester.widgetList<FilterChip>(find.byType(FilterChip))) {
      expect(check.selected, false);
    }
    expect(tester.takeException(), isNull);
  });
}
