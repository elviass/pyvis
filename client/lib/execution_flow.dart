class FlowPlace {
  final String label, code, file;
  final int? line;
  final dynamic frameId;
  const FlowPlace(this.label, this.code, this.file, this.line, this.frameId);
}

bool isLearningStop(Map e) =>
    e['kind'] == 'statement' ||
    (e['kind'] == 'call' && (e['frames'] as List? ?? []).length > 1);

class ExecutionFlow {
  final FlowPlace? previous, next;
  final FlowPlace current;
  final String transition;
  const ExecutionFlow(this.previous, this.current, this.next, this.transition);
}

ExecutionFlow executionFlow(
    Map<String, dynamic> event, List<Map<String, dynamic>> events, Map sources,
    {bool finished = true}) {
  String code(String file, int? line) {
    final lines = '${sources[file] ?? ''}'.split('\n');
    return line == null || line < 1 || line > lines.length
        ? ''
        : lines[line - 1].trim();
  }

  FlowPlace place(Map e) {
    final frames = (e['before']?['frames'] ?? e['frames'] ?? []) as List;
    final frame = frames.isEmpty ? {} : frames.last as Map;
    final file = '${e['file'] ?? ''}';
    final line = e['line'] as int?;
    final name = '${frame['name'] ?? ''}';
    return FlowPlace(e['kind'] == 'call' ? '进入 $name' : '第 $line 行',
        '${e['code'] ?? code(file, line)}', file, line, frame['id']);
  }

  final seq = event['seq'] as int;
  final prior = events.take(seq).where(isLearningStop);
  final current = place(event);
  FlowPlace? next;
  var transition = '继续';
  for (final e in events.skip(seq + 1)) {
    if (e['kind'] == 'call' && (e['frames'] as List).length > 1) {
      next = place(e);
      transition = '进入函数';
      break;
    }
    if (e['kind'] == 'return' && (e['frames'] as List).length > 1) {
      final caller =
          (e['frames'] as List)[(e['frames'] as List).length - 2] as Map;
      final file = '${caller['file']}';
      final line = caller['line'] as int?;
      next =
          FlowPlace('回到第 $line 行', code(file, line), file, line, caller['id']);
      transition = '返回调用处';
      break;
    }
    if (e['kind'] == 'line') {
      next = place(e);
      if (next.frameId == current.frameId &&
          next.file == current.file &&
          next.line != null &&
          current.line != null &&
          next.line! <= current.line!) {
        transition = '回到前面';
      } else if (const ['If', 'While', 'For']
          .contains(event['statement_type'])) {
        transition = '实际选择的路';
      }
      break;
    }
  }
  if (event['outcome'] == 'exception') {
    next = null;
    transition = '出错，暂停';
  } else if (next == null) {
    transition = finished ? '执行结束' : '等待下一步';
  }
  FlowPlace? previous = prior.isEmpty ? null : place(prior.last);
  // A call starts while its caller's statement is still pending, so the last
  // completed statement is not the call site. Read the live caller frame.
  final frames = event['frames'] as List? ?? [];
  if (event['kind'] == 'call' && frames.length > 1) {
    final caller = frames[frames.length - 2] as Map;
    final file = '${caller['file']}';
    final line = caller['line'] as int?;
    previous =
        FlowPlace('第 $line 行', code(file, line), file, line, caller['id']);
  }
  return ExecutionFlow(previous, current, next, transition);
}
