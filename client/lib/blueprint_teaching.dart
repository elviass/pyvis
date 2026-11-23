import 'package:material_ui/material_ui.dart';

/// A reading guide for static code, without inventing execution results.
class BlueprintTeaching extends StatefulWidget {
  final Map lesson;
  final ValueChanged<Map> onStep;
  const BlueprintTeaching(
      {super.key, required this.lesson, required this.onStep});
  @override
  State<BlueprintTeaching> createState() => _BlueprintTeachingState();
}

class _BlueprintTeachingState extends State<BlueprintTeaching> {
  bool details = false;
  @override
  Widget build(BuildContext context) {
    final lesson = widget.lesson;
    final steps = (lesson['steps'] as List? ?? []).cast<Map>();
    final icon = switch (lesson['role']) {
      'repeat' => Icons.repeat,
      'check' => Icons.alt_route,
      'output' => Icons.monitor,
      'input' => Icons.keyboard,
      'error' || 'protect' => Icons.health_and_safety_outlined,
      'finish' => Icons.check_circle_outline,
      _ => Icons.lightbulb_outline,
    };
    return Container(
        key: const ValueKey('blueprint-teaching'),
        height: details ? 140 : 96,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        decoration: const BoxDecoration(
            color: Color(0xff242d39),
            border: Border(bottom: BorderSide(color: Color(0xff465971)))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: const Color(0xff8ed4f0), size: 21),
            const SizedBox(width: 9),
            Expanded(
                child: Text('${lesson['title'] ?? '当前步骤说明'}',
                    key: const ValueKey('teaching-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Color(0xffedf4ff)))),
            const SizedBox(width: 8),
            Text('第 ${lesson['line'] ?? 1} 行',
                style: const TextStyle(fontSize: 12, color: Color(0xffaebfd5))),
            SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                    key: const ValueKey('teaching-details'),
                    tooltip: details ? '收起说明' : '详细说明',
                    onPressed: () => setState(() => details = !details),
                    constraints:
                        const BoxConstraints.tightFor(width: 28, height: 28),
                    padding: EdgeInsets.zero,
                    icon: Icon(details ? Icons.expand_less : Icons.expand_more,
                        size: 18)))
          ]),
          if (details) const SizedBox(height: 7),
          if (details)
            SizedBox(
                height: 38,
                child: Text('${lesson['explanation'] ?? ''}',
                    key: const ValueKey('teaching-explanation'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, height: 1.3, color: Color(0xffd0dbe9)))),
          const Spacer(),
          SizedBox(
              height: 34,
              child: steps.isEmpty
                  ? const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('按箭头顺序阅读；点击节点查看对应操作的说明。',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xffaebfd5))))
                  : ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: steps.length,
                      separatorBuilder: (_, index) => const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 7),
                          child: Icon(Icons.arrow_forward,
                              size: 16, color: Color(0xff91a7c0))),
                      itemBuilder: (context, i) {
                        final step = steps[i],
                            repeat = step['kind'] == 'repeat';
                        return OutlinedButton(
                            key: ValueKey('teaching-step-$i'),
                            onPressed: () => widget.onStep(step),
                            style: OutlinedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 10),
                                side:
                                    const BorderSide(color: Color(0xff516985)),
                                foregroundColor: const Color(0xffe6effa)),
                            child:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              if (repeat)
                                const Icon(Icons.replay, size: 15)
                              else
                                Text('${i + 1}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xff8ed4f0))),
                              const SizedBox(width: 7),
                              Text('${step['label']}',
                                  style: const TextStyle(fontSize: 13))
                            ]));
                      }))
        ]));
  }
}

String plainNodeTitle(Map node) {
  final kind = node['kind'], title = '${node['title']}';
  return switch (kind) {
    'variable' =>
      '${node['symbol'] ?? title.split('：').first.replaceFirst('循环中的 ', '')}',
    'read' => '读取值',
    'write' => '赋值',
    'truth' => '判断真值',
    'value' => title == '比较结果' || title == '真值结果'
        ? '判断结果'
        : title == '运算结果'
            ? '计算结果'
            : title,
    'condition' => title == '条件选路' ? '选择分支' : title,
    'control' => title == '跳出循环'
        ? '退出循环'
        : title == '开始下一轮'
            ? '进入下一轮'
            : title,
    'join' => title == '分支汇合' ? '继续执行' : title,
    'format' => '格式化文本',
    'argument' => '传递参数',
    'receive' => '接收返回值',
    'call' => node['function'] == 'print'
        ? '输出到屏幕'
        : node['function'] == 'input'
            ? '读取输入'
            : title,
    _ => title,
  };
}

String plainNodeKind(Map node, String original) => switch (node['kind']) {
      'variable' => '${node['title']}'.startsWith('循环中的 ') ? '循环变量' : '路径结果',
      'symbol' => '变量',
      'reference' => '变量引用',
      'read' => '读取',
      'write' => '赋值',
      'literal' => node['literal_type'] == 'str'
          ? '字符串'
          : node['literal_type'] == 'bool'
              ? '布尔值'
              : '字面值',
      'operator' => const ['<', '≤', '>', '≥', '==', '≠', 'in', 'not in']
              .contains(node['title'])
          ? '比较'
          : '运算',
      'condition' => '条件判断',
      'value' => '结果',
      'argument' => '参数',
      'receive' => '返回值',
      _ => original,
    };

String explainGraphNode(Map node) {
  final name = node['symbol'] ?? node['title'];
  return switch (node['kind']) {
    'symbol' => '$name 是变量名。变量用于引用数据，后续代码可以通过该名称读取它的值。',
    'reference' => '此节点表示在当前位置使用变量 $name，不创建新变量。可通过“定位来源”查看对应的来源语句。',
    'variable' => '${node['title']}'.startsWith('循环中的 ')
        ? '$name 在第一轮使用初始值，后续轮次使用上一轮更新后的值。'
        : '此处使用实际执行的分支所产生的值，不会同时使用不同分支的结果。',
    'read' => '读取变量或指定位置的当前值，将其传给后续操作。',
    'write' => '将计算结果赋给 $name。赋值完成后，后续读取使用更新后的值。',
    'operator' => '对输入值执行 ${node['title']} 运算，并将计算结果传给后续操作。',
    'value' => '此节点表示前一步产生的结果，后续操作通过连线使用它。实际数值需运行后观察。',
    'truth' => '将条件解释为 True 或 False，用于判断条件是否成立。',
    'condition' => '根据条件判断结果选择下一步：成立时执行对应分支，不成立时执行另一分支。',
    'argument' => '将此值作为参数传入函数，供函数内部使用。',
    'receive' => '接收函数调用返回的结果，供后续代码使用。',
    'call' => '使用已准备的参数调用 ${node['function'] ?? '目标函数'}，将返回结果传给后续操作。',
    'control' => '${node['title']}'.contains('下一轮')
        ? '结束当前轮次，直接进入下一轮循环。'
        : '${node['title']}'.contains('循环')
            ? '退出当前循环，继续执行循环之后的代码。'
            : '按指定路径继续执行。',
    'join' => '选中的分支执行完成后，从此处继续执行后续代码。',
    'literal' => node['literal_type'] == 'bool'
        ? '布尔值用于表示判断结果：True 表示成立，False 表示不成立。'
        : '这是代码中直接写出的值，可作为后续操作的输入。',
    _ => '此操作对应第 ${node['line']} 行。连线表示它接收的数据、产生的结果或执行顺序。',
  };
}
