import 'dart:convert';

/// Validate a recording before replacing the active session.
Map<String, dynamic> decodeTrace(String text) {
  final raw = jsonDecode(text);
  if (raw is! Map<String, dynamic> ||
      raw['version'] != 1 ||
      raw['events'] is! List) {
    throw const FormatException('不支持的执行记录格式');
  }
  void value(dynamic item) {
    if (item is! Map ||
        item['type'] is! String ||
        (item.containsKey('ref') && item['ref'] is! String)) {
      throw const FormatException('执行记录中的值无效');
    }
  }

  void snapshot(dynamic item) {
    if (item is! Map || item['frames'] is! List || item['heap'] is! Map) {
      throw const FormatException('执行记录缺少作用域或对象');
    }
    for (final frame in item['frames']) {
      if (frame is! Map || frame['id'] is! int || frame['locals'] is! Map) {
        throw const FormatException('执行记录中的调用帧无效');
      }
      for (final variable in frame['locals'].values) {
        value(variable);
      }
    }
    for (final obj in item['heap'].values) {
      if (obj is! Map || obj['type'] is! String) {
        throw const FormatException('执行记录中的对象无效');
      }
      if (obj['items'] != null) {
        if (obj['items'] is! List) throw const FormatException('容器元素无效');
        for (final v in obj['items']) {
          value(v);
        }
      }
      if (obj['attributes'] != null) {
        if (obj['attributes'] is! Map) throw const FormatException('对象属性无效');
        for (final v in obj['attributes'].values) {
          value(v);
        }
      }
      if (obj['entries'] != null) {
        if (obj['entries'] is! List) throw const FormatException('字典元素无效');
        for (final pair in obj['entries']) {
          if (pair is! List || pair.length != 2) {
            throw const FormatException('字典键值无效');
          }
          value(pair[0]);
          value(pair[1]);
        }
      }
    }
  }

  final result = <Map<String, dynamic>>[];
  for (final item in raw['events']) {
    if (item is! Map<String, dynamic> ||
        item['seq'] != result.length ||
        item['kind'] is! String ||
        (item['line'] != null && item['line'] is! int) ||
        item['values'] is! List) {
      throw const FormatException('执行事件无效');
    }
    snapshot(item);
    for (final v in item['values']) {
      value(v);
    }
    if (item['kind'] == 'statement') {
      snapshot(item['before']);
      if (item['operation_seqs'] is! List) {
        throw const FormatException('缺少行内运算记录');
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
