import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyvis_editor/comfy_blueprint_panel.dart';
import 'package:pyvis_editor/blueprint_service.dart';
import 'package:pyvis_editor/reading_flow_trace.dart';

Future<void> parsed(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  for (var i = 0; i < 100; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    final status = find.byKey(const ValueKey('graph-status'));
    if (status.evaluate().isNotEmpty &&
        tester.widget<Text>(status).data == '已同步') {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Python AST did not reply');
}

void main() {
  testWidgets('canvas error can be retried without changing the selected line',
      (tester) async {
    late ValueChanged<Map> event;
    late Map scene;
    const canvasKey = ValueKey('retry-fixture');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ComfyBlueprintPanel(
                source: 'items = [1, 2]\nprint(items)\n',
                filename: 'canvas.py',
                activeLine: 2,
                onLineSelected: (_) {},
                canvasBuilder: (_, data, callback) {
                  scene = data;
                  event = callback;
                  return const SizedBox(key: canvasKey);
                }))));
    await parsed(tester);
    await tester.tap(find.text('节点图'));
    await tester.pump();
    expect(scene['activeLine'], 2);
    event({'action': 'error', 'message': '绘制节点画布失败'});
    await tester.pump();
    expect(find.byKey(const ValueKey('graph-error')), findsOneWidget);
    expect(find.text('画布出错'), findsOneWidget);
    final oldCanvas = tester.element(find.byKey(canvasKey));
    await tester.tap(find.text('重试画布'));
    await tester.pump();
    expect(tester.element(find.byKey(canvasKey)), isNot(same(oldCanvas)));
    expect(scene['activeLine'], 2);
    event({'action': 'error', 'message': '绘制节点画布失败'});
    event({'action': 'rendered', 'nodes': 3});
    await tester.pump();
    expect(find.byKey(const ValueKey('graph-error')), findsNothing);
    expect(find.text('3 个节点'), findsOneWidget);
  });

  test(
      'routes identify a recursive function, exception handler and the matching case',
      () async {
    final parser = BlueprintService();
    addTearDown(parser.dispose);
    final graph = (await parser.parse('''def visit(n):
    if n:
        return visit(n - 1)
    return 0

try:
    visit(2)
except ValueError:
    print('invalid')
match mode:
    case 'on':
        run()
    case _:
        stop()
'''))['graph'] as Map;
    final items = (graph['reading'] as List).cast<Map>();
    ReadingRoute route(int line,
            {String? syntax, String? function, int? next}) =>
        ReadingRoute.project(
            items,
            ReadingTrace(
                recording: items,
                sequence: 1,
                line: line,
                syntax: syntax,
                function: function,
                nextLine: next));

    expect(route(1, function: 'visit').arms['1:0'], 0);
    expect(route(1, syntax: 'FunctionDef').arms, isEmpty);
    expect(route(3, syntax: 'Return').arms, {'1:0': 0, '2:4': 0});
    expect(route(9).arms['6:0'], 1);
    expect(route(14).arms['10:0'], 1);
  });

  testWidgets('reading starts with collapsed branches and opens a source line',
      (tester) async {
    Map? atomScene;
    int? selected;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ComfyBlueprintPanel(
                source:
                    'items = [3, 4]\nfor item in items:\n    if item > 3:\n        print(item)\n',
                filename: 'reading.py',
                activeLine: 1,
                onLineSelected: (line) => selected = line,
                canvasBuilder: (_, data, callback) {
                  atomScene = data;
                  return const SizedBox();
                }))));
    await parsed(tester);
    expect(find.text('代码概览'), findsOneWidget);
    expect(atomScene, isNull);
    expect(find.text('输出到控制台'), findsNothing);
    await tester.tap(find.text('每一轮执行'));
    await tester.pumpAndSettle();
    expect(selected, 3);
    await tester.tap(find.text('条件成立'));
    await tester.pumpAndSettle();
    expect(selected, 4);
    expect(find.text('输出到控制台'), findsOneWidget);
    await tester.tap(find.text('查看本行节点'));
    await tester.pumpAndSettle();
    expect(atomScene!['activeLine'], 4);
    expect(atomScene!['sections'], isEmpty);
    expect(atomScene!['compactNodes'], isTrue);
    await tester.tap(find.text('显示中间节点'));
    await tester.pumpAndSettle();
    expect(atomScene!['compactNodes'], isFalse);
    expect(atomScene!['activeLine'], 4);
    await tester.tap(find.text('返回代码概览'));
    await tester.pumpAndSettle();
    expect(find.text('输出到控制台'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Comfy canvas receives real sections, folds, branch paths and source navigation',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map? scene;
    late ValueChanged<Map> event;
    int? selected;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ComfyBlueprintPanel(
                source: 'a=2\nif a>0:\n    x=1\nelse:\n    x=2\nprint(x)\n',
                filename: 'test.py',
                activeLine: 1,
                onLineSelected: (line) => selected = line,
                canvasBuilder: (_, data, callback) {
                  scene = data;
                  event = callback;
                  return const SizedBox();
                }))));
    await parsed(tester);
    await tester.tap(find.text('节点图'));
    await tester.pump();
    expect(
        (scene!['folded'] as List).length, (scene!['sections'] as List).length);
    final summary = (scene!['sections'] as List)
        .firstWhere((s) => s['subflow_group'] != null);
    expect(summary['line'], 2);
    event({
      'action': 'enter',
      'id': summary['id'],
      'group': summary['subflow_group'],
      'line': 2
    });
    await tester.pump();
    expect(selected, 2);
    expect(find.byKey(const ValueKey('comfy-parent')), findsOneWidget);
    expect((scene!['section_links'] as List).where((e) => e['label'] == '成立'),
        isNotEmpty);
    expect((scene!['section_links'] as List).where((e) => e['label'] == '不成立'),
        isNotEmpty);
    final first = (scene!['sections'] as List).first;
    event({'action': 'expandAll'});
    await tester.pump();
    event({'action': 'fold', 'id': first['id']});
    await tester.pump();
    expect(scene!['folded'], contains(first['id']));
    event({'action': 'fold', 'id': first['id']});
    await tester.pump();
    expect(scene!['folded'], isNot(contains(first['id'])));
    await tester.tap(find.byKey(const ValueKey('comfy-parent')));
    await tester.pump();
    expect((scene!['sections'] as List).any((s) => s['subflow_group'] != null),
        isTrue);
    await tester.tap(find.text('逐行'));
    await tester.pump();
    expect(scene!['sections'], isEmpty);
    event({'action': 'select', 'id': 'unused', 'line': 3.0});
    expect(selected, 3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'live AST errors preserve display; node offsets survive parsing and mode changes',
      (tester) async {
    Map? scene;
    late ValueChanged<Map> event;
    late StateSetter update;
    var source = 'a=2\nb=a+1\n';
    final positions = <String, Offset>{};
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: StatefulBuilder(builder: (_, set) {
      update = set;
      return ComfyBlueprintPanel(
          source: source,
          filename: 'live.py',
          activeLine: 2,
          layoutPositions: positions,
          onLineSelected: (_) {},
          canvasBuilder: (_, data, callback) {
            scene = data;
            event = callback;
            return const SizedBox();
          });
    }))));
    await parsed(tester);
    await tester.tap(find.text('节点图'));
    await tester.pump();
    final read =
        (scene!['nodes'] as List).firstWhere((n) => n['kind'] == 'read');
    final key = read['layout_key'];
    event({
      'action': 'layout',
      'positions': {
        key: [91.0, -23.0]
      }
    });
    expect(positions['main|whole|$key'], const Offset(91, -23));
    final previous = scene;
    update(() => source = 'b=a+');
    await parsed(tester);
    expect(find.byKey(const ValueKey('graph-error')), findsOneWidget);
    expect(identical(scene, previous), isTrue);
    update(() => source = 'a=2\nb=a+3\n');
    await parsed(tester);
    expect(find.byKey(const ValueKey('graph-error')), findsNothing);
    expect((scene!['positions'] as Map)[key], [91.0, -23.0]);
    event({'action': 'collapseAll'});
    await tester.pump();
    expect(
        (scene!['folded'] as List).length, (scene!['sections'] as List).length);
    event({'action': 'expandAll'});
    await tester.pump();
    expect(scene!['folded'], isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'recursive calls enter the function scope without executing or infinitely expanding',
      (tester) async {
    Map? scene;
    late ValueChanged<Map> event;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ComfyBlueprintPanel(
                source:
                    'def f(n):\n    if n<=1:\n        return 1\n    return n*f(n-1)\nx=f(3)\n',
                filename: 'f.py',
                activeLine: 5,
                onLineSelected: (_) {},
                canvasBuilder: (_, data, callback) {
                  scene = data;
                  event = callback;
                  return const SizedBox();
                }))));
    await parsed(tester);
    await tester.tap(find.text('节点图'));
    await tester.pump();
    final call =
        (scene!['nodes'] as List).firstWhere((n) => n['kind'] == 'call');
    event({'action': 'call', 'id': call['id']});
    await tester.pump();
    expect('${scene!['key']}', contains('/f'));
    expect((scene!['nodes'] as List).length, lessThan(50));
    expect(
        (scene!['nodes'] as List).any((n) => n['kind'] == 'parameter'), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
