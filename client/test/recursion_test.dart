import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyvis_editor/learning_scene.dart';
import 'package:pyvis_editor/line_process.dart';
import 'package:pyvis_editor/recursion_view.dart';

void main() {
  final data =
      jsonDecode(File('test/fixtures/flow_traces.json').readAsStringSync())
          as Map;
  List<Map<String, dynamic>> trace(String name) =>
      (data[name]['events'] as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
  test(
      'inline recursive return computes the outer multiplication before returning',
      () {
    final es = trace('recursion');
    final returns = es
        .where(
            (e) => e['kind'] == 'statement' && e['statement_type'] == 'Return')
        .toList();
    expect(returns.map((e) => (e['values'] as List).first['value']), [1, 2, 6]);
    for (final e in returns) {
      final beats = lineBeats(e, es);
      expect(beats.last.scene.kind, 'return');
      expect(beats.last.scene.result!.value, e['values'][0]);
      if (e['line'] == 4) {
        final scene = learningScene(e, es);
        expect(scene.kind, 'calculation');
        expect(scene.signs, ['×']);
        expect(scene.result!.value, e['values'][0]);
      }
    }
  });
  test(
      'every live invocation retains its own entry parameters and pending line',
      () {
    final es = trace('recursion_split');
    final deepest = es.firstWhere(
        (e) => e['kind'] == 'call' && (e['frames'] as List).length == 6);
    final state = recursionState(deepest, es);
    expect(state.calls.map((c) => c.arguments),
        ['n=5', 'n=4', 'n=3', 'n=2', 'n=1']);
    expect(state.calls.map((c) => c.id).toSet().length, 5);
    expect(
        state.calls.take(4).every((c) => c.status.contains('等待下一层返回')), true);
    expect(state.calls.last.status, '正在执行');
    expect(state.returning, isNull);
  });
  test('base case returns to the immediate caller, not the outermost frame',
      () {
    final es = trace('recursion_split');
    final base = es.firstWhere(
        (e) => e['kind'] == 'statement' && e['statement_type'] == 'Return');
    final state = recursionState(base, es);
    expect(state.calls.last.arguments, 'n=1');
    expect(state.calls.last.status, '返回 1');
    expect(state.calls[state.calls.length - 2].arguments, 'n=2');
    expect(state.returning, contains('factorial的第 4 行'));
  });
  test('unwinding split recursion restores each parent and finishes at 120',
      () {
    final es = trace('recursion_split');
    final returns = es
        .where(
            (e) => e['kind'] == 'statement' && e['statement_type'] == 'Return')
        .toList();
    expect(returns.map((e) => (e['values'] as List).first['value']),
        [1, 2, 6, 24, 120]);
    expect(returns.map((e) => recursionState(e, es).calls.length),
        [5, 4, 3, 2, 1]);
    final assignment =
        es.firstWhere((e) => e['kind'] == 'statement' && e['line'] == 8);
    expect(learningScene(assignment, es).result!.text, '120');
    expect(recursionState(assignment, es).calls.single.status, '返回 120');
  });
  test(
      'two recursive calls in one expression have distinct identities and final sum',
      () {
    final es = trace('fibonacci');
    final outer = es.lastWhere(
        (e) => e['kind'] == 'statement' && e['statement_type'] == 'Return');
    final scene = learningScene(outer, es);
    expect(scene.kind, 'calculation');
    expect(scene.inputs.map((v) => v.text), ['2', '1']);
    expect(scene.result!.text, '3');
    expect(lineBeats(outer, es).last.scene.result!.text, '3');
    final calls = es
        .where((e) => e['kind'] == 'call' && (e['frames'] as List).length > 1);
    expect(calls.map((e) => (e['frames'] as List).last['id']).toSet().length,
        calls.length);
    final beforeFirst = es.firstWhere((e) =>
        e['kind'] == 'statement' && e['statement_type'] == 'FunctionDef');
    expect(recursionState(beforeFirst, es).calls, isEmpty);
  });
}
