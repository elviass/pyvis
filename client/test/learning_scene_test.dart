import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyvis_editor/learning_scene.dart';

void main() {
  late Map data;
  setUpAll(() => data =
      jsonDecode(File('test/fixtures/learning_traces.json').readAsStringSync())
          as Map);
  (Map<String, dynamic>, List<Map<String, dynamic>>) record(
      String name, int line) {
    final events = (data[name]['events'] as List)
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    return (
      events.firstWhere((e) => e['kind'] == 'statement' && e['line'] == line),
      events
    );
  }

  test(
      'calculation shows actual values and one destination without interpreter identifiers',
      () {
    final (event, events) = record('math', 3);
    final scene = learningScene(event, events);
    expect(scene.kind, 'calculation');
    expect(scene.inputs.map((v) => v.text), ['20', '3']);
    expect(scene.signs, ['×']);
    expect(scene.result!.text, '60');
    expect(scene.target, 'total');
    expect(scene.title, isNot(contains('Assign')));
  });
  test('condition reports observed truth and the actual next line', () {
    final (event, events) = record('math', 4);
    final scene = learningScene(event, events);
    expect(scene.kind, 'condition');
    expect(scene.result!.value['value'], true);
    expect(scene.nextLine, 5);
    expect(scene.signs, ['≥']);
    expect(scene.title, contains('成立'));
  });
  test('shared list has a single visible object and two variable names', () {
    final (event, events) = record('list', 2);
    final scene = learningScene(event, events);
    expect(scene.kind, 'alias');
    expect(scene.aliases, containsAll(['a', 'b']));
    expect(scene.result!.text, '[10, 20]');
    expect(scene.result!.text, isNot(contains('#')));
  });
  test('mutation shows before and after, not an opaque address', () {
    final (event, events) = record('list', 3);
    final scene = learningScene(event, events);
    expect(scene.kind, 'mutation');
    expect(scene.previous!.text, '[10, 20]');
    expect(scene.result!.text, '[10, 20, 30]');
    expect(scene.aliases, containsAll(['a', 'b']));
  });
  test('printing shows screen contents, not print function internals or None',
      () {
    final (event, events) = record('list', 4);
    final scene = learningScene(event, events);
    expect(scene.kind, 'output');
    expect(scene.result!.text, '[10, 20, 30]');
    expect(scene.inputs, isEmpty);
    expect(scene.title, isNot(contains('调用')));
  });
  test('a function call uses real parameter values and return value', () {
    final (event, events) = record('function', 3);
    final scene = learningScene(event, events);
    expect(scene.kind, 'function');
    expect(scene.inputs.map((v) => v.text), ['2', '3']);
    expect(scene.result!.text, '5');
    expect(scene.target, 'total');
    expect(scene.title, isNot(contains('调用帧')));
  });
}
