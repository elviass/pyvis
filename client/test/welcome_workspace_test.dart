import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pyvis_editor/main.dart';
import 'package:pyvis_editor/welcome_workspace.dart';

void main() {
  testWidgets('project menu shows choices before opening the creation dialog',
      (tester) async {
    await tester.pumpWidget(const PyvisApp());
    await tester.tap(find.byTooltip('项目菜单'));
    await tester.pumpAndSettle();
    expect(find.text('新建项目…'), findsOneWidget);
    expect(find.textContaining('最近项目'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);

    await tester.tap(find.text('新建项目…'));
    await tester.pumpAndSettle();
    expect(find.text('项目名称'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('toolbar returns to the welcome page on a phone', (tester) async {
    tester.view.physicalSize = const Size(412, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const PyvisApp());
    await tester.tap(find.byTooltip('返回欢迎页'));
    await tester.pumpAndSettle();
    expect(find.byType(WelcomeLaunch), findsOneWidget);
    await tester.tap(find.byTooltip('关闭欢迎页'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('返回欢迎页'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('welcome About opens, copies its details and closes',
      (tester) async {
    String? copied;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = call.arguments['text'] as String;
      }
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(const PyvisApp(startOnWelcome: true));
    await tester.tap(find.text('关于 Pyvis'));
    await tester.pumpAndSettle();
    // Allow the interpreter probe to finish even on hosts without Python.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制信息'));
    await tester.pump();
    expect(find.text('Pyvis v0.1.0'), findsOneWidget);
    expect(copied, startsWith('Pyvis v0.1.0\n'));
    expect(copied, contains('构建号'));
    expect(copied, contains('Dart'));
    expect(find.text('已复制'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('AI entry points show a development notice by default',
      (tester) async {
    await tester.pumpWidget(const PyvisApp(startOnWelcome: true));
    await tester.pumpAndSettle();
    for (final button in [find.text('学习提问'), find.byTooltip('学习提问')]) {
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('开发中'), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-editor-tab')), findsNothing);
      expect(find.byType(WelcomeLaunch), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
  testWidgets('learning questions open as a tab beside the welcome page',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester
        .pumpWidget(const PyvisApp(aiEnabled: true, startOnWelcome: true));
    await tester.pumpAndSettle();
    expect(find.byType(WelcomeProjects), findsOneWidget);
    expect(find.byType(WelcomeLaunch), findsOneWidget);
    const chatTab = ValueKey('chat-editor-tab');
    const welcomeTab = ValueKey('welcome-editor-tab');
    expect(find.byKey(chatTab), findsOneWidget);
    expect(find.byKey(welcomeTab), findsOneWidget);

    await tester.tap(find.byKey(chatTab));
    await tester.pumpAndSettle();
    expect(find.byType(WelcomeLaunch), findsNothing);
    final field = find.widgetWithText(TextField, '输入您的任务，使用 @ 添加文件或使用 / 输入命令');
    expect(field, findsOneWidget);
    await tester.enterText(field, '循环为什么结束？');
    await tester.tap(find.widgetWithText(TextButton, '新建聊天'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    await tester.tap(find.text('聊天历史记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('循环为什么结束？').last);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, '循环为什么结束？');

    await tester.tap(find.byKey(welcomeTab));
    await tester.pumpAndSettle();
    expect(find.byType(WelcomeLaunch), findsOneWidget);
    await tester.tap(find.byKey(chatTab));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回侧栏'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('收起学习提问'), findsOneWidget);
    expect(find.byType(WelcomeLaunch), findsOneWidget);

    tester.view.physicalSize = const Size(740, 540);
    await tester.pumpAndSettle();
    if (find.byType(WelcomeLaunch).evaluate().isEmpty) {
      await tester.tap(find.byTooltip('收起学习提问'));
      await tester.pumpAndSettle();
    }
    expect(find.byType(WelcomeLaunch), findsOneWidget);
    await tester.tap(find.byTooltip('学习提问'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, '循环为什么结束？');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });
}
