import 'package:material_ui/material_ui.dart';
import 'learning_scene.dart';

String _functionKey(Map frame) =>
    '${frame['file']}:${frame['name']}:${frame['definition_line'] ?? ''}';

class Invocation {
  final int id, ordinal;
  final String name, arguments, status;
  final Map locals;
  final bool active;
  const Invocation(this.id, this.ordinal, this.name, this.arguments,
      this.status, this.locals, this.active);
}

class RecursionState {
  final List<Invocation> calls;
  final String? returning;
  const RecursionState(this.calls, this.returning);
}

RecursionState recursionState(Map event, List<Map<String, dynamic>> events) {
  final recursive = <String>{};
  for (final e in events.where((e) => e['kind'] == 'call')) {
    final fs = e['frames'] as List;
    if (fs.isEmpty) continue;
    final key = _functionKey(fs.last as Map);
    if (fs.take(fs.length - 1).any((f) => _functionKey(f as Map) == key)) {
      recursive.add(key);
    }
  }
  final seq = event['seq'] as int;
  final seen = events.take(seq + 1).toList();
  var frames = event['frames'] as List? ?? [];
  Map? returned;
  if (!frames.any((f) => recursive.contains(_functionKey(f as Map)))) {
    // A top-level assignment has already resumed. Only show a return belonging
    // to this very statement; never borrow the value of a later/sibling call.
    final start = event['start_seq'] as int? ?? seq;
    final returns = seen.where((e) =>
        e['kind'] == 'return' &&
        (e['seq'] as int) >= start &&
        (e['frames'] as List).isNotEmpty &&
        recursive.contains(_functionKey((e['frames'] as List).last as Map)));
    if (returns.isEmpty) return const RecursionState([], null);
    returned = returns.last;
    frames = returned['frames'] as List;
  }
  final heap = (returned ?? event)['heap'] as Map? ?? {};
  final active =
      frames.where((f) => recursive.contains(_functionKey(f as Map))).toList();
  final result = <Invocation>[];
  for (var i = 0; i < active.length; i++) {
    final frame = active[i] as Map;
    final id = frame['id'] as int;
    final calls = seen
        .where((e) =>
            e['kind'] == 'call' &&
            (e['frames'] as List).isNotEmpty &&
            _functionKey((e['frames'] as List).last as Map) ==
                _functionKey(frame))
        .toList();
    final ordinal =
        calls.indexWhere((e) => (e['frames'] as List).last['id'] == id) + 1;
    final entry = calls.where((e) => (e['frames'] as List).last['id'] == id);
    final args = entry.isEmpty
        ? frame['locals'] as Map
        : (entry.first['frames'] as List).last['locals'] as Map;
    final argHeap = entry.isEmpty ? heap : entry.first['heap'] as Map;
    final arguments = args.entries
        .map((e) => '${e.key}=${plainValue(e.value, argHeap)}')
        .join(', ');
    final isLast = i == active.length - 1;
    final values = (returned ?? event)['values'] as List? ?? [];
    final isReturning = isLast &&
        (returned != null ||
            event['statement_type'] == 'Return' ||
            event['kind'] == 'return');
    final status = isReturning && values.isNotEmpty
        ? '返回 ${plainValue(values.first, heap)}'
        : isLast
            ? '正在执行'
            : '暂停在第 ${frame['line']} 行，等待下一层返回';
    result.add(Invocation(id, ordinal, '${frame['name']}', arguments, status,
        frame['locals'] as Map, isLast));
  }
  String? returning;
  if (result.isNotEmpty && result.last.status.startsWith('返回 ')) {
    final allFrames = frames;
    final caller =
        allFrames.length > 1 ? allFrames[allFrames.length - 2] as Map : null;
    returning =
        '${result.last.status} → ${caller == null || caller['name'] == '<module>' ? '主程序' : caller['name']}的第 ${caller?['line'] ?? '?'} 行，接着完成剩余运算';
  }
  return RecursionState(result, returning);
}

class RecursionView extends StatelessWidget {
  final Map<String, dynamic> event;
  final List<Map<String, dynamic>> events;
  final Map sources;
  const RecursionView(
      {super.key,
      required this.event,
      required this.events,
      this.sources = const {}});
  @override
  Widget build(BuildContext context) {
    final state = recursionState(event, events);
    if (state.calls.isEmpty) return const SizedBox.shrink();
    final visible = state.calls.length > 6
        ? [...state.calls.take(2), ...state.calls.skip(state.calls.length - 4)]
        : state.calls;
    return Container(
        margin: const EdgeInsets.symmetric(vertical: 16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: const Color(0xff262331),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xff625578))),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('递归 · 每次调用都有自己的一份变量',
              style: TextStyle(fontSize: 14, color: Color(0xffd2bdf6))),
          const SizedBox(height: 10),
          for (var i = 0; i < visible.length; i++) ...[
            if (state.calls.length > 6 && i == 2)
              Text('中间还有 ${state.calls.length - 6} 层等待',
                  style: const TextStyle(fontSize: 12)),
            Padding(
                padding: EdgeInsets.only(left: i * 12.0, top: 5),
                child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                        color: visible[i].active
                            ? const Color(0xff3a334b)
                            : const Color(0xff2c2934),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                            color: visible[i].active
                                ? const Color(0xffba9fe5)
                                : const Color(0xff4a4357))),
                    child: Wrap(spacing: 14, runSpacing: 5, children: [
                      Text(
                          '第 ${visible[i].ordinal} 次 ${visible[i].name}(${visible[i].arguments})',
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xffe3d8f4))),
                      Text(visible[i].status,
                          style: TextStyle(
                              fontSize: 12,
                              color: visible[i].active
                                  ? const Color(0xff93d1a1)
                                  : const Color(0xffaba3b9)))
                    ])))
          ],
          if (state.returning != null)
            Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(state.returning!,
                    style: const TextStyle(
                        color: Color(0xff93d1a1), fontSize: 13)))
        ]));
  }
}
