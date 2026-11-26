import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyvis_editor/execution_flow.dart';
import 'package:pyvis_editor/trace_archive.dart';

Map<String, dynamic> _snapshot(Map<String, dynamic> heap) =>
    {'frames': [], 'heap': heap, 'values': []};

Map<String, dynamic> _event(int seq, Map<String, dynamic> heap,
        {String kind = 'line', Map<String, dynamic>? before}) =>
    {
      'seq': seq,
      'kind': kind,
      ..._snapshot(heap),
      if (before != null) ...{
        'before': _snapshot(before),
        'operation_seqs': [0],
      },
    };

Map<String, dynamic> _object(int value) => {
      'type': 'list',
      'items': [
        {'type': 'int', 'value': value},
      ],
    };

void main() {
  test('out-of-order replay preserves snapshots, removals and output events',
      () {
    final first = {'a': _object(1), 'b': _object(2)};
    final recording = ExecutionRecording()
      ..add(_event(0, first))
      ..add(_event(1, {}, kind: 'output')..['text'] = 'before update\n')
      ..add(_event(2, {'a': _object(3)},
          kind: 'statement', before: {'a': null, 'b': null}))
      ..add(_event(3, {'a': null, 'b': _object(4)}));

    expect(recording.events[3]['heap'], {'a': _object(3), 'b': _object(4)});
    final statement = recording.stepAt(2)!;
    expect(statement['heap'], {'a': _object(3)});
    expect(statement['before']['heap'], first);
    expect(recording.events.first['heap'], first);
    expect(recording.events[1]['text'], 'before update\n');

    final exported = recording.compactArchive..['sources'] = {'main.py': ''};
    expect(exported['version'], 2);
    expect(exported['objects'], hasLength(4));
    final restored = decodeTrace(jsonEncode(exported));
    expect(restored['events'], recording.events);
    expect(jsonDecode(jsonEncode(restored))['events'], recording.events);
  });

  test('a rejected delta cannot change the next snapshot baseline', () {
    final recording = ExecutionRecording()..add(_event(0, {'a': _object(1)}));
    expect(
        () => recording.add(_event(1, {'missing': null},
            kind: 'statement', before: {'a': _object(2)})),
        throwsFormatException);
    recording.add(_event(1, {'a': null}));
    expect(recording.events[1]['heap'], {'a': _object(1)});
    expect(recording.compactArchive['objects'], hasLength(1));
  });

  test('legacy archives preserve objects that reference each other', () {
    final first = {
      'a': {
        'type': 'list',
        'items': [
          {'type': 'list', 'ref': 'b'},
        ],
      },
      'b': _object(2),
    };
    final events = [
      _event(0, first),
      _event(1, {'b': _object(3), 'a': first['a']}),
    ];
    final restored = decodeTrace(jsonEncode(
        {'version': 1, 'events': events, 'sources': <String, String>{}}));
    expect(restored['events'], events);
    final changed = (restored['events'] as List).last['heap'] as Map;
    expect(changed.keys, ['b', 'a']);
  });

  test('compact archives reject broken indices and duplicate snapshot IDs', () {
    final recording = ExecutionRecording()..add(_event(0, {'a': _object(1)}));
    final archive = recording.compactArchive..['sources'] = {};
    final event = (archive['events'] as List).single as Map;
    event['heap'] = [1];
    expect(() => decodeTrace(jsonEncode(archive)), throwsFormatException);
    event['heap'] = [0, 0];
    expect(() => decodeTrace(jsonEncode(archive)), throwsFormatException);
  });
}
