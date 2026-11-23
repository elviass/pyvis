import 'package:material_ui/material_ui.dart';
import 'learning_scene.dart';
import 'line_process.dart';
import 'runtime_value_view.dart';

/// The whole line stays on screen. Only the observed stage advances; future
/// values are concealed, including reads after a call with side effects.
class ProcessDiagram extends StatefulWidget {
  final List<ProcessBeat> beats;
  final int active;
  final double speed;
  final bool paused;
  final ValueChanged<int> onSelect;
  const ProcessDiagram(
      {super.key,
      required this.beats,
      required this.active,
      required this.onSelect,
      this.speed = 1,
      this.paused = false});
  @override
  State<ProcessDiagram> createState() => _ProcessDiagramState();
}

class _ProcessDiagramState extends State<ProcessDiagram>
    with SingleTickerProviderStateMixin {
  late final AnimationController motion;
  final scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    motion = AnimationController(
        vsync: this,
        duration: Duration(milliseconds: (850 / widget.speed).round()));
    if (!widget.paused) motion.forward();
    revealActive();
  }

  void revealActive() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !scroll.hasClients) return;
        final left = widget.active * 220.0;
        final right = left + 188;
        final viewport = scroll.position.viewportDimension;
        if (left < scroll.offset || right > scroll.offset + viewport) {
          scroll.animateTo(
              (left - (viewport - 188) / 2)
                  .clamp(0.0, scroll.position.maxScrollExtent),
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut);
        }
      });

  @override
  void didUpdateWidget(covariant ProcessDiagram old) {
    super.didUpdateWidget(old);
    motion.duration = Duration(milliseconds: (850 / widget.speed).round());
    if (old.active != widget.active) {
      motion.reset();
      revealActive();
    }
    if (widget.paused) {
      motion.stop();
    } else {
      motion.forward();
    }
  }

  @override
  void dispose() {
    motion.dispose();
    scroll.dispose();
    super.dispose();
  }

  static const blue = Color(0xffa5c7ff), green = Color(0xff93d1a1);
  Color typeColor(SceneValue value) =>
      switch (value.value is Map ? value.value['type'] : null) {
        'str' => const Color(0xffd5b789),
        'bool' => const Color(0xffc6a4e8),
        'list' || 'dict' || 'tuple' || 'set' => green,
        _ => blue
      };

  Widget value(SceneValue value, {bool changed = false}) => Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
          color: changed ? const Color(0xff263b2f) : const Color(0xff21262e),
          border: Border(left: BorderSide(color: typeColor(value), width: 3)),
          borderRadius: BorderRadius.circular(4)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(value.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: typeColor(value))),
        const SizedBox(height: 4),
        RuntimeValueView(value: value, compact: true)
      ]));

  List<Widget> content(LearningScene scene, bool started, bool complete) {
    if (!started) {
      return [
        Text(scene.operation.isNotEmpty ? scene.operation : scene.target,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: 'JetBrains Mono', fontSize: 13)),
        const SizedBox(height: 14),
        const Text('尚未执行',
            style: TextStyle(color: Color(0xff929baa), fontSize: 12))
      ];
    }
    final result = scene.result;
    if (scene.kind == 'store') {
      return [
        if (scene.previous != null)
          Text(
              '原值：${valueSummary(scene.previous!.value, scene.previous!.heap)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xff929baa), fontSize: 12))
        else
          const Text('原值：未定义',
              style: TextStyle(color: Color(0xff929baa), fontSize: 12)),
        if (result != null && complete)
          value(result, changed: true)
        else
          const Padding(padding: EdgeInsets.all(12), child: Text('空'))
      ];
    }
    if (scene.kind == 'mutation') {
      return [
        if (scene.previous != null)
          Text(
              '修改前：${valueSummary(scene.previous!.value, scene.previous!.heap)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        if (result != null && complete)
          RuntimeValueView(
              value: result, previous: scene.previous, compact: true)
      ];
    }
    return [
      for (var i = 0; i < scene.inputs.length && i < 3; i++) ...[
        if (i > 0 && scene.signs.length >= i)
          Center(
              child: Text(scene.signs[i - 1],
                  style: const TextStyle(color: blue))),
        value(scene.inputs[i])
      ],
      if (scene.inputs.length > 3)
        Text('另有 ${scene.inputs.length - 3} 个值，见详细过程',
            style: const TextStyle(fontSize: 11)),
      if (scene.operation.isNotEmpty && scene.inputs.isEmpty)
        Text(scene.operation, maxLines: 2, overflow: TextOverflow.ellipsis),
      if (result != null) ...[
        const Divider(),
        if (complete)
          value(result, changed: true)
        else
          const Text('正在计算…', style: TextStyle(color: blue, fontSize: 12))
      ],
      if (const ['condition', 'iteration'].contains(scene.kind) && complete)
        Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
                scene.nextLine == null
                    ? '等待后续执行记录'
                    : '选中路径 → 第 ${scene.nextLine} 行',
                style: const TextStyle(color: green, fontSize: 12)))
    ];
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: motion,
      builder: (context, _) => Scrollbar(
          controller: scroll,
          thumbVisibility: true,
          child: SingleChildScrollView(
              controller: scroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(bottom: 14, top: 4),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (var i = 0; i < widget.beats.length; i++) ...[
                  if (i > 0)
                    SizedBox(
                        width: 32,
                        height: 90,
                        child: Stack(alignment: Alignment.center, children: [
                          Icon(Icons.arrow_right_alt,
                              color: i <= widget.active
                                  ? blue
                                  : const Color(0xff454b56)),
                          if (i == widget.active && !motion.isCompleted)
                            Transform.translate(
                                offset: Offset(-10 + 20 * motion.value, 0),
                                child: Container(
                                    width: 6,
                                    height: 6,
                                    decoration: const BoxDecoration(
                                        color: blue, shape: BoxShape.circle)))
                        ])),
                  SizedBox(
                      width: 188,
                      child: Material(
                          color: i == widget.active
                              ? const Color(0xff283447)
                              : const Color(0xff252930),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: BorderSide(
                                  color: i == widget.active
                                      ? blue
                                      : const Color(0xff424955),
                                  width: i == widget.active ? 1.5 : 1)),
                          child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () => widget.onSelect(i),
                              child: Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Row(children: [
                                          Text('${i + 1}',
                                              style: const TextStyle(
                                                  color: blue, fontSize: 12)),
                                          const SizedBox(width: 7),
                                          Expanded(
                                              child: Text(widget.beats[i].label,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w600))),
                                          if (i < widget.active)
                                            const Icon(Icons.check,
                                                size: 14, color: green)
                                        ]),
                                        const SizedBox(height: 8),
                                        ...content(
                                            widget.beats[i].scene,
                                            i <= widget.active,
                                            i < widget.active ||
                                                motion.value >= .8)
                                      ])))))
                ]
              ]))));
}
