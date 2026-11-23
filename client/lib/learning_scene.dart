import 'dart:convert';

class SceneValue {
  final String label;
  final dynamic value;
  final Map heap;
  const SceneValue(this.label, this.value, this.heap);
  String get text => plainValue(value, heap);
}

String plainValue(dynamic value, Map heap, [Set<String>? visited]) {
  if (value is! Map) return value == null ? '' : value.toString();
  if (value.containsKey('ref')) {
    final ref = '${value['ref']}';
    final seen = {...?visited};
    if (!seen.add(ref)) return '↩ 指回自己';
    final obj = heap[ref] as Map? ?? {};
    if (obj['items'] is List) {
      final items = obj['items'] as List;
      return '[${items.take(8).map((v) => plainValue(v, heap, seen)).join(', ')}${items.length > 8 ? ', …' : ''}]';
    }
    if (obj['entries'] is List) {
      return '{${(obj['entries'] as List).take(5).map((p) => '${plainValue(p[0], heap, seen)}: ${plainValue(p[1], heap, seen)}').join(', ')}}';
    }
    if (obj['name'] != null) return '${obj['name']}';
    if (obj['attributes'] is Map && (obj['attributes'] as Map).isNotEmpty) {
      return (obj['attributes'] as Map)
          .entries
          .take(4)
          .map((e) => '${e.key} = ${plainValue(e.value, heap, seen)}')
          .join('\n');
    }
    return '对象';
  }
  return switch (value['type']) {
    'str' => jsonEncode(value['value']),
    'NoneType' => 'None',
    'bool' => value['value'] == true ? 'True' : 'False',
    _ => '${value['value']}',
  };
}

String operatorLabel(dynamic name) =>
    const {
      'Add': '+',
      'Sub': '−',
      'Mult': '×',
      'Div': '÷',
      'FloorDiv': '//',
      'Mod': '%',
      'Pow': '**',
      'Eq': '==',
      'NotEq': '≠',
      'Gt': '>',
      'GtE': '≥',
      'Lt': '<',
      'LtE': '≤',
      'Is': '是同一个对象',
      'IsNot': '不是同一个对象',
      'In': '在其中',
      'NotIn': '不在其中',
      'And': '并且',
      'Or': '或者',
      'USub': '−',
      'UAdd': '+',
      'Not': '不是',
      'BitAnd': '&',
      'BitOr': '|',
      'BitXor': '^',
    }[name] ??
    '';

class LearningScene {
  final String title, kind, target, operation;
  final List<SceneValue> inputs, writes;
  final List<String> signs, aliases;
  final SceneValue? result, previous;
  final int? nextLine;
  const LearningScene(
      {required this.title,
      required this.kind,
      this.target = '',
      this.operation = '',
      this.inputs = const [],
      this.writes = const [],
      this.signs = const [],
      this.result,
      this.previous,
      this.aliases = const [],
      this.nextLine});
}

LearningScene learningScene(
    Map<String, dynamic> event, List<Map<String, dynamic>> events) {
  final before = event['before'] as Map? ?? {};
  final oldHeap = before['heap'] as Map? ?? {};
  final heap = event['heap'] as Map? ?? {};
  final beforeFrames = before['frames'] as List? ?? [];
  final frames = event['frames'] as List? ?? [];
  final frameId = beforeFrames.isEmpty ? null : beforeFrames.last['id'];
  final matches = frames.where((f) => f['id'] == frameId);
  final old = beforeFrames.isEmpty
      ? <String, dynamic>{}
      : beforeFrames.last['locals'] as Map;
  final current = matches.isEmpty
      ? (frames.isEmpty ? <String, dynamic>{} : frames.last['locals'] as Map)
      : matches.first['locals'] as Map;
  final changed = current.keys
      .where((key) => jsonEncode(old[key]) != jsonEncode(current[key]))
      .toList();
  final ops = (event['operation_seqs'] as List? ?? [])
      .whereType<int>()
      .where((i) => i >= 0 && i < events.length)
      .map((i) => events[i])
      .toList();
  final seq = event['seq'] as int;
  final start = event['start_seq'] as int? ?? seq;
  final segment = events.sublist(start.clamp(0, events.length),
      seq.clamp(start.clamp(0, events.length), events.length));
  final type = event['statement_type'];
  final code = '${event['code'] ?? ''}';
  final recordedTargets =
      (event['assigned_names'] as List? ?? []).cast<String>();
  // Older archives did not record assignment targets. Recognize only a simple
  // name assignment there; new recordings use Python's parsed AST targets.
  final legacy =
      RegExp(r'^([\w]+)\s*(?:[+*/%&|^-]?=)(?!=)').firstMatch(code.trim());
  final targets = recordedTargets.isNotEmpty
      ? recordedTargets
      : (legacy != null ? [legacy[1]!] : <String>[]);
  final assigned = targets.where(current.containsKey).toList();
  if (assigned.isNotEmpty) {
    changed.removeWhere(assigned.contains);
    changed.insertAll(0, assigned);
  }

  final frameLine = matches.isEmpty ? null : matches.first['line'] as int?;
  final following = event.containsKey('next_line')
      ? null
      : events.skip(seq + 1).where((e) {
          final followingFrames = e['frames'] as List? ?? [];
          return e['kind'] == 'line' &&
              e['file'] == event['file'] &&
              (frameId == null ||
                  (followingFrames.isNotEmpty &&
                      followingFrames.last['id'] == frameId));
        }).firstOrNull;
  final next = event.containsKey('next_line')
      ? event['next_line'] as int?
      : (frameLine != event['line'] ? frameLine : following?['line'] as int?);
  SceneValue? opValue(Map op) => (op['values'] as List? ?? []).isEmpty
      ? null
      : SceneValue('${op['expression_text'] ?? ''}', op['values'][0],
          op['heap'] as Map? ?? heap);

  if (event['outcome'] == 'exception') {
    return const LearningScene(title: '本行发生异常', kind: 'error');
  }
  if (type == 'FunctionDef' ||
      type == 'AsyncFunctionDef' ||
      type == 'ClassDef') {
    final name = changed.isEmpty ? code : changed.first.toString();
    return LearningScene(
        title: type != 'ClassDef'
            ? '定义函数 $name，调用时执行函数体'
            : '定义类 $name，后续可调用该类创建实例',
        kind: 'definition',
        target: name,
        result: changed.isEmpty ? null : SceneValue(name, current[name], heap));
  }
  final output =
      segment.where((e) => e['kind'] == 'output').map((e) => e['text']).join();
  if (output.isNotEmpty && RegExp(r'^print\s*\(').hasMatch(code.trim())) {
    return LearningScene(
        title: '将内容输出到屏幕',
        kind: 'output',
        result: SceneValue(
            '屏幕输出',
            {
              'type': 'output',
              'value': (output.endsWith('\n')
                  ? output.substring(0, output.length - 1)
                  : output)
            },
            heap));
  }
  final input = segment.where((e) => e['kind'] == 'input').lastOrNull;
  if (input != null &&
      (input['frames'] as List? ?? []).lastOrNull?['id'] == frameId) {
    final name = assigned.firstOrNull;
    final received = SceneValue(
        '输入内容', {'type': 'str', 'value': '${input['text'] ?? ''}'}, heap);
    return LearningScene(
        title: name == null ? '读取用户输入' : '读取用户输入，将本行结果赋给 $name',
        kind: 'input',
        target: name ?? '',
        inputs: name == null ? const [] : [received],
        result:
            name == null ? received : SceneValue(name, current[name], heap));
  }
  if ((type == 'For' || type == 'AsyncFor') && event['body_range'] is List) {
    final body = event['body_range'] as List;
    final entered = event.containsKey('branch_taken')
        ? event['branch_taken'] as bool?
        : frameLine != null && frameLine >= body[0] && frameLine <= body[1];
    final names = recordedTargets.where(current.containsKey).toList();
    return LearningScene(
        title: switch (entered) {
          true => names.isEmpty
              ? '取得下一个元素，执行循环体'
              : '取得下一个元素，赋给 ${names.join('、')}，执行循环体',
          false => '没有下一个元素，结束本次 for 循环',
          null => '继续处理循环',
        },
        kind: 'iteration',
        target: names.join('、'),
        inputs: entered == true
            ? names
                .map((name) => SceneValue(name, current[name], heap))
                .toList()
            : const [],
        result: entered != false
            ? null
            : const SceneValue(
                '迭代结束', {'type': 'text', 'value': '没有下一个元素'}, {}),
        writes: entered == true
            ? names
                .map((name) => SceneValue(name, current[name], heap))
                .toList()
            : const [],
        nextLine: next);
  }
  if (type == 'If' || type == 'While' || type == 'For') {
    final span = event['condition_span'];
    final check = span != null
        ? ops.reversed
            .where((op) => jsonEncode(op['span']) == jsonEncode(span))
            .firstOrNull
        : (type != 'For' ? ops.lastOrNull : null);
    final rawResult = check == null ? null : opValue(check);
    bool? truth;
    final raw = rawResult?.value;
    if (raw is Map) {
      final value = raw['value'];
      if (raw['type'] == 'bool') {
        truth = value == true;
      } else if (raw['type'] == 'NoneType') {
        truth = false;
      } else if (raw['type'] == 'str') {
        truth = (value as String).isNotEmpty;
      } else if (const ['int', 'float'].contains(raw['type'])) {
        truth = value is num ? value != 0 : true;
      } else if (raw['ref'] != null) {
        final obj = rawResult!.heap[raw['ref']] as Map?;
        if (obj?['length'] is int) truth = obj!['length'] > 0;
      }
    }
    truth = event['branch_taken'] as bool? ?? truth;
    final result = truth == null
        ? null
        : SceneValue('判断结果', {'type': 'bool', 'value': truth}, heap);
    var inputs = check == null
        ? <SceneValue>[]
        : (check['operands'] as List? ?? [])
            .map((o) => SceneValue(
                '${o['label']}', o['value'], check['heap'] as Map? ?? heap))
            .toList();
    if (inputs.isEmpty && rawResult != null) inputs = [rawResult];
    final signs =
        (check?['operators'] as List? ?? []).map(operatorLabel).toList();
    return LearningScene(
        title: type == 'For'
            ? (changed.isEmpty ? '检查是否还有下一个元素' : '读取下一个元素，赋给 ${changed.first}')
            : (truth == null
                ? '判断条件，确定后续执行路径'
                : truth
                    ? (type == 'While' ? '条件成立，进入下一轮' : '条件成立，执行此分支')
                    : (type == 'While' ? '条件不成立，结束循环' : '条件不成立，跳过此分支')),
        kind: 'condition',
        inputs: inputs,
        signs: signs,
        result: type == 'For' && changed.isNotEmpty
            ? SceneValue(changed.first.toString(), current[changed.first], heap)
            : result,
        nextLine: next,
        operation: check?['expression_text'] ?? code,
        target: changed.isEmpty ? '' : changed.first.toString());
  }
  for (final key in heap.keys) {
    if (oldHeap.containsKey(key) &&
        jsonEncode(heap[key]) != jsonEncode(oldHeap[key])) {
      final obj = heap[key] as Map;
      if (obj['items'] == null &&
          obj['attributes'] == null &&
          obj['entries'] == null) {
        continue;
      }
      final names = current.keys
          .where((name) => current[name] is Map && current[name]['ref'] == key)
          .map((e) => e.toString())
          .toList();
      final label = names.isEmpty ? '这个对象' : names.join('、');
      final ref = {'type': obj['type'], 'ref': key};
      return LearningScene(
          title: '修改 $label 的内容${names.length > 1 ? '（这些变量引用同一对象）' : ''}',
          kind: 'mutation',
          target: label,
          previous: SceneValue('原来', ref, oldHeap),
          result: SceneValue('现在', ref, heap),
          aliases: names,
          writes: changed
              .map((name) => SceneValue(name.toString(), current[name], heap))
              .toList());
    }
  }
  final target = changed.isEmpty ? '' : changed.first.toString();
  final targetValue = target.isEmpty ? null : current[target];
  if (targetValue is Map &&
      targetValue['ref'] != null &&
      oldHeap.containsKey(targetValue['ref'])) {
    final aliases = current.keys
        .where((name) =>
            current[name] is Map && current[name]['ref'] == targetValue['ref'])
        .map((n) => n.toString())
        .toList();
    if (aliases.length > 1) {
      return LearningScene(
          title:
              '$target 与 ${aliases.where((n) => n != target).join('、')} 引用同一对象',
          kind: 'alias',
          target: target,
          aliases: aliases,
          result: SceneValue('共同引用的对象', targetValue, heap));
    }
  }
  final container = switch (event['value_type']) {
    'Dict' || 'DictComp' => '字典',
    'List' || 'ListComp' => '列表',
    'Set' || 'SetComp' => '集合',
    'Tuple' => '元组',
    _ => null
  };
  if (container != null && target.isNotEmpty) {
    return LearningScene(
        title: '构建$container并赋给 $target',
        kind: 'assignment',
        target: target,
        result: SceneValue(target, targetValue, heap),
        previous: old.containsKey(target)
            ? SceneValue('原来', old[target], oldHeap)
            : null);
  }
  final calls = segment
      .where((e) =>
          e['kind'] == 'call' &&
          (e['frames'] as List).length == beforeFrames.length + 1)
      .toList();
  if (calls.isNotEmpty && ops.isNotEmpty && ops.last['expression'] == 'Call') {
    final active = (calls.first['frames'] as List).last as Map;
    final parameters = active['locals'] as Map;
    final returned = ops.where((e) => e['expression'] == 'Call').toList();
    return LearningScene(
        title:
            '调用 ${active['name']}，接收返回值${target.isEmpty ? '' : '，赋给 $target'}',
        kind: 'function',
        operation: '${active['name']}',
        inputs: parameters.entries
            .map((e) =>
                SceneValue('${e.key}', e.value, calls.first['heap'] as Map))
            .toList(),
        result: targetValue == null
            ? (returned.isEmpty ? null : opValue(returned.last))
            : SceneValue(target, targetValue, heap),
        target: target);
  }
  final calculations = ops
      .where((e) => const ['BinOp', 'UnaryOp', 'Compare', 'BoolOp', 'Subscript']
          .contains(e['expression']))
      .toList();
  if (calculations.isNotEmpty) {
    final calculation = calculations.last;
    final operands = (calculation['operands'] as List? ?? [])
        .map((o) => SceneValue(
            '${o['label']}', o['value'], calculation['heap'] as Map? ?? heap))
        .toList();
    final signs =
        (calculation['operators'] as List? ?? []).map(operatorLabel).toList();
    return LearningScene(
        title: type == 'Return'
            ? '计算结果并返回给调用方'
            : target.isEmpty
                ? '使用输入值计算结果'
                : '计算结果并赋给 $target',
        kind: 'calculation',
        inputs: operands,
        signs: signs,
        result: opValue(calculation),
        target: target,
        operation: '${calculation['expression_text']}');
  }
  final simpleCalls = ops.where((e) => e['expression'] == 'Call').toList();
  if (simpleCalls.isNotEmpty) {
    final call = simpleCalls.last;
    final name = '${call['expression_text']}'.split('(').first;
    return LearningScene(
        title: '传入参数并调用 $name，接收返回值${target.isEmpty ? '' : '，赋给 $target'}',
        kind: 'function',
        operation: name,
        target: target,
        inputs: (call['operands'] as List? ?? [])
            .map((o) => SceneValue(
                '${o['label']}', o['value'], call['heap'] as Map? ?? heap))
            .toList(),
        result: targetValue == null
            ? opValue(call)
            : SceneValue(target, targetValue, heap));
  }
  if (type == 'Return') {
    return LearningScene(
        title: '函数执行结束，将结果返回给调用方',
        kind: 'return',
        result: (event['values'] as List? ?? []).isEmpty
            ? null
            : SceneValue('返回的结果', event['values'][0], heap));
  }
  if (target.isNotEmpty) {
    return LearningScene(
        title: old.containsKey(target) ? '更新变量 $target 的值' : '创建变量 $target 并赋值',
        kind: 'assignment',
        target: target,
        result: SceneValue(target, targetValue, heap),
        previous: old.containsKey(target)
            ? SceneValue('原来', old[target], oldHeap)
            : null);
  }
  if (output.isNotEmpty) {
    return LearningScene(
        title: '将内容输出到屏幕',
        kind: 'output',
        result: SceneValue(
            '屏幕输出',
            {
              'type': 'output',
              'value': (output.endsWith('\n')
                  ? output.substring(0, output.length - 1)
                  : output)
            },
            heap));
  }
  if (type == 'Import' || type == 'ImportFrom') {
    return LearningScene(
        title: '导入所需模块或对象',
        kind: 'definition',
        target: code,
        result: SceneValue('导入完成', {'type': 'text', 'value': code}, heap));
  }
  final deleted = old.keys.where((key) => !current.containsKey(key)).toList();
  if (deleted.isNotEmpty) {
    return LearningScene(
        title: '移除变量 ${deleted.join('、')}',
        kind: 'assignment',
        target: deleted.join('、'),
        result: const SceneValue('现在', {'type': 'text', 'value': '已移除'}, {}));
  }
  return LearningScene(
      title: type == 'Pass' ? 'pass 不执行操作，继续后续代码' : '本行执行完成，继续下一步',
      kind: 'plain',
      result: SceneValue('当前代码', {'type': 'text', 'value': code}, heap));
}
