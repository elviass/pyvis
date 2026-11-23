import 'pyvis_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'learning_scene.dart';
import 'runtime_value_view.dart';

class LearningSceneView extends StatefulWidget {
  final LearningScene scene;
  final int phase;
  final bool showTitle, paused;
  final double speed;
  const LearningSceneView(
      {super.key,
      required this.scene,
      required this.phase,
      this.showTitle = true,
      this.speed = 1,
      this.paused = false});
  @override
  State<LearningSceneView> createState() => _LearningSceneViewState();
}

class _LearningSceneViewState extends State<LearningSceneView>
    with SingleTickerProviderStateMixin {
  late final AnimationController motion;
  LearningScene get scene => widget.scene;
  int get phase => widget.phase;
  double get progress => motion.value;
  @override
  void initState() {
    super.initState();
    motion = AnimationController(
        vsync: this,
        duration: Duration(milliseconds: (850 / widget.speed).round()));
    if (!widget.paused) motion.forward();
  }

  @override
  void didUpdateWidget(covariant LearningSceneView old) {
    super.didUpdateWidget(old);
    motion.duration = Duration(milliseconds: (850 / widget.speed).round());
    if (widget.paused) {
      motion.stop();
    } else if (!motion.isCompleted) {
      motion.forward();
    }
  }

  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }

  static const green = Color(0xff93d1a1),
      blue = Color(0xffa5c7ff),
      muted = Color(0xff9b9fa8);

  Widget arrow([String? value]) => SizedBox(
      width: 105,
      height: 70,
      child: Stack(alignment: Alignment.center, children: [
        const Positioned(
            left: 0,
            right: 0,
            bottom: 12,
            child: Icon(Icons.arrow_forward_rounded, size: 30, color: blue)),
        if (value != null && value.isNotEmpty && progress < .98)
          Transform.translate(
              offset: Offset(-30 + 60 * progress, -10),
              child: Container(
                  constraints: const BoxConstraints(maxWidth: 95),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                      color: const Color(0xff3b5982),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: blue)),
                  child: Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16, color: Color(0xfff0f2f5)))))
      ]));
  Widget card(SceneValue value,
      {bool destination = false, bool reveal = true, String? label}) {
    final isList = value.value is Map &&
        value.value['ref'] != null &&
        (value.heap[value.value['ref']] as Map?)?['items'] is List;
    return AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        constraints:
            BoxConstraints(minWidth: 110, maxWidth: isList ? 300 : 240),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        decoration: BoxDecoration(
            color:
                destination ? const Color(0xff27372e) : const Color(0xff252b35),
            border: Border.all(
                color: destination ? green : const Color(0xff5b6a81),
                width: 1.5),
            borderRadius: BorderRadius.circular(12)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(label ?? value.label,
              style:
                  TextStyle(fontSize: 13, color: destination ? green : blue)),
          const SizedBox(height: 8),
          AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: reveal
                  ? RuntimeValueView(value: value)
                  : const Text('…',
                      key: ValueKey('waiting'),
                      style: TextStyle(fontSize: 27, color: muted))),
        ]));
  }

  Widget container(SceneValue value, {SceneValue? previous}) {
    return Container(
        width: 260,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: const Color(0xff242b2a),
            border: Border.all(color: previous == null ? blue : green),
            borderRadius: BorderRadius.circular(10)),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(value.label,
                  style: const TextStyle(fontSize: 13, color: blue)),
              const SizedBox(height: 8),
              RuntimeValueView(value: value, previous: previous),
            ]));
  }

  List<Widget> mathInputs() {
    final result = <Widget>[];
    for (var i = 0; i < scene.inputs.length; i++) {
      if (i > 0) {
        result.add(Text(
            scene.signs.length >= i && scene.signs[i - 1].isNotEmpty
                ? scene.signs[i - 1]
                : '',
            style: const TextStyle(fontSize: 30, color: blue)));
      }
      result.add(card(scene.inputs[i]));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: motion, builder: (context, _) => buildScene(context));

  Widget buildScene(BuildContext context) {
    final scene = this.scene;
    final result = scene.result;
    final nodes = <Widget>[];
    if (scene.kind == 'read') {
      nodes.addAll(scene.inputs.map((v) => card(v)));
      nodes.add(arrow(scene.inputs.map((v) => v.text).join('、')));
      nodes.add(card(
          SceneValue('取出的值', {
            'type': 'text',
            'value': scene.inputs.map((v) => v.text).join('、')
          }, const {}),
          destination: true,
          reveal: progress > .8));
    } else if (scene.kind == 'store') {
      if (scene.inputs.isNotEmpty) nodes.add(card(scene.inputs.first));
      nodes.add(arrow(result?.text));
      if (result != null) {
        nodes.add(card(
            progress > .8
                ? result
                : (scene.previous ??
                    SceneValue(scene.target, {'type': 'text', 'value': '空'},
                        const {})),
            destination: true,
            label: scene.target));
      }
    } else if (scene.kind == 'enter') {
      nodes.add(card(SceneValue('传来的值', {
        'type': 'text',
        'value': scene.inputs.isEmpty
            ? '不需要参数'
            : scene.inputs.map((v) => v.text).join('、')
      }, const {})));
      nodes.add(arrow(scene.inputs.map((v) => v.text).join('、')));
      nodes.add(Column(mainAxisSize: MainAxisSize.min, children: [
        Text('函数 ${scene.operation} 的参数', style: const TextStyle(color: blue)),
        const SizedBox(height: 8),
        Wrap(
            spacing: 8,
            runSpacing: 8,
            children: scene.inputs
                .map((v) => card(v, destination: true, reveal: progress > .8))
                .toList())
      ]));
    } else if (scene.kind == 'mutation') {
      if (scene.previous != null) nodes.add(container(scene.previous!));
      nodes.add(arrow());
      if (result != null) {
        nodes.add(container(progress > .8 ? result : (scene.previous ?? result),
            previous: scene.previous));
      }
    } else if (scene.kind == 'alias') {
      nodes.add(Column(
          mainAxisSize: MainAxisSize.min,
          children: scene.aliases
              .map((name) => Padding(
                  padding: const EdgeInsets.all(4),
                  child: Container(
                      width: 110,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                          border: Border.all(color: blue),
                          borderRadius: BorderRadius.circular(8)),
                      child: Text(name,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 18, color: blue)))))
              .toList()));
      nodes.add(arrow(result?.text));
      if (result != null) nodes.add(container(result));
    } else if (scene.kind == 'output') {
      if (result != null) {
        nodes.add(card(SceneValue('要显示的内容', result.value, result.heap)));
        nodes.add(arrow(result.text));
      }
      nodes.add(Container(
          constraints: const BoxConstraints(minWidth: 220, maxWidth: 700),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
              color: PyvisColors.canvas,
              border: Border.all(color: const Color(0xff5b6a81)),
              borderRadius: BorderRadius.circular(12)),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.desktop_windows_outlined, color: blue, size: 20),
                  SizedBox(width: 8),
                  Text('屏幕', style: TextStyle(color: muted, fontSize: 13))
                ]),
                const SizedBox(height: 15),
                Text(progress > .8 ? (result?.text ?? '') : '正在送到屏幕…',
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 16, color: Color(0xfff0f2f5)))
              ])));
    } else if (scene.kind == 'function') {
      nodes.addAll(scene.inputs.map((v) => card(v)));
      if (scene.inputs.isNotEmpty) nodes.add(arrow());
      nodes.add(Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
              color: const Color(0xff332e42),
              border: Border.all(color: const Color(0xffad9cdb)),
              borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            const Icon(Icons.functions, color: Color(0xffc9baef), size: 27),
            Text(scene.operation,
                style: const TextStyle(fontSize: 21, color: Color(0xffded4fa)))
          ])));
      if (result != null) {
        nodes.add(arrow(result.text));
        nodes.add(card(result,
            destination: true,
            reveal: phase > 0 && progress > .8,
            label: scene.target.isEmpty ? '返回的结果' : scene.target));
      }
    } else if (scene.kind == 'condition') {
      nodes.addAll(mathInputs());
      if (scene.inputs.isEmpty && scene.operation.isNotEmpty) {
        nodes.add(Text(scene.operation,
            style: const TextStyle(fontSize: 20, color: blue)));
      }
      if (result != null) {
        nodes.add(arrow());
        final raw = result.value;
        final boolean = raw is Map && raw['type'] == 'bool';
        nodes.add(Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
                color: boolean && raw['value'] == false
                    ? const Color(0xff49362b)
                    : const Color(0xff27372e),
                borderRadius: BorderRadius.circular(12)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(boolean && raw['value'] == false ? Icons.close : Icons.check,
                  color: green, size: 26),
              const SizedBox(width: 8),
              Text(
                  progress < .8
                      ? '判断中…'
                      : boolean
                          ? (raw['value'] == true ? '成立' : '不成立')
                          : result.text,
                  style:
                      const TextStyle(fontSize: 25, color: Color(0xffecf4ef)))
            ])));
      }
    } else if (scene.kind == 'calculation') {
      nodes.addAll(mathInputs());
      if (scene.inputs.isEmpty) {
        nodes.add(Text(scene.operation,
            style: const TextStyle(fontSize: 20, color: blue)));
      }
      if (result != null) {
        nodes.add(arrow(result.text));
        nodes.add(card(result,
            destination: true,
            reveal: phase > 0 && progress > .8,
            label: scene.target.isEmpty ? '结果' : scene.target));
      }
    } else if (scene.kind == 'assignment') {
      if (scene.previous != null) {
        nodes.add(card(scene.previous!));
        nodes.add(arrow());
      }
      if (result != null) nodes.add(container(result));
    } else if (scene.kind == 'error') {
      nodes.add(const Icon(Icons.pause_circle_outline,
          color: Color(0xffe7a2a2), size: 46));
      nodes.add(const Text('这一步没有完成\n先看下面的错误提示',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, color: Color(0xffe7a2a2))));
    } else {
      if (result != null) {
        nodes.add(card(result, destination: scene.kind == 'return'));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.showTitle)
        Text(scene.title,
            style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                height: 1.5,
                color: Color(0xffe7eaf0))),
      if (widget.showTitle) const SizedBox(height: 22),
      AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Wrap(
              key: ValueKey('${scene.kind}-${scene.target}'),
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 14,
              runSpacing: 14,
              children: nodes)),
      if (scene.kind == 'condition')
        Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Center(
                child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                        color: const Color(0xff263449),
                        borderRadius: BorderRadius.circular(8)),
                    child: Text(
                        scene.nextLine == null
                            ? '点击下一步，查看后续执行路径'
                            : '接下来 → 第 ${scene.nextLine} 行',
                        style: const TextStyle(fontSize: 16, color: blue))))),
      if (scene.kind == 'mutation')
        const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('绿色标出这一步发生的变化',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: green))),
      if (scene.writes.isNotEmpty)
        Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
                '本步赋值：${scene.writes.map((v) => "${v.label} = ${v.text}").join('，')}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, color: blue))),
      const SizedBox(height: 12),
    ]);
  }
}
