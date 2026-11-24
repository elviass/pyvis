import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pyvis_editor/windows_title_bar.dart';

void main() {
  testWidgets('Windows menu expands in place and dispatches existing actions',
      (tester) async {
    final messages = <MethodCall>[];
    const channel = MethodChannel('pyvis/window');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      messages.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          WindowsTitleBar(
            workspaceTitle: 'Pyvis · 欢迎页',
            menus: {
              '文件': [
                MenuItemButton(
                  onPressed: () => opened++,
                  child: const Text('打开项目…'),
                ),
              ],
              '编辑': [MenuItemButton(onPressed: () {}, child: const Text('查找'))],
            },
          ),
        ]),
      ),
    ));

    expect(find.text('文件'), findsNothing);
    await tester.tap(find.byTooltip('展开主菜单'));
    await tester.pumpAndSettle();
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('打开项目…'), findsOneWidget);
    expect(messages.last.arguments, isTrue);

    await tester.tap(find.text('打开项目…'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    await tester.tap(find.byTooltip('收起主菜单'));
    await tester.pumpAndSettle();
    expect(find.text('文件'), findsNothing);
    expect(find.text('Pyvis · 欢迎页'), findsOneWidget);
    expect(messages.last.arguments, isFalse);

    await tester.binding.setSurfaceSize(const Size(430, 580));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('展开主菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开项目…'));
    await tester.pumpAndSettle();
    expect(opened, 2);
    expect(messages.length, 2);
  });
}
