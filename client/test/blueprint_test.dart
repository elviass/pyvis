import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyvis_editor/blueprint_view.dart';
import 'package:pyvis_editor/comfy_blueprint_panel.dart';
import 'package:pyvis_editor/main.dart';
import 'package:re_editor/re_editor.dart';

Future<void> parsed(WidgetTester tester, {bool expandWhole = true}) async {
  await tester.pump(const Duration(milliseconds: 400));
  var ready = false;
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    final status = find.byKey(const ValueKey('graph-status'));
    if (status.evaluate().isNotEmpty &&
        !tester.widget<Text>(status).data!.startsWith('更新中')) {
      ready = true;
      break;
    }
  }
  expect(ready, isTrue, reason: 'Python AST parser did not reply');
  await tester.pumpAndSettle();
  if (expandWhole &&
      find.byKey(const ValueKey('full-flow-toggle')).evaluate().isNotEmpty) {
    final chip = tester
        .widget<FilterChip>(find.byKey(const ValueKey('full-flow-toggle')));
    if (!chip.selected) {
      await tester.tap(find.byKey(const ValueKey('full-flow-toggle')));
      await tester.pumpAndSettle();
    }
  }
  if (expandWhole &&
      find.byKey(const ValueKey('expand-all-sections')).evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const ValueKey('expand-all-sections')));
    await tester.pumpAndSettle();
  }
}

void main() {
  setUpAll(() async {
    await Directory('build/test-artifacts/graph-review')
        .create(recursive: true);
    final font = File('/System/Library/Fonts/Supplemental/Arial Unicode.ttf');
    if (font.existsSync()) {
      for (final family in ['.AppleSystemUIFont', 'Roboto', 'monospace']) {
        final loader = FontLoader(family);
        loader.addFont(
            Future.value(ByteData.sublistView(font.readAsBytesSync())));
        await loader.load();
      }
    }
    final mono = FontLoader('JetBrains Mono');
    mono.addFont(rootBundle.load('assets/fonts/JetBrainsMono-Regular.ttf'));
    await mono.load();
    final icons = File(
        '${Platform.environment['HOME']}/.local/share/pyvis-flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      final loader = FontLoader('MaterialIcons');
      loader
          .addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
      await loader.load();
    }
  });
  testWidgets(
      'typing updates real AST graph; partial syntax preserves last graph and recovers',
      (tester) async {
    var source = 'c = a + b * 2\n';
    late StateSetter update;
    int? line;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(body: StatefulBuilder(builder: (context, set) {
          update = set;
          return BlueprintPanel(
              source: source,
              filename: 'lesson.py',
              onLineSelected: (value) => line = value);
        }))));
    await parsed(tester);
    expect(find.text('×'), findsOneWidget);
    expect(find.text('+'), findsOneWidget);
    expect(find.text('c'), findsOneWidget);
    expect(find.byKey(const ValueKey('blueprint-canvas')), findsOneWidget);
    await tester.tap(find.text('a'));
    await tester.pump();
    expect(line, 1);
    update(() => source = 'c = a +');
    await tester.pump();
    await parsed(tester);
    expect(find.byKey(const ValueKey('graph-error')), findsOneWidget);
    expect(find.text('c'), findsOneWidget);
    update(() => source = 'c = a - 3\n');
    await tester.pump();
    await parsed(tester);
    expect(find.byKey(const ValueKey('graph-error')), findsNothing);
    expect(find.text('−'), findsOneWidget);
    expect(find.text('×'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'function bodies can be opened from a call; recursive graph stays finite',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
            body: BlueprintPanel(
                source:
                    'def fact(n):\n    if n<=1:\n        return 1\n    return n*fact(n-1)\nx=fact(3)\n',
                filename: 'recursive.py',
                onLineSelected: (_) {}))));
    await parsed(tester);
    await tester.tap(find.text('整段'));
    await tester.pump();
    if (!tester
        .widget<FilterChip>(find.byKey(const ValueKey('full-flow-toggle')))
        .selected) {
      await tester.tap(find.byKey(const ValueKey('full-flow-toggle')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const ValueKey('expand-all-sections')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('查看全图'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('调用').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('展开函数内部'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('expand-all-sections')));
    await tester.pumpAndSettle();
    expect(find.text('接收参数'), findsOneWidget);
    expect(find.text('n'), findsWidgets);
    expect(find.text('×'), findsOneWidget);
    expect(find.text('−'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'node drag follows zoom, updates wires and line label, preserves edits, and resets',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var source = 'a=10\nb=12\nc=a+b\n';
    final previewKey = GlobalKey();
    late StateSetter update;
    int? line;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(body: StatefulBuilder(builder: (context, set) {
          update = set;
          return RepaintBoundary(
              key: previewKey,
              child: BlueprintPanel(
                  source: source,
                  filename: 'drag.py',
                  onLineSelected: (value) => line = value));
        }))));
    await parsed(tester);
    await tester.runAsync(() async {
      final boundary = previewKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('build/test-artifacts/graph-review/03-compact-sample.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
    await tester.tap(find.byTooltip('缩小流程图'));
    await tester.pump();
    final view = tester.widget<InteractiveViewer>(
        find.byKey(const ValueKey('blueprint-canvas')));
    final scale = view.transformationController!.value[0].abs();
    final initialPainter = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('graph-wires')))
        .painter! as BlueprintWires;
    final id = initialPainter.nodes
        .firstWhere((n) => n['kind'] == 'symbol' && n['title'] == 'a')['id'];
    final node = find.byKey(ValueKey('graph-node-$id'));
    final before = tester.getTopLeft(node);
    final painterBefore = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('graph-wires')))
        .painter! as BlueprintWires;
    final outputBefore =
        graphOutput(painterBefore.nodes.firstWhere((n) => n['id'] == id));
    await tester.drag(node, const Offset(80, 40));
    await tester.pump();
    final after = tester.getTopLeft(node);
    expect(after.dx - before.dx, closeTo(80, 2));
    expect(after.dy - before.dy, closeTo(40, 2));
    expect(line, 1);
    expect(find.byKey(ValueKey('node-line-$id')), findsOneWidget);
    expect(
        tester.widget<Text>(find.byKey(ValueKey('node-line-$id'))).data, 'L1');
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('selected-graph-line')))
            .data,
        '第 1 行');
    final painterAfter = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('graph-wires')))
        .painter! as BlueprintWires;
    final moved = painterAfter.nodes.firstWhere((n) => n['id'] == id);
    expect(graphOutput(moved).dx - outputBefore.dx, closeTo(80 / scale, 2));
    final savedX = moved['x'];
    update(() => source += 'd=3\n');
    await tester.pump();
    await parsed(tester);
    final painterEdited = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('graph-wires')))
        .painter! as BlueprintWires;
    expect(
        painterEdited.nodes
            .firstWhere((n) => n['kind'] == 'symbol' && n['title'] == 'a')['x'],
        savedX);
    await tester.tap(find.byTooltip('重新自动排布'));
    await tester.pumpAndSettle();
    final painterReset = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('graph-wires')))
        .painter! as BlueprintWires;
    expect(
        painterReset.nodes
            .firstWhere((n) => n['kind'] == 'symbol' && n['title'] == 'a')['x'],
        isNot(savedX));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('variables values operators and assignments move independently',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    int? sourceLine;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
            body: BlueprintPanel(
                source: 'a=1\nb=1\nc=a+b\n',
                filename: 'atomic.py',
                onLineSelected: (line) => sourceLine = line))));
    await parsed(tester);
    BlueprintWires painter() => tester
        .widget<CustomPaint>(find.byKey(const ValueKey('graph-wires')))
        .painter! as BlueprintWires;
    for (final kind in ['symbol', 'value', 'operator', 'write']) {
      final before = painter();
      final target = before.nodes.firstWhere((n) => n['kind'] == kind);
      final oldPositions = {
        for (final n in before.nodes) n['id']: graphNodeRect(n).topLeft
      };
      final node = find.byKey(ValueKey('graph-node-${target['id']}'));
      final screenBefore = tester.getTopLeft(node);
      await tester.drag(node, const Offset(45, 25));
      await tester.pump();
      expect(tester.getTopLeft(node).dx - screenBefore.dx, closeTo(45, 2));
      expect(sourceLine, target['line']);
      for (final n in painter().nodes.where((n) => n['id'] != target['id'])) {
        expect(graphNodeRect(n).topLeft, oldPositions[n['id']]);
      }
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'readable line view follows editor while context selection does not jump away',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var line = 3;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(body: StatefulBuilder(builder: (_, set) {
          update = set;
          return BlueprintPanel(
              source: 'a=10\nb=12\nc=a+b\n',
              filename: 'readable.py',
              activeLine: line,
              onLineSelected: (value) => update(() => line = value));
        }))));
    await parsed(tester);
    expect(
        tester
            .widget<DropdownButton<int>>(
                find.byKey(const ValueKey('graph-line-picker')))
            .value,
        3);
    expect(find.text('a 的值'), findsOneWidget);
    expect(tester.widget<Text>(find.text('a 的值')).style!.fontSize,
        greaterThanOrEqualTo(16));
    final viewer = tester.widget<InteractiveViewer>(
        find.byKey(const ValueKey('blueprint-canvas')));
    expect(viewer.transformationController!.value[0], 1);
    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();
    expect(line, 1);
    expect(
        tester
            .widget<DropdownButton<int>>(
                find.byKey(const ValueKey('graph-line-picker')))
            .value,
        3);
    update(() => line = 2);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<DropdownButton<int>>(
                find.byKey(const ValueKey('graph-line-picker')))
            .value,
        2);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('a 的值'), findsNothing);
    update(() => line = 3);
    await tester.pumpAndSettle();
    expect(find.text('a 的值'), findsOneWidget);
    await tester.tap(find.text('整段'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('graph-line-picker')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('expand-all-sections')));
    await tester.pumpAndSettle();
    expect(find.text('10'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'source cursor inside a function shows that line without a scope search',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
            body: BlueprintPanel(
                source:
                    'def add(n):\n    value=n+1\n    return value\nx=add(2)\n',
                filename: 'function-line.py',
                activeLine: 2,
                onLineSelected: (_) {}))));
    await parsed(tester);
    expect(
        tester
            .widget<DropdownButton<int>>(
                find.byKey(const ValueKey('graph-line-picker')))
            .value,
        2);
    expect(find.text('+'), findsOneWidget);
    expect(find.text('n 的值'), findsOneWidget);
    expect(find.text('x'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'workspace exposes a separate graph screen without executing code',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late ValueChanged<Map> canvasEvent;
    Map? canvasScene;
    await tester
        .pumpWidget(PyvisApp(graphCanvasBuilder: (context, data, event) {
      canvasEvent = event;
      canvasScene = data;
      return const SizedBox(key: ValueKey('test-comfy-canvas'));
    }));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('代码流程图').first);
    await tester.pump();
    await parsed(tester);
    expect(find.byType(ComfyBlueprintPanel), findsOneWidget);
    expect(find.text('代码概览'), findsOneWidget);
    await tester.tap(find.text('节点图'));
    await tester.pumpAndSettle();
    expect(canvasScene!['nodes'], isNotEmpty);
    expect(find.text('程序走到哪里'), findsNothing);
    expect(find.text('已同步'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    await tester.tap(find.text('逐行'));
    await tester.pumpAndSettle();
    tester
        .widget<DropdownButton<int>>(
            find.byKey(const ValueKey('graph-line-picker')))
        .onChanged!(3);
    await tester.pumpAndSettle();
    final count = (canvasScene!['nodes'] as List)
        .firstWhere((n) => n['kind'] == 'read' && n['symbol'] == 'count');
    expect(count['line'], 3);
    canvasEvent({'action': 'source', 'line': 2});
    await tester.pump();
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    expect(editor.controller!.selection.extent.index, 1);
    expect(
        tester
            .widget<DefaultCodeLineNumber>(find.byType(DefaultCodeLineNumber))
            .customLineIndex2Text!(1),
        '▶ 2');
    expect(
        tester
            .widget<DefaultCodeLineNumber>(find.byType(DefaultCodeLineNumber))
            .customLineIndex2Text!(0),
        '1');

    await tester.tap(find.text('编辑代码'));
    await tester.pumpAndSettle();
    expect(find.byType(ComfyBlueprintPanel), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'whole graph has regions, local references, obstacle routes and independent dragging',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preview = GlobalKey();
    int? sourceLine;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
            body: RepaintBoundary(
                key: preview,
                child: BlueprintPanel(
                    source: File('../examples/逐行运算.py').readAsStringSync(),
                    filename: 'regions.py',
                    initialLineMode: false,
                    onLineSelected: (line) => sourceLine = line)))));
    await parsed(tester);
    BlueprintWires painter() => tester
        .widget<CustomPaint>(find.byKey(const ValueKey('graph-wires')))
        .painter! as BlueprintWires;
    expect(find.text('设置变量 · L1'), findsOneWidget);
    expect(find.text('判断 total >= 50 · L4'), findsOneWidget);
    expect(find.byKey(const ValueKey('blocked-wires')), findsNothing);
    final reference = painter()
        .nodes
        .firstWhere((n) => n['kind'] == 'reference' && n['symbol'] == 'total');
    final original =
        painter().nodes.firstWhere((n) => n['id'] == reference['origin_id']);
    expect(reference['section_id'], isNot(original['section_id']));
    expect(
        painter().routes.where((r) => r.edge['kind'] == 'reference'), isEmpty);
    await tester.tap(find.byTooltip('查看全图'));
    await tester.pumpAndSettle();
    Future<void> capture(String file) async {
      await tester.runAsync(() async {
        final boundary = preview.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('build/test-artifacts/graph-review/$file')
            .writeAsBytes(bytes!.buffer.asUint8List());
      });
    }

    await capture('04-whole-sections.png');
    await tester.tap(find.byKey(ValueKey('graph-node-${reference['id']}')));
    await tester.pumpAndSettle();
    expect(sourceLine, reference['line']);
    expect(painter().routes.any((r) => r.edge['kind'] == 'reference'), isTrue);
    await tester.tap(find.text('定位来源 · 第 3 行'));
    await tester.pumpAndSettle();
    expect(sourceLine, 3);
    final oldPositions = {
      for (final n in painter().nodes) n['id']: graphNodeRect(n).topLeft
    };
    final target = find.byKey(ValueKey('graph-node-${original['id']}'));
    final before = tester.getTopLeft(target);
    await tester.drag(target, const Offset(50, 30));
    await tester.pump();
    expect(tester.getTopLeft(target).dx - before.dx, closeTo(50, 2));
    for (final n in painter().nodes.where((n) => n['id'] != original['id'])) {
      expect(graphNodeRect(n).topLeft, oldPositions[n['id']]);
    }
    expect(sourceLine, 3);
    await tester.tap(find.byTooltip('重新自动排布'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('判断 total >= 50 · L4'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('缩小流程图'));
    await tester.pumpAndSettle();
    await capture('05-branch-detail.png');
    expect(find.byKey(const ValueKey('blocked-wires')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'flow places alternatives side by side and folds content without losing dragged positions',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preview = GlobalKey();
    int? sourceLine;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
            body: RepaintBoundary(
                key: preview,
                child: BlueprintPanel(
                    source:
                        'x=1\nif x>0:\n    y=x+2\nelse:\n    y=x-2\nprint(y)\n',
                    filename: 'folded-flow.py',
                    initialLineMode: false,
                    onLineSelected: (line) => sourceLine = line)))));
    await parsed(tester);
    BlueprintWires painter() => tester
        .widget<CustomPaint>(find.byKey(const ValueKey('graph-wires')))
        .painter! as BlueprintWires;
    Map node(int line, String kind) => painter()
        .nodes
        .firstWhere((n) => n['line'] == line && n['kind'] == kind);
    final yes = node(3, 'write'),
        no = node(5, 'write'),
        output = node(6, 'call');
    expect((yes['x'] as num) + graphNodeWidth(yes), lessThan(no['x'] as num));
    expect((yes['y'] as num).toDouble(),
        closeTo((no['y'] as num).toDouble(), .001));
    expect(output['y'] as num, greaterThan(yes['y'] as num));
    final sectionRoutes =
        painter().routes.where((r) => r.edge['kind'] == 'section');
    expect(sectionRoutes.where((r) => r.edge['label'] == '成立'), hasLength(1));
    expect(sectionRoutes.where((r) => r.edge['label'] == '不成立'), hasLength(1));
    expect(sectionRoutes.every((r) => !r.blocked), isTrue);
    final count = painter().nodes.length;
    await tester.tap(find.byKey(ValueKey('section-jump-${yes['section_id']}')));
    await tester.pumpAndSettle();
    final target = find.byKey(ValueKey('graph-node-${yes['id']}'));
    final before = graphNodeRect(node(3, 'write')).topLeft;
    await tester.drag(target, const Offset(60, 24));
    await tester.pumpAndSettle();
    final moved = graphNodeRect(node(3, 'write')).topLeft;
    expect(moved.dx, greaterThan(before.dx));
    expect(sourceLine, 3);
    final fold = find.byKey(ValueKey('section-fold-${yes['section_id']}'));
    await tester.tap(fold);
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('graph-node-${yes['id']}')), findsNothing);
    expect(
        painter().routes.any((r) =>
            r.edge['kind'] == 'section' && r.edge['to'] == yes['section_id']),
        isTrue);
    await tester
        .tap(find.byKey(ValueKey('section-header-${yes['section_id']}')));
    await tester.pumpAndSettle();
    expect(graphNodeRect(node(3, 'write')).topLeft, moved);
    expect(painter().nodes.length, count);
    await tester.tap(find.byKey(const ValueKey('fold-all-sections')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('查看全图'));
    await tester.pumpAndSettle();
    expect(painter().nodes, isEmpty);
    expect(find.byKey(const ValueKey('blueprint-canvas')), findsOneWidget);
    expect(painter().routes.where((r) => r.edge['kind'] == 'section'),
        hasLength(6));
    expect(painter().routes.every((r) => !r.blocked), isTrue);
    await tester.runAsync(() async {
      final image = await (preview.currentContext!.findRenderObject()!
              as RenderRepaintBoundary)
          .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('build/test-artifacts/graph-review/11-flow-folded.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
    await tester.tap(find.byKey(const ValueKey('expand-all-sections')));
    await tester.pumpAndSettle();
    expect(painter().nodes.length, count);
    expect(graphNodeRect(node(3, 'write')).topLeft, moved);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('folded loop retains its return path and exit path',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preview = GlobalKey();
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
            body: RepaintBoundary(
                key: preview,
                child: BlueprintPanel(
                    source: 'i=0\nwhile i<3:\n    i+=1\nprint(i)\n',
                    filename: 'loop-flow.py',
                    initialLineMode: false,
                    onLineSelected: (_) {})))));
    await parsed(tester);
    BlueprintWires painter() => tester
        .widget<CustomPaint>(find.byKey(const ValueKey('graph-wires')))
        .painter! as BlueprintWires;
    await tester.tap(find.byKey(const ValueKey('fold-all-sections')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('查看全图'));
    await tester.pumpAndSettle();
    final back = painter().routes.singleWhere((r) => r.edge['label'] == '下一轮');
    expect(back.edge['back'], isTrue);
    expect(back.blocked, isFalse);
    expect(back.points.first.dy, greaterThan(back.points.last.dy));
    final exit = painter().routes.singleWhere((r) => r.edge['label'] == '结束');
    expect(exit.edge['back'], isFalse);
    expect(exit.blocked, isFalse);
    expect(exit.points.last.dy, greaterThan(exit.points.first.dy));
    await tester.runAsync(() async {
      final image = await (preview.currentContext!.findRenderObject()!
              as RenderRepaintBoundary)
          .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('build/test-artifacts/graph-review/12-loop-folded.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'actual menu expands try, navigates deep loops and culls offscreen nodes',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preview = GlobalKey();
    int? sourceLine;
    final code = File('../tests/fixtures/menu_decimal.py').readAsStringSync();
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
            body: RepaintBoundary(
                key: preview,
                child: BlueprintPanel(
                    source: code,
                    filename: '1.py',
                    initialLineMode: false,
                    activeLine: 7,
                    onLineSelected: (line) => sourceLine = line)))));
    await parsed(tester);
    BlueprintWires painter() => tester
        .widget<CustomPaint>(find.byKey(const ValueKey('graph-wires')))
        .painter! as BlueprintWires;
    expect(painter().nodes.length, greaterThan(900));
    expect(find.textContaining('尚未细分'), findsNothing);
    expect(find.byKey(const ValueKey('graph-section-picker')), findsOneWidget);
    int renderedNodes() => find
        .byWidgetPredicate((widget) =>
            widget.key is ValueKey<String> &&
            (widget.key as ValueKey<String>).value.startsWith('graph-node-'))
        .evaluate()
        .length;
    expect(renderedNodes(), lessThan(120));
    expect(renderedNodes(), greaterThan(2));
    var nav = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('graph-section-picker')));
    expect(nav.items!.length, greaterThan(50));
    final loop = nav.items!.firstWhere((item) =>
        ((item.child as Text).data ?? '').contains('while number <= 50'));
    nav.onChanged!(loop.value);
    await tester.pumpAndSettle();
    expect(sourceLine, 106);
    expect(find.text('≤'), findsOneWidget);
    expect(renderedNodes(), lessThan(120));
    expect(find.byKey(const ValueKey('blocked-wires')), findsNothing);
    final operator = painter()
        .nodes
        .firstWhere((n) => n['line'] == 106 && n['kind'] == 'operator');
    final oldPositions = {
      for (final n in painter().nodes) n['id']: graphNodeRect(n).topLeft
    };
    final target = find.byKey(ValueKey('graph-node-${operator['id']}'));
    final before = tester.getTopLeft(target);
    await tester.drag(target, const Offset(0, 25),
        kind: ui.PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(target).dy - before.dy, closeTo(25, 2));
    for (final n in painter().nodes.where((n) => n['id'] != operator['id'])) {
      expect(graphNodeRect(n).topLeft, oldPositions[n['id']]);
    }
    expect(sourceLine, 106);
    await tester.runAsync(() async {
      final boundary =
          preview.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('build/test-artifacts/graph-review/06-menu-loop.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
    await tester.tap(find.byTooltip('下一个分区'));
    await tester.pumpAndSettle();
    expect(sourceLine, 107);
    expect(renderedNodes(), lessThan(120));
    await tester.tap(find.byTooltip('分区总览'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('graph-section-search')), 'L114');
    await tester.pumpAndSettle();
    // Match the actual source caption; region counts can change as syntax improves.
    final tile = find
        .byType(ListTile)
        .evaluate()
        .map((e) => e.widget as ListTile)
        .firstWhere((t) =>
            ((t.title as Text).data ?? '').contains('while number <= 5'));
    await tester.tap(find.byWidget(tile));
    await tester.pumpAndSettle();
    expect(sourceLine, 114);
    expect(find.byKey(const ValueKey('graph-section-search')), findsNothing);
    expect(renderedNodes(), lessThan(120));
    final foldedAt = Stopwatch()..start();
    await tester.tap(find.byKey(const ValueKey('fold-all-sections')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('查看全图'));
    await tester.pumpAndSettle();
    expect(painter().nodes, isEmpty);
    expect(painter().routes.where((r) => r.blocked), isEmpty);
    expect(foldedAt.elapsed, lessThan(const Duration(seconds: 10)));
    nav = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('graph-section-picker')));
    nav.onChanged!(loop.value);
    await tester.pumpAndSettle();
    expect(painter().nodes, isEmpty);
    await tester.tap(find.byKey(ValueKey('section-header-${loop.value}')));
    await tester.pumpAndSettle();
    expect(
        painter()
            .nodes
            .any((n) => n['line'] == 106 && n['kind'] == 'condition'),
        isTrue);
    expect(renderedNodes(), lessThan(120));
    expect(sourceLine, 106);
    await tester.tap(find.text('逐行'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('graph-line-picker')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  test('data tracing does not sweep in other ancestors of downstream consumers',
      () {
    expect(
        graphConnections('b', [
          {'from': 'a', 'to': 'b', 'kind': 'data'},
          {'from': 'x', 'to': 'b', 'kind': 'reference'},
          {'from': 'b', 'to': 'c', 'kind': 'binding'},
          {'from': 'b', 'to': 'd', 'kind': 'data'},
          {'from': 'e', 'to': 'd', 'kind': 'data'}
        ]),
        {'a', 'x', 'b', 'c', 'd'});
  });

  testWidgets(
      'real menu opens folded at readable scale and reserves the canvas for the graph',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preview = GlobalKey();
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
            body: RepaintBoundary(
                key: preview,
                child: BlueprintPanel(
                    source: File('../tests/fixtures/menu_decimal.py')
                        .readAsStringSync(),
                    filename: 'readable-menu.py',
                    activeLine: 106,
                    initialLineMode: false,
                    onLineSelected: (_) {})))));
    await parsed(tester, expandWhole: false);
    BlueprintWires painter() => tester
        .widget<CustomPaint>(find.byKey(const ValueKey('graph-wires')))
        .painter! as BlueprintWires;
    double scale() => tester
        .widget<InteractiveViewer>(
            find.byKey(const ValueKey('blueprint-canvas')))
        .transformationController!
        .value[0];
    expect(painter().nodes, isEmpty);
    expect(scale(), 1);
    expect(find.byKey(const ValueKey('blueprint-teaching')), findsNothing);
    expect(
        tester.getSize(find.byKey(const ValueKey('blueprint-canvas'))).height,
        greaterThan(550));
    final nav = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('graph-section-picker')));
    final header = find.byKey(ValueKey('section-header-${nav.value}'));
    expect(tester.getRect(header).left, greaterThanOrEqualTo(0));
    expect(tester.getRect(header).right, lessThanOrEqualTo(1000));
    await tester.runAsync(() async {
      final image = await (preview.currentContext!.findRenderObject()!
              as RenderRepaintBoundary)
          .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('build/test-artifacts/graph-review/13-readable-default.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(painter().nodes, isNotEmpty);
    expect(scale(), greaterThanOrEqualTo(.85));
    expect(
        tester.getSize(find.byKey(const ValueKey('blueprint-teaching'))).height,
        96);
    await tester.tap(find.byKey(const ValueKey('teaching-details')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('teaching-explanation')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('teaching-details')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('缩小流程图'));
    await tester.tap(find.byTooltip('缩小流程图'));
    await tester.pumpAndSettle();
    expect(scale(), lessThan(.85));
    await tester.tap(find.byKey(const ValueKey('readable-zoom')));
    await tester.pumpAndSettle();
    expect(scale(), greaterThanOrEqualTo(.85));
    expect(find.byKey(const ValueKey('blocked-wires')), findsNothing);
    await tester.tap(find.byTooltip('分区总览'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('graph-section-search')), 'L114');
    await tester.pumpAndSettle();
    final choice = find
        .byType(ListTile)
        .evaluate()
        .map((e) => e.widget as ListTile)
        .firstWhere((t) =>
            ((t.title as Text).data ?? '').contains('while number <= 5'));
    await tester.tap(find.byWidget(choice));
    await tester.pumpAndSettle();
    final selected = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('graph-section-picker')));
    expect(
        (selected.selectedItemBuilder == null
                ? selected.items!
                    .firstWhere((i) => i.value == selected.value)
                    .child as Text
                : null)
            ?.data,
        contains('L114'));
    expect(painter().nodes, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'nested control flow can be entered and left without showing unrelated paths',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preview = GlobalKey();
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
            body: RepaintBoundary(
                key: preview,
                child: BlueprintPanel(
                    source:
                        'x=0\nwhile x<3:\n    if x%2==0:\n        print(x)\n    else:\n        print(-x)\n    x+=1\nprint("结束")\n',
                    filename: 'nested-readable.py',
                    initialLineMode: false,
                    activeLine: 1,
                    onLineSelected: (_) {})))));
    await parsed(tester, expandWhole: false);
    BlueprintWires painter() => tester
        .widget<CustomPaint>(find.byKey(const ValueKey('graph-wires')))
        .painter! as BlueprintWires;
    expect(find.byTooltip('进入子流程'), findsOneWidget);
    await tester.tap(find.byTooltip('进入子流程'));
    await tester.pumpAndSettle();
    expect(painter().routes.any((r) => r.edge['label'] == '下一轮'), isTrue);
    expect(find.byTooltip('进入子流程'), findsOneWidget);
    await tester.tap(find.byTooltip('进入子流程'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('进入子流程'), findsNothing);
    expect(painter().routes.where((r) => r.edge['kind'] == 'section'),
        hasLength(4));
    expect(painter().routes.every((r) => !r.blocked), isTrue);
    await tester.tap(find.byTooltip('查看全图'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final image = await (preview.currentContext!.findRenderObject()!
              as RenderRepaintBoundary)
          .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('build/test-artifacts/graph-review/14-layered-flow.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
    await tester.tap(find.byKey(const ValueKey('flow-parent')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('进入子流程'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flow-parent')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('进入子流程'), findsOneWidget);
    expect(
        tester
            .widget<FilterChip>(find.byKey(const ValueKey('full-flow-toggle')))
            .selected,
        isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'narrow desktop graph fits a loop decision and preserves full variable names',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preview = GlobalKey();
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
            body: RepaintBoundary(
                key: preview,
                child: BlueprintPanel(
                    source: File('../tests/fixtures/menu_decimal.py')
                        .readAsStringSync(),
                    filename: '1.py',
                    initialLineMode: false,
                    activeLine: 106,
                    onLineSelected: (_) {})))));
    await parsed(tester);
    final painter = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('graph-wires')))
        .painter! as BlueprintWires;
    final check = painter.nodes
        .firstWhere((n) => n['line'] == 106 && n['kind'] == 'condition');
    final rect =
        tester.getRect(find.byKey(ValueKey('graph-node-${check['id']}')));
    expect(rect.right, lessThanOrEqualTo(990));
    expect(rect.left, greaterThan(0));
    final ref = painter.nodes.firstWhere((n) =>
        n['line'] == 106 && n['kind'] == 'reference' && n['title'] == 'number');
    final title = find.descendant(
        of: find.byKey(ValueKey('graph-node-${ref['id']}')),
        matching: find.text('number'));
    final paragraph = tester.renderObject<RenderParagraph>(title);
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(tester.widget<Text>(title).maxLines, 1);
    expect(find.byKey(const ValueKey('blocked-wires')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          preview.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('build/test-artifacts/graph-review/08-menu-narrow.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'plain guide explains a loop as a sequence and follows real source steps',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preview = GlobalKey();
    int? sourceLine;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
            body: RepaintBoundary(
                key: preview,
                child: BlueprintPanel(
                    source: File('../tests/fixtures/menu_decimal.py')
                        .readAsStringSync(),
                    filename: '1.py',
                    initialLineMode: false,
                    activeLine: 106,
                    onLineSelected: (line) => sourceLine = line)))));
    await parsed(tester);
    expect(find.byKey(const ValueKey('blueprint-teaching')), findsOneWidget);
    expect(
        tester.widget<Text>(find.byKey(const ValueKey('teaching-title'))).data,
        contains('number 小于或等于 50'));
    expect(find.text('汇合'), findsNothing);
    expect(find.text('将 number 加到 total，更新 total'), findsOneWidget);
    expect(find.textContaining('条件不成立 → 退出循环'), findsOneWidget);
    await tester.runAsync(() async {
      final boundary =
          preview.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('build/test-artifacts/graph-review/10-precise-explanation.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
    await tester.tap(find.byKey(const ValueKey('teaching-step-1')));
    await tester.pumpAndSettle();
    expect(sourceLine, 107);
    expect(
        tester.widget<Text>(find.byKey(const ValueKey('teaching-title'))).data,
        '将 number 加到 total，更新 total');
    await tester.tap(find.byKey(const ValueKey('teaching-step-2')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('node-plain-explanation')), findsOneWidget);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('node-plain-explanation')))
            .data,
        contains('赋给 total'));
    await tester.tap(find.byTooltip('上一个分区'));
    await tester.pumpAndSettle();
    expect(sourceLine, 106);
    await tester.tap(find.byKey(const ValueKey('teaching-step-3')));
    await tester.pumpAndSettle();
    expect(sourceLine, 106);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'plain language can switch to original terms without changing nodes or code',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
            body: BlueprintPanel(
                source: 'a=1\nb=2\nc=a+b\n',
                filename: 'plain.py',
                onLineSelected: (_) {}))));
    await parsed(tester);
    BlueprintWires painter() => tester
        .widget<CustomPaint>(find.byKey(const ValueKey('graph-wires')))
        .painter! as BlueprintWires;
    final before = {for (final n in painter().nodes) n['id']: graphNodeRect(n)};
    expect(find.text('赋值'), findsWidgets);
    await tester.tap(find.text('步骤说明'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('blueprint-teaching')), findsNothing);
    expect(find.text('='), findsOneWidget);
    expect(
        {for (final n in painter().nodes) n['id']: graphNodeRect(n)}, before);
    await tester.tap(find.text('步骤说明'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('blueprint-teaching')), findsOneWidget);
    expect(find.text('赋值'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'input guide selects the actual cleanup call for each plain-language step',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
            body: BlueprintPanel(
                source: 'choice=input("选择").strip().lower()\n',
                filename: 'input.py',
                onLineSelected: (_) {}))));
    await parsed(tester);
    BlueprintWires painter() => tester
        .widget<CustomPaint>(find.byKey(const ValueKey('graph-wires')))
        .painter! as BlueprintWires;
    await tester.tap(find.byKey(const ValueKey('teaching-step-1')));
    await tester.pumpAndSettle();
    expect(
        painter()
            .nodes
            .firstWhere((n) => n['id'] == painter().selected)['function'],
        endsWith('.strip'));
    await tester.tap(find.byKey(const ValueKey('teaching-step-2')));
    await tester.pumpAndSettle();
    expect(
        painter()
            .nodes
            .firstWhere((n) => n['id'] == painter().selected)['function'],
        endsWith('.lower'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
