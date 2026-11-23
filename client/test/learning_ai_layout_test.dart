import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pyvis_editor/learning_ai.dart';
import 'package:pyvis_editor/learning_ai_view.dart';
import 'package:pyvis_editor/pyvis_theme.dart';
import 'package:pyvis_editor/editor_settings.dart';

void main() {
  for (final size in [const Size(1000, 700), const Size(1400, 900)]) {
    testWidgets('embedded API settings keep save visible at $size',
        (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AiConfigStore.channel, (_) async => null);
      await tester.pumpWidget(MaterialApp(
          theme: pyvisTheme(),
          home: EditorSettingsDialog(
              aiEnabled: true,
              preferences: EditorPreferences(),
              mac: true,
              initialPage: 4)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.text('保存模型配置')).bottom, lessThan(size.height));
      expect(find.text('关闭'), findsOneWidget);
      expect(find.text('确定'), findsNothing);
      await tester.tap(find.text('自定义模型 API'));
      await tester.pumpAndSettle();
      final protocol = find.byType(DropdownButtonFormField<AiProtocol>);
      await tester.ensureVisible(protocol);
      await tester.pumpAndSettle();
      expect(tester.getSize(protocol).width, lessThanOrEqualTo(340));
      await tester.tap(protocol);
      await tester.pumpAndSettle();
      final menu = find.byType(ListView);
      final popup = menu.evaluate().last;
      expect(tester.getSize(find.byWidget(popup.widget)).height,
          lessThanOrEqualTo(320));
      await tester.tap(find.text(AiProtocol.responses.label).last);
      await tester.pumpAndSettle();
      expect(find.text(AiProtocol.responses.label), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('ai-model')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
  for (final size in [
    const Size(420, 480),
    const Size(720, 640),
    const Size(1200, 850)
  ]) {
    testWidgets('AI dialogs fit $size with fixed actions and scrolling content',
        (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AiConfigStore.channel, (_) async => null);
      await tester.pumpWidget(
          MaterialApp(theme: pyvisTheme(), home: const AiSettingsDialog()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('CAPTURE_AI_LAYOUT')) {
        await expectLater(
            find.byType(AiSettingsDialog),
            matchesGoldenFile(
                '/tmp/pyvis-ai-settings-${size.width.toInt()}.png'));
      }
      final save = find.text('保存模型配置');
      expect(tester.getRect(save).bottom, lessThan(size.height));
      expect(tester.getRect(find.text('测试连接')).top, greaterThan(0));
      await tester.ensureVisible(find.byKey(const ValueKey('ai-model')));
      await tester.pumpAndSettle();
      expect(tester.getRect(save).bottom, lessThan(size.height));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(
          theme: pyvisTheme(),
          home: LearningAiPanel(
            available: {'选中的代码': 'x = 1', '当前错误': '示例错误', '当前演示步骤': '步骤一'},
            messages: [
              AiMessage(true, '为什么？'),
              AiMessage(false, List.filled(30, '这是一段用于检查滚动的说明。').join('\n'))
            ],
          )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('CAPTURE_AI_LAYOUT')) {
        await expectLater(find.byType(LearningAiPanel),
            matchesGoldenFile('/tmp/pyvis-ai-chat-${size.width.toInt()}.png'));
      }
      final sendRect = tester.getRect(find.byTooltip('发送'));
      expect(sendRect.bottom, lessThan(size.height));
      expect(sendRect.right, lessThan(size.width));
      expect(
          tester.getRect(find.byType(TextField)).bottom, lessThan(size.height));
      await tester.tap(find.text('选中的代码'));
      await tester.pumpAndSettle();
      expect(find.text('本次附带 1 项上下文'), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byTooltip('发送')), sendRect);
      expect(tester.takeException(), isNull);
    });
  }
}
