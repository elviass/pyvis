import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyvis_editor/main.dart';
import 'package:pyvis_editor/line_theater.dart';

void main() {
  setUpAll(() async {
    final icons = File(
        '${Platform.environment['HOME']}/.local/share/pyvis-flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      final loader = FontLoader('MaterialIcons');
      loader
          .addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
      await loader.load();
    }
    final font = File('/System/Library/Fonts/Supplemental/Arial Unicode.ttf');
    if (font.existsSync()) {
      final loader = FontLoader('monospace');
      loader
          .addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
      await loader.load();
      final codeFont = FontLoader('JetBrains Mono');
      codeFont
          .addFont(rootBundle.load('assets/fonts/JetBrainsMono-Regular.ttf'));
      await codeFont.load();
      final uiFont = FontLoader('.AppleSystemUIFont');
      uiFont
          .addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
      await uiFont.load();
    }
  });
  testWidgets('real Python run, shared object stage, replay and screenshot',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: key, child: const PyvisApp()));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('共享列表.py'), findsWidgets);
    await tester.runAsync(() async {
      await tester.tap(find.text('逐行运算.py').first);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('直接运行').first);
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pumpAndSettle();

    expect(find.byType(LineTheater), findsOneWidget);
    final theater = tester.widget<LineTheater>(find.byType(LineTheater));
    final target = theater.events.firstWhere((e) =>
        e['kind'] == 'statement' && e['code'] == 'total = price * count');
    tester.widget<Slider>(find.byType(Slider).first).onChanged!(theater.events
        .where((e) => e['kind'] == 'statement')
        .toList()
        .indexWhere((e) => e['seq'] == target['seq'])
        .toDouble());
    await tester.pump();
    await tester.tap(find.text('查看行内过程'));
    await tester.pump();
    await tester.tap(find.text('运算'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.tap(find.byTooltip('暂停本行演示').first);
    await tester.pumpAndSettle();
    expect(find.text('计算结果并赋给 total'), findsOneWidget);
    expect(find.text('×'), findsOneWidget);
    expect(find.textContaining('builtin_function_or_method'), findsNothing);
    expect(find.text('60'), findsWidgets);
    // Moving backwards restores recorded state without starting another run.

    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final folder = Directory('../docs');
      await folder.create(recursive: true);
      await File('../docs/desktop-preview.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('phone layout has a single flow workspace', (tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(const PyvisApp());
    });
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('代码流程图').first);
    await tester.pumpAndSettle();
    expect(find.text('代码概览'), findsOneWidget);
    expect(find.text('执行舞台'), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
