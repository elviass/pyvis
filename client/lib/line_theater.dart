import 'pyvis_theme.dart';
import 'dart:async';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:material_ui/material_ui.dart';
import 'execution_flow.dart';
import 'learning_scene.dart';
import 'line_process.dart';
import 'recursion_view.dart';
import 'process_diagram.dart';
import 'object_binding_view.dart';
import 'runtime_value_view.dart';

class _ValueChange {
  final SceneValue value;
  final SceneValue? previous;
  const _ValueChange(this.value, this.previous);
}

List<_ValueChange> _writes(Map event) {
  final before = event['before'] as Map? ?? {};
  final frames = before['frames'] as List? ?? [];
  final changes = <_ValueChange>[];
  if (frames.isEmpty) return changes;
  final oldFrame = frames.last as Map;
  final after = (event['frames'] as List? ?? [])
      .where((frame) => frame['id'] == oldFrame['id'])
      .firstOrNull as Map?;
  if (after == null) return changes;
  final old = oldFrame['locals'] as Map, current = after['locals'] as Map;
  final oldHeap = before['heap'] as Map? ?? {};
  final heap = event['heap'] as Map? ?? {};
  final names = <String>{
    if (event['outcome'] != 'exception')
      ...(event['assigned_names'] as List? ?? []).whereType<String>(),
    for (final name in {...old.keys, ...current.keys}.whereType<String>())
      if (!mapEquals(old[name] as Map?, current[name] as Map?)) name,
  };
  for (final name in names) {
    if (!old.containsKey(name) && !current.containsKey(name)) continue;
    changes.add(_ValueChange(
        current.containsKey(name)
            ? SceneValue(name, current[name], heap)
            : SceneValue(name, const {'type': 'text', 'value': '已移除'}, heap),
        old.containsKey(name) ? SceneValue(name, old[name], oldHeap) : null));
  }
  return changes;
}

class LineTheater extends StatefulWidget {
  final Map<String, dynamic> event;
  final List<Map<String, dynamic>> events;
  final double speed;
  final bool externalPaused;
  final Map sources;
  final bool finished, startWithDetails;
  final VoidCallback? onInteraction;
  const LineTheater(
      {super.key,
      required this.event,
      required this.events,
      this.speed = 1,
      this.externalPaused = false,
      this.sources = const {},
      this.finished = true,
      this.startWithDetails = false,
      this.onInteraction});
  @override
  State<LineTheater> createState() => _LineTheaterState();
}

class _LineTheaterState extends State<LineTheater> {
  int phase = 0;
  bool paused = false;
  late bool showDetails;
  Timer? timer;
  List<ProcessBeat> get beats => lineBeats(widget.event, widget.events);
  @override
  void initState() {
    super.initState();
    showDetails = widget.startWithDetails;
    start();
  }

  @override
  void didUpdateWidget(covariant LineTheater old) {
    super.didUpdateWidget(old);
    if (!identical(old.event, widget.event) ||
        old.startWithDetails != widget.startWithDetails) {
      phase = 0;
      paused = false;
      showDetails = widget.startWithDetails;
      start();
    } else if (old.speed != widget.speed) {
      start();
    }
  }

  void start() {
    timer?.cancel();
    if (!showDetails || beats.length < 2) return;
    timer = Timer.periodic(
        Duration(milliseconds: (1200 / widget.speed).round()), (_) {
      if (paused || widget.externalPaused) {
        return;
      }
      if (phase >= beats.length - 1) {
        timer?.cancel();
        return;
      }
      if (mounted) setState(() => phase++);
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isCall = widget.event['kind'] == 'call';
    final frames = widget.event['frames'] as List? ?? [];
    final current = frames.lastOrNull;
    final recursive = current != null &&
        frames
                .where((f) =>
                    f['file'] == current['file'] &&
                    f['name'] == current['name'] &&
                    f['definition_line'] == current['definition_line'])
                .length >
            1;
    final location = isCall ? '函数调用' : '第 ${widget.event['line']} 行';
    final scene =
        isCall ? beats.first.scene : learningScene(widget.event, widget.events);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
            child: Text(
                recursive ? '$location · 调用深度 ${frames.length - 1}' : location,
                style:
                    const TextStyle(fontSize: 12, color: Color(0xffa9b1bf)))),
        TextButton(
            onPressed: () {
              widget.onInteraction?.call();
              setState(() {
                showDetails = !showDetails;
                phase = 0;
                paused = false;
              });
              start();
            },
            child: Text(showDetails ? '返回本步结果' : '查看行内过程')),
        if (showDetails) ...[
          IconButton(
              tooltip: paused ? '播放本行演示' : '暂停本行演示',
              onPressed: () {
                widget.onInteraction?.call();
                setState(() => paused = !paused);
                if (!paused) start();
              },
              icon: Icon(paused ? Icons.play_arrow : Icons.pause, size: 18)),
          IconButton(
              tooltip: '重播这一行',
              onPressed: () {
                widget.onInteraction?.call();
                setState(() {
                  phase = 0;
                  paused = false;
                });
                start();
              },
              icon: const Icon(Icons.replay, size: 18)),
        ],
      ]),
      if (showDetails)
        processView(scene)
      else
        _StepResult(
            scene: scene,
            event: widget.event,
            events: widget.events,
            sources: widget.sources,
            finished: widget.finished),
    ]);
  }

  Widget processView(LearningScene scene) {
    final process = beats;
    final active = phase.clamp(0, process.length - 1);
    final binding = process.length == 1 &&
        hasRecordedStructure(process[active].scene.result) &&
        const ['store', 'alias', 'mutation']
            .contains(process[active].scene.kind);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(
          widget.event['kind'] == 'call'
              ? process[active].scene.title
              : scene.title,
          key: const ValueKey('plain-explanation'),
          style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              height: 1.5,
              color: Color(0xffe7eaf0))),
      if (!binding) ...[
        const SizedBox(height: 6),
        Text('${widget.event['code'] ?? ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontFamily: 'JetBrains Mono',
                fontSize: 12,
                color: Color(0xffaeb6c2))),
        const SizedBox(height: 10),
        Text(process[active].caption,
            key: const ValueKey('process-caption'),
            style: const TextStyle(fontSize: 14, color: Color(0xffa5c7ff))),
      ],
      const SizedBox(height: 12),
      if (binding)
        ObjectBindingView(
            key: ValueKey('${widget.event['seq']}-$active-binding'),
            scene: process[active].scene,
            speed: widget.speed,
            paused: paused || widget.externalPaused)
      else
        ProcessDiagram(
            key: ValueKey(widget.event['seq']),
            beats: process,
            active: active,
            speed: widget.speed,
            paused: paused || widget.externalPaused,
            onSelect: (index) {
              widget.onInteraction?.call();
              setState(() {
                phase = index;
                paused = false;
              });
              start();
            }),
      RecursionView(
          event: widget.event, events: widget.events, sources: widget.sources),
    ]);
  }
}

class _StepResult extends StatelessWidget {
  final LearningScene scene;
  final Map<String, dynamic> event;
  final List<Map<String, dynamic>> events;
  final Map sources;
  final bool finished;

  const _StepResult(
      {required this.scene,
      required this.event,
      required this.events,
      required this.sources,
      required this.finished});

  static const blue = Color(0xffa5c7ff), muted = Color(0xffa9b1bf);

  @override
  Widget build(BuildContext context) {
    final type = event['statement_type'];
    final result = scene.result;
    final showInputs = const [
      'enter',
      'iteration',
      'condition',
      'calculation',
      'input'
    ].contains(scene.kind);
    final writes = const ['iteration', 'alias', 'enter'].contains(scene.kind)
        ? <_ValueChange>[]
        : _writes(event);
    final showResult = result != null &&
        scene.kind != 'plain' &&
        (writes.isEmpty ||
            const ['condition', 'mutation', 'return', 'output']
                .contains(scene.kind) ||
            event['statement_type'] == 'Return');
    final code = '${event['code'] ?? ''}'.trim();
    final line = event['line'] as int?;
    final next = scene.nextLine ?? event['next_line'] as int?;
    String? route;
    if (type == 'Return') {
      final flow = executionFlow(event, events, sources, finished: finished);
      if (flow.transition == '返回调用处' && flow.next?.line != null) {
        route = '返回到第 ${flow.next!.line} 行的调用处';
      }
    } else if (scene.kind != 'error' && next != null) {
      if (event['kind'] == 'call' ||
          scene.kind == 'condition' ||
          scene.kind == 'iteration' ||
          type == 'Break' ||
          type == 'Continue' ||
          (line != null && next <= line)) {
        route = next < (line ?? next) ? '回到第 $next 行' : '接着执行第 $next 行';
      }
    }
    if (scene.kind == 'enter' && route == null) {
      final entry = executionFlow(event, events, sources, finished: finished);
      if (entry.next?.line != null) route = '从第 ${entry.next!.line} 行开始执行函数体';
    }
    final recordedException =
        scene.kind == 'error' && (event['seq'] as int) + 1 < events.length
            ? events[(event['seq'] as int) + 1]
            : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(scene.title,
          key: const ValueKey('plain-explanation'),
          style: const TextStyle(
              fontSize: 17, fontWeight: FontWeight.w600, height: 1.4)),
      if (code.isNotEmpty)
        Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 7),
            child: Text(code,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontFamily: 'JetBrains Mono', color: muted, fontSize: 12))),
      if (recordedException?['kind'] == 'exception')
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
                '${recordedException!['exception_type']} · ${recordedException['message']}',
                style:
                    const TextStyle(fontSize: 13, color: Color(0xffeba6a6)))),
      if (showInputs && scene.inputs.isNotEmpty)
        Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 5,
            children: [
              for (var i = 0; i < scene.inputs.length && i < 3; i++) ...[
                if (i > 0 && i - 1 < scene.signs.length)
                  Text(scene.signs[i - 1], style: const TextStyle(color: blue)),
                _operand(scene.inputs[i])
              ],
              if (scene.inputs.length > 3)
                Text('另有 ${scene.inputs.length - 3} 个值',
                    style: const TextStyle(color: muted, fontSize: 12))
            ]),
      for (final write in writes.take(3))
        _value(write.value, previous: write.previous),
      if (writes.length > 3)
        ExpansionTile(
            title: Text('其他 ${writes.length - 3} 个赋值',
                style: const TextStyle(fontSize: 12)),
            children: [
              for (final write in writes.skip(3))
                _value(write.value, previous: write.previous)
            ]),
      if (showResult)
        _value(result,
            previous: scene.previous,
            label: scene.kind == 'mutation'
                ? scene.target
                : scene.kind == 'alias'
                    ? scene.aliases.join('、')
                    : null),
      if (route != null)
        Padding(
            padding: const EdgeInsets.only(top: 7),
            child:
                Text(route, style: const TextStyle(color: blue, fontSize: 13)))
    ]);
  }

  Widget _operand(SceneValue value) => Container(
      constraints: const BoxConstraints(maxWidth: 250),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5), color: PyvisColors.surface),
      child: Text('${value.label}  →  ${valueSummary(value.value, value.heap)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: blue)));

  Widget _value(SceneValue value, {SceneValue? previous, String? label}) {
    final before =
        previous == null ? null : valueSummary(previous.value, previous.heap);
    final color = pyvisTypeColor(
        value.value is Map ? value.value['type'] as String? : null);
    return Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 450),
            child: Container(
                margin: const EdgeInsets.only(top: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: PyvisColors.border),
                    color: PyvisColors.raised),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label ?? value.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: color, fontSize: 13)),
                      if (before != null && !hasRecordedStructure(value))
                        Text('原来 $before',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: muted, fontSize: 11)),
                      RuntimeValueView(
                          value: value, previous: previous, compact: true)
                    ]))));
  }
}
