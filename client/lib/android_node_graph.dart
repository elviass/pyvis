import 'package:material_ui/material_ui.dart';
import 'blueprint_service.dart';
import 'comfy_blueprint_panel.dart';
import 'comfy_graph_canvas.dart';

/// One explicitly compiled snapshot, retained when the editor tab is shown.
class NodeCompilation extends ChangeNotifier {
  bool viewing = false, busy = false;
  Map? graph;
  String? source, error;
  int? requestedLine;
  BlueprintService? _worker;

  void open(int? line) {
    viewing = true;
    requestedLine = line;
    notifyListeners();
  }

  void close() {
    viewing = false;
    notifyListeners();
  }

  Future<void> compile(String input) async {
    if (busy) return;
    busy = true;
    error = null;
    final worker = _worker = BlueprintService();
    notifyListeners();
    try {
      final result = await worker.parse(input, mode: 'nodes');
      if (_worker != worker) return;
      final problem = result['error'];
      if (problem is Map) {
        final line = problem['line'];
        error = '${line == null ? "" : "第 $line 行："}${problem["message"]}';
      } else {
        graph = result['graph'] as Map;
        source = input;
      }
    } catch (e) {
      if (_worker == worker) error = e.toString();
    } finally {
      if (_worker == worker) {
        _worker = null;
        worker.dispose();
        busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _worker?.dispose();
    _worker = null;
    super.dispose();
  }
}

class AndroidNodeGraph extends StatelessWidget {
  final NodeCompilation compilation;
  final String source, filename;
  final ValueChanged<int> onLine;
  final GraphCanvasBuilder? canvasBuilder;
  final Map<String, Offset> positions;
  const AndroidNodeGraph(
      {super.key,
      required this.compilation,
      required this.source,
      required this.filename,
      required this.onLine,
      required this.positions,
      this.canvasBuilder});

  @override
  Widget build(BuildContext context) {
    final graph = compilation.graph;
    final stale = graph != null && compilation.source != source;
    final message = compilation.busy
        ? '正在编译节点图…'
        : compilation.error != null
            ? '编译失败：${compilation.error}'
            : stale
                ? '源码已修改，当前显示上次编译的节点图'
                : graph == null
                    ? '尚未编译节点图'
                    : '已编译';
    return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) compilation.close();
        },
        child: Column(children: [
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(children: [
                Expanded(
                    child: Semantics(liveRegion: true, child: Text(message))),
                TextButton.icon(
                    onPressed: compilation.busy
                        ? null
                        : () => compilation.compile(source),
                    icon: const Icon(Icons.build_outlined, size: 16),
                    label: Text(graph == null ? '编译节点图' : '重新编译')),
              ])),
          if (compilation.busy)
            const LinearProgressIndicator(semanticsLabel: '正在编译节点图'),
          Expanded(
              child: graph == null
                  ? Center(
                      child: TextButton(
                          onPressed: compilation.close,
                          child: const Text('返回代码概览')))
                  : ComfyBlueprintPanel(
                      source: compilation.source!,
                      filename: filename,
                      compiledGraph: graph,
                      startAtLine: compilation.requestedLine != null,
                      activeLine: compilation.requestedLine,
                      closeNodes: compilation.close,
                      layoutPositions: positions,
                      canvasBuilder: canvasBuilder,
                      onLineSelected: (line) {
                        if (!stale) onLine(line);
                      })),
        ]));
  }
}
