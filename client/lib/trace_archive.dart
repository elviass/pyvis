import 'dart:convert';

/// Validate a recording before replacing the active session.
Map<String, dynamic> decodeTrace(String text) {
  final raw = jsonDecode(text);
  if (raw is! Map<String, dynamic> ||
      raw['version'] != 1 ||
      raw['events'] is! List) {
    throw const FormatException('不支持的执行记录格式');
  }
  void value(dynamic item, [Map? heap]) {
    if (item is! Map ||
        item['type'] is! String ||
        (item.containsKey('ref') &&
            (item['ref'] is! String ||
                heap != null && !heap.containsKey(item['ref'])))) {
      throw const FormatException('执行记录中的值无效');
    }
  }

  void snapshot(dynamic item) {
    if (item is! Map || item['frames'] is! List || item['heap'] is! Map) {
      throw const FormatException('执行记录缺少作用域或对象');
    }
    final heap = item['heap'] as Map;
    for (final frame in item['frames']) {
      if (frame is! Map ||
          frame['id'] is! int ||
          frame['locals'] is! Map ||
          (frame['name'] != null && frame['name'] is! String) ||
          (frame['line'] != null && frame['line'] is! int)) {
        throw const FormatException('执行记录中的调用帧无效');
      }
      for (final variable in frame['locals'].values) {
        value(variable, heap);
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
          value(v, heap);
        }
      }
      if (obj['attributes'] != null) {
        if (obj['attributes'] is! Map) throw const FormatException('对象属性无效');
        for (final v in obj['attributes'].values) {
          value(v, heap);
        }
      }
      if (obj['entries'] != null) {
        if (obj['entries'] is! List) throw const FormatException('字典元素无效');
        for (final pair in obj['entries']) {
          if (pair is! List || pair.length != 2) {
            throw const FormatException('字典键值无效');
          }
          value(pair[0], heap);
          value(pair[1], heap);
        }
      }
    }
  }

  final result = <Map<String, dynamic>>[];
  for (final item in raw['events']) {
    if (item is! Map<String, dynamic> ||
        item['seq'] != result.length ||
        item['kind'] is! String ||
        ['line', 'column', 'next_line', 'next_column', 'start_seq']
            .any((key) => item[key] != null && item[key] is! int) ||
        ['file', 'statement_type', 'outcome', 'code', 'text', 'prompt']
            .any((key) => item[key] != null && item[key] is! String) ||
        (item['branch_taken'] != null && item['branch_taken'] is! bool) ||
        item['values'] is! List) {
      throw const FormatException('执行事件无效');
    }
    snapshot(item);
    for (final v in item['values']) {
      value(v, item['heap'] as Map);
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
          operations
              .any((seq) => seq is! int || seq < 0 || seq >= result.length)) {
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
    result.add(item);
  }
  final sources = raw['sources'];
  if (sources is! Map || sources.values.any((v) => v is! String)) {
    throw const FormatException('缺少源码快照');
  }
  if (raw['error'] != null && raw['error'] is! Map) {
    throw const FormatException('异常记录无效');
  }
  return {
    ...raw,
    'events': result,
    'sources': Map<String, dynamic>.from(sources)
  };
}
