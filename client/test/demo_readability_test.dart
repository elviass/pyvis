import 'dart:convert';
import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyvis_editor/learning_scene.dart';
import 'package:pyvis_editor/line_process.dart';
import 'package:pyvis_editor/process_diagram.dart';
import 'package:pyvis_editor/runtime_value_view.dart';
import 'package:pyvis_editor/object_binding_view.dart';

void main() {
  testWidgets(
      'dictionary assignment draws one object with variable reference and actual fields',
      (tester) async {
    final heap = {
      'inventory': {
        'type': 'dict',
        'length': 4,
        'entries': [
          for (final name in ['笔记本', '钢笔', '书包', '水杯'])
            [
              {'type': 'str', 'value': name},
              {'type': 'dict', 'ref': name}
            ]
        ]
      },
      for (final name in ['笔记本', '钢笔', '书包', '水杯'])
        name: {
          'type': 'dict',
          'entries': [
            [
              {'type': 'str', 'value': 'price'},
              {'type': 'int', 'value': 20}
            ],
            [
              {'type': 'str', 'value': 'stock'},
              {'type': 'int', 'value': 12}
            ]
          ]
        }
    };
    final scene = LearningScene(
        title: '',
        kind: 'store',
        target: 'inventory',
        result: SceneValue(
            'inventory', {'type': 'dict', 'ref': 'inventory'}, heap));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: ObjectBindingView(scene: scene)))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recorded-object')), findsOneWidget);
    expect(find.text('inventory'), findsOneWidget);
    expect(find.text('引用'), findsOneWidget);
    expect(find.text('"笔记本"'), findsOneWidget);
    expect(find.text('"price": 20'), findsNWidgets(4));
    expect(tester.getSize(find.byKey(const ValueKey('recorded-object'))).height,
        lessThan(360));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'shared variable references retain a single object in narrow windows',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const scene = LearningScene(
        title: '',
        kind: 'alias',
        target: 'b',
        aliases: ['a', 'b'],
        result: SceneValue('共同引用的对象', {
          'type': 'list',
          'ref': '1'
        }, {
          '1': {
            'type': 'list',
            'items': [
              {'type': 'int', 'value': 7}
            ]
          }
        }));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: ObjectBindingView(scene: scene)))));
    await tester.pumpAndSettle();
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
    expect(find.byKey(const ValueKey('recorded-object')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('for distinguishes repeated equal values from exhausted iteration', () {
    final trace = jsonDecode(
        File('test/fixtures/iteration_trace.json').readAsStringSync());
    final events = (trace['events'] as List)
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final iterations = events
        .where((e) => e['kind'] == 'statement' && e['statement_type'] == 'For')
        .toList();
    for (final e in iterations.take(2)) {
      final scene = learningScene(e, events);
      expect(scene.inputs.single.label, 'item');
      expect(scene.inputs.single.text, '1');
      expect(scene.title, contains('取得下一个元素'));
      expect(scene.nextLine, 2);
    }
    final exhausted = learningScene(iterations.last, events);
    expect(exhausted.inputs, isEmpty);
    expect(exhausted.title, contains('结束本次 for 循环'));
    expect(exhausted.nextLine, 3);
  });

  testWidgets('nested containers stay bounded and expand into a recorded tree',
      (tester) async {
    final heap = {
      '1': {
        'type': 'dict',
        'length': 30,
        'entries': [
          for (var i = 0; i < 30; i++)
            [
              {'type': 'str', 'value': '商品$i'},
              {'type': 'dict', 'ref': '2'}
            ]
        ]
      },
      '2': {
        'type': 'dict',
        'entries': [
          [
            {'type': 'str', 'value': 'price'},
            {'type': 'int', 'value': 20}
          ],
          [
            {'type': 'str', 'value': 'stock'},
            {'type': 'int', 'value': 12}
          ]
        ]
      }
    };
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: 240,
                    child: RuntimeValueView(
                        value: SceneValue('inventory',
                            {'type': 'dict', 'ref': '1'}, heap)))))));
    expect(tester.getSize(find.byType(RuntimeValueView)).height, lessThan(240));
    expect(find.text('字典 · 30 项'), findsOneWidget);
    expect(find.textContaining('price'), findsNothing);
    await tester.tap(find.text('展开内容（30 项已记录）'));
    await tester.pumpAndSettle();
    expect(find.text('inventory'), findsOneWidget);
    await tester.tap(find
        .descendant(
            of: find.byType(AlertDialog), matching: find.text('字典 · 2 项'))
        .first);
    await tester.pumpAndSettle();
    expect(find.text('"price"'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('records share columns and only nested values open a new table',
      (tester) async {
    final heap = {
      'rows': {
        'type': 'list',
        'items': [
          {'type': 'dict', 'ref': 'first'},
          {'type': 'dict', 'ref': 'second'}
        ]
      },
      for (final (id, score) in [('first', 5), ('second', 8)])
        id: {
          'type': 'dict',
          'entries': [
            [
              {'type': 'str', 'value': 'score'},
              {'type': 'int', 'value': score}
            ],
            [
              {'type': 'str', 'value': 'tags'},
              {'type': 'list', 'ref': 'tags'}
            ]
          ]
        },
      'tags': {
        'type': 'list',
        'items': [
          {'type': 'str', 'value': 'sample'}
        ]
      }
    };
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RuntimeValueView(
                value: SceneValue(
                    'results', {'type': 'list', 'ref': 'rows'}, heap)))));
    await tester.tap(find.text('展开内容（2 项已记录）'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    Finder inDialog(String text) =>
        find.descendant(of: dialog, matching: find.text(text));
    expect(inDialog('索引'), findsOneWidget);
    expect(inDialog('score'), findsOneWidget);
    expect(inDialog('tags'), findsOneWidget);
    expect(inDialog('5'), findsOneWidget);
    expect(inDialog('8'), findsOneWidget);
    await tester.tap(inDialog('5'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('value-path')), findsNothing);
    await tester.tap(inDialog('列表 · 1 项').first);
    await tester.pumpAndSettle();
    expect(inDialog('results / [0].tags'), findsOneWidget);
    expect(inDialog('"sample"'), findsOneWidget);
    await tester.tap(find.byTooltip('返回上一级'));
    await tester.pumpAndSettle();
    expect(inDialog('8'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'future reads remain hidden and the whole process retains its nodes',
      (tester) async {
    const beats = [
      ProcessBeat(
          '取值',
          '读取 a',
          LearningScene(title: '', kind: 'read', inputs: [
            SceneValue('a', {'type': 'int', 'value': 1}, {})
          ])),
      ProcessBeat(
          '取值',
          '调用后读取 a',
          LearningScene(title: '', kind: 'read', inputs: [
            SceneValue('a', {'type': 'int', 'value': 537}, {})
          ]))
    ];
    Widget diagram(int active) => MaterialApp(
        home: Scaffold(
            body: ProcessDiagram(
                beats: beats, active: active, onSelect: (_) {})));
    await tester.pumpWidget(diagram(0));
    expect(find.text('1'), findsWidgets);
    expect(find.text('537'), findsNothing);
    expect(find.text('尚未执行'), findsOneWidget);
    await tester.pumpWidget(diagram(1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('537'), findsOneWidget);
    expect(find.text('取值'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('long data and multiple stages do not overflow a narrow window',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final beats = [
      for (var i = 0; i < 10; i++)
        ProcessBeat(
            '运算',
            '',
            LearningScene(
                title: '',
                kind: 'calculation',
                operation: 'very_long_expression',
                result: SceneValue(
                    '结果', {'type': 'str', 'value': '长文本' * 1000}, const {})))
    ];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: ProcessDiagram(
                    beats: beats, active: 9, onSelect: (_) {})))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(find.text('10')).dx, lessThan(360));
    await tester.pumpWidget(const SizedBox());
  });
}
