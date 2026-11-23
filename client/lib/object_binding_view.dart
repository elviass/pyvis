import 'package:material_ui/material_ui.dart';
import 'learning_scene.dart';
import 'runtime_value_view.dart';

bool hasRecordedStructure(SceneValue? value) {
  if (value == null || value.value is! Map) return false;
  final object = value.heap[value.value['ref']];
  return object is Map &&
      (object['entries'] is List ||
          object['items'] is List ||
          object['attributes'] is Map);
}

/// A mutable object is drawn once. Variable boxes refer to it instead of
/// displaying two identical copies of its contents.
class ObjectBindingView extends StatefulWidget {
  final LearningScene scene;
  final double speed;
  final bool paused;
  const ObjectBindingView(
      {super.key, required this.scene, this.speed = 1, this.paused = false});
  @override
  State<ObjectBindingView> createState() => _ObjectBindingViewState();
}

class _ObjectBindingViewState extends State<ObjectBindingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController motion;
  @override
  void initState() {
    super.initState();
    motion = AnimationController(
        vsync: this,
        duration: Duration(milliseconds: (850 / widget.speed).round()));
    if (!widget.paused) motion.forward();
  }

  @override
  void didUpdateWidget(covariant ObjectBindingView old) {
    super.didUpdateWidget(old);
    motion.duration = Duration(milliseconds: (850 / widget.speed).round());
    if (widget.paused) {
      motion.stop();
    } else {
      motion.forward();
    }
  }

  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }

  static const blue = Color(0xffa5c7ff), green = Color(0xff93d1a1);
  Widget field(String label, dynamic raw, Map heap) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
          color: const Color(0xff303840),
          borderRadius: BorderRadius.circular(5)),
      child: Text('$label: ${valueSummary(raw, heap)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: Color(0xffe3e7ed))));

  Widget object(SceneValue value) {
    final entries = valueEntries(value.value, value.heap);
    final old = widget.scene.previous;
    final previous = old == null
        ? <String, dynamic>{}
        : Map.fromEntries(
            valueEntries(old.value, old.heap).map((e) => MapEntry(e.$1, e.$2)));
    final heapObject = value.heap[value.value['ref']] as Map;
    final dictionary = heapObject['entries'] is List;
    final count = heapObject['length'] ?? entries.length;
    return Container(
        key: const ValueKey('recorded-object'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: const Color(0xff222d29),
            border: Border.all(color: green, width: 1.5),
            borderRadius: BorderRadius.circular(10)),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const Icon(Icons.data_object, color: green, size: 19),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(valueSummary(value.value, value.heap),
                        style: const TextStyle(
                            color: green,
                            fontSize: 14,
                            fontWeight: FontWeight.w600))),
                TextButton(
                    onPressed: () =>
                        RuntimeValueView(value: value).inspect(context),
                    child: const Text('展开全部', style: TextStyle(fontSize: 11)))
              ]),
              Row(children: [
                SizedBox(
                    width: 100,
                    child: Text(dictionary ? '键' : '索引 / 属性',
                        style: const TextStyle(color: blue, fontSize: 11))),
                const Expanded(
                    child:
                        Text('值', style: TextStyle(color: blue, fontSize: 11)))
              ]),
              const SizedBox(height: 6),
              if (entries.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('当前为空', style: TextStyle(fontSize: 13))),
              for (final entry in entries.take(5))
                Builder(builder: (context) {
                  final children = valueEntries(entry.$2, value.heap);
                  final changed = old != null &&
                      (!previous.containsKey(entry.$1) ||
                          plainValue(previous[entry.$1], old.heap) !=
                              plainValue(entry.$2, value.heap));
                  return Container(
                      margin: const EdgeInsets.only(bottom: 5),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                          color: changed
                              ? const Color(0xff365440)
                              : const Color(0xff28332f),
                          borderRadius: BorderRadius.circular(5)),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                                width: 92,
                                child: Text(entry.$1,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Color(0xffd7b98e),
                                        fontSize: 13))),
                            Expanded(
                                child: children.isEmpty
                                    ? Text(valueSummary(entry.$2, value.heap),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontFamily: 'JetBrains Mono',
                                            fontSize: 13))
                                    : Wrap(
                                        spacing: 5,
                                        runSpacing: 4,
                                        children: [
                                            for (final child
                                                in children.take(3))
                                              field(child.$1, child.$2,
                                                  value.heap),
                                            if (children.length > 3)
                                              Text(
                                                  '…另 ${children.length - 3} 项',
                                                  style: const TextStyle(
                                                      fontSize: 11))
                                          ]))
                          ]));
                }),
              if (count > 5)
                Text('另有 ${count - 5} 项，可展开查看',
                    style: const TextStyle(color: blue, fontSize: 11)),
              if (heapObject['truncated'] == true)
                const Text('仅显示运行时已记录的内容',
                    style: TextStyle(color: blue, fontSize: 11)),
              if (old != null)
                const Text('绿色背景表示本次变化',
                    style: TextStyle(color: green, fontSize: 11))
            ]));
  }

  @override
  Widget build(BuildContext context) {
    final scene = widget.scene;
    final result = scene.result!;
    final names = scene.aliases.isEmpty ? [scene.target] : scene.aliases;
    return AnimatedBuilder(
        animation: motion,
        builder: (context, _) => LayoutBuilder(builder: (context, size) {
              final compact = size.maxWidth < 580;
              final variables =
                  Column(mainAxisSize: MainAxisSize.min, children: [
                for (final name in names)
                  Container(
                      width: 154,
                      margin: const EdgeInsets.symmetric(vertical: 5),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                          color: const Color(0xff263345),
                          border: Border.all(color: blue),
                          borderRadius: BorderRadius.circular(9)),
                      child: Column(children: [
                        const Text('变量',
                            style: TextStyle(fontSize: 11, color: blue)),
                        const SizedBox(height: 4),
                        Text(name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontFamily: 'JetBrains Mono',
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text(
                            scene.kind == 'mutation'
                                ? '引用保持不变'
                                : motion.value < .8
                                    ? '正在建立引用…'
                                    : '已关联容器',
                            style: const TextStyle(fontSize: 10, color: blue))
                      ]))
              ]);
              if (compact) {
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(alignment: Alignment.centerLeft, child: variables),
                      const Padding(
                          padding: EdgeInsets.all(5),
                          child: Text('↓ 引用',
                              style: TextStyle(fontSize: 12, color: blue))),
                      object(result)
                    ]);
              }
              return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                        padding: const EdgeInsets.only(top: 48),
                        child: variables),
                    SizedBox(
                        width: 76,
                        height: 160,
                        child: Stack(alignment: Alignment.center, children: [
                          const Positioned(
                              top: 57,
                              child: Text('引用',
                                  style: TextStyle(fontSize: 11, color: blue))),
                          const Icon(Icons.arrow_right_alt,
                              size: 60, color: blue),
                          if (!motion.isCompleted)
                            Transform.translate(
                                offset: Offset(-22 + 44 * motion.value, 0),
                                child: Container(
                                    width: 7,
                                    height: 7,
                                    decoration: const BoxDecoration(
                                        color: green, shape: BoxShape.circle)))
                        ])),
                    Flexible(
                        child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 560),
                            child: object(result)))
                  ]);
            }));
  }
}
