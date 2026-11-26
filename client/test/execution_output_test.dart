import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyvis_editor/execution_output.dart';
import 'package:pyvis_editor/learning_scene.dart';
import 'package:pyvis_editor/trace_archive.dart';

void main() {
  test('console caps UTF-8 at a whole character and marks truncation once', () {
    final console = ExecutionOutput(maxBytes: 7);
    console
      ..append('A')
      ..append('好😀')
      ..append('later');
    expect(console.text, 'A好');
    expect(console.truncated, isTrue);
    expect(console.displayText, 'A好$outputTruncatedNotice');
    console
      ..clear()
      ..append('好😀');
    expect(console.displayText, '好😀');
    expect(console.truncated, isFalse);
  });

  test(
      'replay shows the recorded output and truncation notice at the print step',
      () {
    final events = [
      {
        'seq': 0,
        'kind': 'output',
        'text': '前半段',
        'channel': 'stdout',
        'output_truncated': true,
        'frames': [],
        'heap': {},
        'values': [],
      },
      {
        'seq': 1,
        'kind': 'statement',
        'start_seq': 0,
        'line': 1,
        'code': 'print(text)',
        'operation_seqs': [],
        'before': {'frames': [], 'heap': {}},
        'frames': [],
        'heap': {},
        'values': [],
      }
    ];
    final archive = decodeTrace(jsonEncode({
      'version': 1,
      'sources': {},
      'events': events,
      'output': '前半段',
      'output_truncated': true,
    }));
    final replay = (archive['events'] as List).cast<Map<String, dynamic>>();
    final scene = learningScene(replay.last, replay);
    expect(scene.kind, 'output');
    expect(scene.result!.text, '前半段\n[输出已截断]');
    expect(archive['output_truncated'], isTrue);
  });
}
