import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'execution_flow.dart';
import 'execution_output.dart';
import 'recording_heaps.dart';

const _maxTraceFileMiB = 64;
const maxTraceFileBytes = _maxTraceFileMiB * 1024 * 1024;
// Leave room for the runtime's independent trace and output event budgets.
const _maxTraceEvents = 50000;

typedef ImportedTrace = ({
  ExecutionRecording recording,
  Map<String, dynamic> sources,
  Map<String, dynamic>? error,
  ExecutionOutput console,
});

/// Reads and prepares an archive in the background isolate used by the editor.
ImportedTrace readTraceFile(String path) {
  final file = File(path).openSync();
  final Uint8List bytes;
  try {
    final length = file.lengthSync();
    if (length > maxTraceFileBytes) {
      throw const FormatException('执行记录文件超过 $_maxTraceFileMiB MiB 上限');
    }
    bytes = file.readSync(length);
    if (bytes.length != length || file.readByteSync() != -1) {
      throw const FormatException('执行记录在读取期间发生变化，请重试');
    }
  } finally {
    file.closeSync();
  }

  final (archive, recording) = _decodeTrace(utf8.decode(bytes));
  final console = ExecutionOutput();
  final output = archive['output'];
  if (output is Map) {
    console
      ..append('${output['stdout'] ?? ''}')
      ..append('${output['stderr'] ?? ''}');
  } else {
    console.append('${output ?? ''}');
  }
  if (archive['output_truncated'] == true) console.truncated = true;
  return (
    recording: recording,
    sources: archive['sources'] as Map<String, dynamic>,
    error: archive['error'] as Map<String, dynamic>?,
    console: console,
  );
}

/// Validate a recording and expose the v1 event shape with lazy heaps.
Map<String, dynamic> decodeTrace(String text) => _decodeTrace(text).$1;

(Map<String, dynamic>, ExecutionRecording) _decodeTrace(String text) {
  final raw = jsonDecode(text);
  if (raw is! Map<String, dynamic> ||
      (raw['version'] != 1 && raw['version'] != 2) ||
      raw['events'] is! List) {
    throw const FormatException('不支持的执行记录格式');
  }
  final events = raw['events'] as List;
  if (events.length > _maxTraceEvents) {
    throw const FormatException('执行记录超过 $_maxTraceEvents 个事件的上限');
  }
  final compact = raw['version'] == 2;
  final recording = ExecutionRecording();
  if (compact) recording.readHeapTables(raw);

  void value(dynamic item, [Set<String>? heapIds]) {
    if (item is! Map ||
        item['type'] is! String ||
        (item.containsKey('ref') &&
            (item['ref'] is! String ||
                heapIds != null && !heapIds.contains(item['ref'])))) {
      throw const FormatException('执行记录中的值无效');
    }
  }

  Set<String> snapshot(dynamic item) {
    if (item is! Map || item['frames'] is! List || item['heap'] is! Map) {
      throw const FormatException('执行记录缺少作用域或对象');
    }
    final heap = item['heap'] as Map;
    if (heap.length > maxSnapshotObjects) {
      throw const FormatException('单步快照超过 $maxSnapshotObjects 个对象的上限');
    }
    final heapIds = heap.keys.cast<String>().toSet();
    if (heapIds.length != heap.length) {
      throw const FormatException('单个快照包含重复对象');
    }
    for (final frame in item['frames']) {
      if (frame is! Map ||
          frame['id'] is! int ||
          frame['locals'] is! Map ||
          (frame['name'] != null && frame['name'] is! String) ||
          (frame['line'] != null && frame['line'] is! int)) {
        throw const FormatException('执行记录中的调用帧无效');
      }
      for (final variable in frame['locals'].values) {
        value(variable, heapIds);
      }
    }
    for (final obj in heap.values) {
      if (obj is! Map ||
          obj['type'] is! String ||
          (obj['length'] != null && obj['length'] is! int)) {
        throw const FormatException('执行记录中的对象无效');
      }
      if (obj['items'] != null) {
        if (obj['items'] is! List) throw const FormatException('容器元素无效');
        for (final v in obj['items']) {
          value(v, heapIds);
        }
      }
      if (obj['attributes'] != null) {
        if (obj['attributes'] is! Map) throw const FormatException('对象属性无效');
        for (final v in obj['attributes'].values) {
          value(v, heapIds);
        }
      }
      if (obj['entries'] != null) {
        if (obj['entries'] is! List) throw const FormatException('字典元素无效');
        for (final pair in obj['entries']) {
          if (pair is! List || pair.length != 2) {
            throw const FormatException('字典键值无效');
          }
          value(pair[0], heapIds);
          value(pair[1], heapIds);
        }
      }
    }
    return heapIds;
  }

  for (var index = 0; index < events.length; index++) {
    final rawEvent = events[index];
    if (rawEvent is! Map<String, dynamic>) {
      throw const FormatException('执行事件无效');
    }
    final item = compact ? recording.readHeapReferences(rawEvent) : rawEvent;
    if (item['seq'] != recording.events.length ||
        item['kind'] is! String ||
        ['line', 'column', 'next_line', 'next_column', 'start_seq']
            .any((key) => item[key] != null && item[key] is! int) ||
        ['file', 'statement_type', 'outcome', 'code', 'text', 'prompt']
            .any((key) => item[key] != null && item[key] is! String) ||
        (item['branch_taken'] != null && item['branch_taken'] is! bool) ||
        (item['output_truncated'] != null &&
            item['output_truncated'] is! bool) ||
        item['values'] is! List) {
      throw const FormatException('执行事件无效');
    }
    final heapIds = snapshot(item);
    for (final v in item['values']) {
      value(v, heapIds);
    }
    final operands = item['operands'];
    if (operands != null) {
      if (operands is! List || operands.any((op) => op is! Map)) {
        throw const FormatException('行内运算参数无效');
      }
      for (final operand in operands) {
        value(operand['value']);
      }
    }
    final operators = item['operators'];
    if (operators != null && operators is! List) {
      throw const FormatException('行内运算符无效');
    }
    if (item['kind'] == 'statement') {
      snapshot(item['before']);
      final operations = item['operation_seqs'];
      if (operations is! List ||
          operations.any((seq) =>
              seq is! int || seq < 0 || seq >= recording.events.length)) {
        throw const FormatException('缺少行内运算记录');
      }
      final names = item['assigned_names'];
      final body = item['body_range'];
      if ((names != null &&
              (names is! List || names.any((n) => n is! String))) ||
          (body != null &&
              (body is! List ||
                  body.length != 2 ||
                  body.any((n) => n is! int)))) {
        throw const FormatException('语句记录无效');
      }
    }
    recording.add(item, compareFullObjects: !compact);
    events[index] = null;
  }
  final sources = raw['sources'];
  if (sources is! Map || sources.values.any((v) => v is! String)) {
    throw const FormatException('缺少源码快照');
  }
  if (raw['error'] != null && raw['error'] is! Map) {
    throw const FormatException('异常记录无效');
  }
  if (raw['output_truncated'] != null && raw['output_truncated'] is! bool) {
    throw const FormatException('输出截断标记无效');
  }
  if (compact) {
    raw
      ..remove('objects')
      ..remove('heap_blocks');
  }
  raw
    ..['version'] = 1
    ..['events'] = recording.events
    ..['sources'] = Map<String, dynamic>.from(sources);
  return (raw, recording);
}
