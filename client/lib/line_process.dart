import 'learning_scene.dart';

/// Each beat is projected from recorded values; replay never evaluates Python.
class ProcessBeat {
  final String label, caption;
  final LearningScene scene;
  const ProcessBeat(this.label, this.caption, this.scene);
}

List<ProcessBeat> lineBeats(
    Map<String, dynamic> event, List<Map<String, dynamic>> events) {
  final scene = learningScene(event, events);
  if (event['kind'] == 'call') {
    final frames = event['frames'] as List;
    final frame = frames.last as Map;
    final heap = event['heap'] as Map? ?? {};
    final parameters = (frame['locals'] as Map)
        .entries
        .map((e) => SceneValue('${e.key}', e.value, heap))
        .toList();
    return [
      ProcessBeat(
          '传入参数',
          '进入 ${frame['name']}，将传入值绑定到参数',
          LearningScene(
              title: '进入函数 ${frame['name']}',
              kind: 'enter',
              operation: '${frame['name']}',
              inputs: parameters))
    ];
  }
  if (scene.kind == 'error') {
    return [ProcessBeat('停在错误处', scene.title, scene)];
  }
  if (scene.kind == 'iteration') {
    return [ProcessBeat('迭代', scene.title, scene)];
  }
  final operations = (event['operation_seqs'] as List? ?? [])
      .whereType<int>()
      .where((i) => i >= 0 && i < events.length)
      .map((i) => events[i])
      .toList();
  if (scene.kind == 'alias' &&
      operations.every((op) => op['expression'] == 'Name')) {
    return [ProcessBeat('建立引用', scene.title, scene)];
  }
  final beats = <ProcessBeat>[];
  final reads = <SceneValue>[];
  void flushReads() {
    if (reads.isEmpty) return;
    beats.add(ProcessBeat(
        '取值',
        '读取本步骤所需变量的当前值',
        LearningScene(
            title: scene.title, kind: 'read', inputs: List.of(reads))));
    reads.clear();
  }

  // Follow observation order: a later read may see a value changed by a call.
  for (final op in operations) {
    final values = op['values'] as List? ?? [];
    if (values.isEmpty) continue;
    final heap = op['heap'] as Map? ?? {};
    final expression = op['expression'];
    if (expression == 'Name') {
      final value = values.first as Map;
      if (const [
        'function',
        'builtin_function_or_method',
        'type',
        'module',
        'method'
      ].contains(value['type'])) {
        continue;
      }
      reads.add(SceneValue('${op['expression_text']}', value, heap));
      continue;
    }
    if (!const ['BinOp', 'UnaryOp', 'Compare', 'BoolOp', 'Subscript', 'Call']
        .contains(expression)) {
      continue;
    }
    flushReads();
    if (expression == 'Call' &&
        const ['output', 'mutation', 'function'].contains(scene.kind)) {
      continue;
    }
    final inputs = (op['operands'] as List? ?? [])
        .map((o) => SceneValue('${o['label']}', o['value'], heap))
        .toList();
    beats.add(ProcessBeat(
        expression == 'Call' ? '接收返回值' : '运算',
        '现在执行 ${op['expression_text']}',
        LearningScene(
            title: scene.title,
            kind: expression == 'Call' ? 'function' : 'calculation',
            operation: '${op['expression_text']}',
            inputs: inputs,
            signs: (op['operators'] as List? ?? []).map(operatorLabel).toList(),
            result: SceneValue('本次计算结果', values.first, heap))));
  }
  flushReads();
  if (scene.kind == 'calculation' &&
      scene.target.isNotEmpty &&
      scene.result != null) {
    final before = event['before'] as Map? ?? {};
    final frames = before['frames'] as List? ?? [];
    final locals = frames.isEmpty ? {} : frames.last['locals'] as Map;
    // The assignment can differ from the last intermediate value (e.g. a call
    // around a calculation), so always use the actual final local snapshot.
    final afterFrames = event['frames'] as List? ?? [];
    final matching = afterFrames
        .where((f) => frames.isNotEmpty && f['id'] == frames.last['id']);
    final after = matching.isEmpty ? {} : matching.first['locals'] as Map;
    final actual = SceneValue(
        scene.target,
        after[scene.target] ?? scene.result!.value,
        event['heap'] as Map? ?? {});
    beats.add(ProcessBeat(
        '赋值给 ${scene.target}',
        '将结果赋给 ${scene.target}，完成本行赋值',
        LearningScene(
            title: scene.title,
            kind: 'store',
            target: scene.target,
            inputs: [SceneValue('计算结果', actual.value, actual.heap)],
            result: actual,
            previous: locals.containsKey(scene.target)
                ? SceneValue(scene.target, locals[scene.target],
                    before['heap'] as Map? ?? {})
                : null)));
  } else if (scene.kind == 'calculation') {
    if (event['statement_type'] == 'Return' && scene.result != null) {
      beats.add(ProcessBeat(
          '返回',
          '将计算结果返回给调用方',
          LearningScene(
              title: scene.title, kind: 'return', result: scene.result)));
    }
  } else if (scene.kind == 'assignment' && scene.result != null) {
    beats.add(ProcessBeat(
        '赋值',
        '将此值赋给 ${scene.target}',
        LearningScene(
            title: scene.title,
            kind: 'store',
            target: scene.target,
            result: scene.result,
            previous: scene.previous,
            inputs: [
              SceneValue('待赋值的数据', scene.result!.value, scene.result!.heap)
            ])));
  } else {
    beats.add(ProcessBeat(
        switch (scene.kind) {
          'condition' => '选择执行路径',
          'output' => '显示',
          'function' => '接收返回值',
          'mutation' => '修改内容',
          'alias' => '建立关联',
          'return' => '返回',
          'definition' => '完成定义',
          _ => '完成'
        },
        switch (scene.kind) {
          'condition' => scene.nextLine == null
              ? '根据判断结果继续执行'
              : '根据判断结果，执行第 ${scene.nextLine} 行',
          'output' => '将内容输出到屏幕',
          'mutation' => '修改原容器的内容，绿色标出变化',
          'function' => '函数执行结束，接收其返回值',
          _ => scene.title
        },
        scene));
  }
  if (event['statement_type'] == 'Return' &&
      (beats.isEmpty || beats.last.scene.kind != 'return')) {
    final values = event['values'] as List? ?? [];
    if (values.isNotEmpty) {
      beats.add(ProcessBeat(
          '返回',
          '将本次调用的结果返回给调用方',
          LearningScene(
              title: scene.title,
              kind: 'return',
              result: SceneValue(
                  '本次返回', values.first, event['heap'] as Map? ?? {}))));
    }
  }
  return beats.isEmpty ? [ProcessBeat('完成', scene.title, scene)] : beats;
}
