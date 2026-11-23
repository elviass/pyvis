import 'dart:convert';
import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyvis_editor/execution_flow.dart';
import 'package:pyvis_editor/line_process.dart';
import 'package:pyvis_editor/line_theater.dart';

void main() {
  final data =
      jsonDecode(File('test/fixtures/flow_traces.json').readAsStringSync())
          as Map;
  List<Map<String, dynamic>> events(String name) =>
      (data[name]['events'] as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
  Map<String, dynamic> statement(List<Map<String, dynamic>> es, int line) =>
      es.firstWhere((e) => e['kind'] == 'statement' && e['line'] == line);

  test('nested expressions retain real order and store the final result last',
      () {
    final es = events('nested');
    final beats = lineBeats(statement(es, 4), es);
    expect(beats.map((b) => b.label), ['取值', '运算', '运算', '赋值给 result']);
    expect(beats[1].scene.operation, 'b*c');
    expect(beats[1].scene.result!.text, '12');
    expect(beats[2].scene.inputs.map((v) => v.text), ['2', '12']);
    expect(beats.last.scene.result!.text, '14');
  });
  test('reads on either side of a mutating call keep their observed values',
      () {
    final es = events('changed_read');
    final beats = lineBeats(statement(es, 6), es);
    final reads =
        beats.where((b) => b.label == '取值').expand((b) => b.scene.inputs);
    expect(reads.where((v) => v.label == 'a').map((v) => v.text), ['1', '5']);
    expect(beats.last.scene.result!.text, '8');
  });
  test('short circuit never invents an unexecuted division beat', () {
    final es = events('short');
    final beats = lineBeats(statement(es, 2), es);
    expect(beats.where((b) => b.scene.operation == '1/x'), isEmpty);
    expect(beats.last.scene.result!.text, 'False');
  });
  test('branch route skips the unexecuted arm and a loop really returns', () {
    var es = events('branch');
    final branch =
        executionFlow(statement(es, 2), es, data['branch']['sources']);
    expect(branch.next!.line, 5);
    expect(branch.transition, '实际选择的路');
    es = events('loop');
    final loop = executionFlow(statement(es, 3), es, data['loop']['sources']);
    expect(loop.next!.line, 2);
    expect(loop.transition, '回到前面');
    final checks =
        es.where((e) => e['kind'] == 'statement' && e['line'] == 2).toList();
    expect(
        executionFlow(checks.last, es, data['loop']['sources']).next!.line, 4);
  });
  test('function entry is a playback stop; return points back to its caller',
      () {
    final es = events('function');
    final call = es.firstWhere(
        (e) => e['kind'] == 'call' && (e['frames'] as List).length == 2);
    expect(isLearningStop(call), true);
    expect(
        lineBeats(call, es).single.scene.inputs.map((v) => v.text), ['2', '3']);
    final entry = executionFlow(call, es, data['function']['sources']);
    expect(entry.current.label, '进入 add');
    expect(entry.previous!.line, 3);
    expect(entry.previous!.code, 'total=add(2,3)');
    expect(entry.next!.line, 2);
    final returned =
        executionFlow(statement(es, 2), es, data['function']['sources']);
    expect(returned.transition, '返回调用处');
    expect(returned.next!.line, 3);
    expect(returned.next!.frameId, 1);
  });
  test('recursive returns target distinct caller instances', () {
    final es = events('recursion');
    final returns = es.where(
        (e) => e['kind'] == 'statement' && e['statement_type'] == 'Return');
    final routes =
        returns.map((e) => executionFlow(e, es, data['recursion']['sources']));
    expect(routes.every((r) => r.transition == '返回调用处'), true);
    expect(routes.map((r) => r.next!.frameId).toSet().length, 3);
  });
  test('live frontier is waiting, completed trace is ended', () {
    final es = events('nested');
    final last = es.lastWhere((e) => e['kind'] == 'statement');
    expect(
        executionFlow(last, es, data['nested']['sources']).transition, '执行结束');
    expect(
        executionFlow(last, es, data['nested']['sources'], finished: false)
            .transition,
        '等待下一步');
  });
  testWidgets(
      'process visibly advances, pauses, replays and stores after movement',
      (tester) async {
    final es = events('nested');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: LineTheater(
                    event: statement(es, 4),
                    events: es,
                    sources: data['nested']['sources'])))));
    expect(find.text('14'), findsOneWidget);
    expect(find.text('读取本步骤所需变量的当前值'), findsNothing);
    await tester.tap(find.text('查看行内过程'));
    await tester.pump();
    expect(find.text('读取本步骤所需变量的当前值'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text('现在执行 b*c'), findsOneWidget);
    await tester.tap(find.byTooltip('暂停本行演示').first);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('现在执行 b*c'), findsOneWidget);
    await tester.tap(find.byTooltip('播放本行演示').first);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text('现在执行 a+b*c'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text('将结果赋给 result，完成本行赋值'), findsOneWidget);
    expect(find.text('空'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();
    expect(find.text('空'), findsNothing);
    expect(find.text('14'), findsWidgets);
    await tester.tap(find.byTooltip('重播这一行').first);
    await tester.pump();
    expect(find.text('读取本步骤所需变量的当前值'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
