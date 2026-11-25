import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pyvis_editor/comfy_blueprint_panel.dart';
import 'package:pyvis_editor/pyvis_theme.dart';
import 'package:pyvis_editor/windows_title_bar.dart';

import 'basic_workflows_test.dart' show openFixture, realIo, waitForRealIo;

const _channel = MethodChannel('pyvis/window');

void main() {
  testWidgets('Windows menu expands in place and dispatches existing actions',
      (tester) async {
    final messages = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      messages.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));

    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      theme: pyvisTheme(),
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
    final collapsedInsets = messages.last.arguments as List<Object?>;
    await tester.tap(find.byTooltip('展开主菜单'));
    await tester.pumpAndSettle();
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('打开项目…'), findsOneWidget);
    expect(messages.last.method, 'titleBarInsets');
    expect(messages.last.arguments, [168, 0]);

    for (final label in ['文件', '编辑']) {
      final text = find.text(label);
      final button =
          find.ancestor(of: text, matching: find.byType(TextButton)).first;
      final paragraph = tester.renderObject<RenderParagraph>(text);
      final style = tester.widget<TextButton>(button).style!;
      expect(tester.getSize(button), const Size(42, 28));
      expect(style.overlayColor!.resolve({WidgetState.hovered}),
          const Color(0x1affffff));
      expect((style.shape!.resolve({}) as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular(6));
      final bounds = paragraph
          .getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: label.length))
          .map((box) => box.toRect())
          .reduce((first, next) => first.expandToInclude(next));
      expect(paragraph.localToGlobal(bounds.center).dx,
          closeTo(tester.getCenter(button).dx, 0.5));
    }

    await tester.tap(find.text('打开项目…'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    await tester.tap(find.byTooltip('收起主菜单'));
    await tester.pumpAndSettle();
    expect(find.text('文件'), findsNothing);
    expect(find.text('Pyvis · 欢迎页'), findsOneWidget);
    expect(messages.last.arguments, collapsedInsets);

    await tester.binding.setSurfaceSize(const Size(430, 580));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpAndSettle();
    final messageCount = messages.length;
    await tester.tap(find.byTooltip('展开主菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开项目…'));
    await tester.pumpAndSettle();
    expect(opened, 2);
    expect(messages.length, messageCount);
  });

  testWidgets('Windows workspace shares the title bar with persistent actions',
      (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
    await openFixture(tester, {'main.py': "print('merged-toolbar-output')\n"});

    final bar = find.byType(WindowsTitleBar);
    final project = find.byTooltip('项目菜单');
    final run = find.byTooltip('直接运行').first;
    final close = find.byTooltip('关闭窗口');
    expect(project, findsOneWidget);
    expect(tester.getCenter(run).dy, tester.getCenter(close).dy);
    expect(tester.getCenter(project).dy, tester.getCenter(close).dy);
    expect(tester.getSize(bar).height, 36);

    await tester.tap(find.byTooltip('展开主菜单'));
    await tester.pumpAndSettle();
    expect(project, findsNothing);
    expect(find.text('文件'), findsOneWidget);
    expect(tester.getCenter(run).dy, tester.getCenter(close).dy);
    await tester.tap(find.byTooltip('收起主菜单'));
    await tester.pumpAndSettle();
    expect(project, findsOneWidget);
    expect(find.text('文件'), findsNothing);

    for (final width in [900.0, 760.0, 640.0, 430.0, 190.0]) {
      tester.view.physicalSize = Size(width, 600);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Window width $width');
      expect(tester.getSize(bar).height, 36);
    }

    tester.view.physicalSize = const Size(1400, 900);
    await tester.pumpAndSettle();
    await realIo(tester, () async => tester.tap(run));
    await waitForRealIo(tester, find.textContaining('merged-toolbar-output'));
    expect(find.byType(ComfyBlueprintPanel), findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));
}
