import 'ide_chrome.dart';
import 'pyvis_theme.dart';
import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'blueprint_service.dart';
import 'blueprint_flow_layout.dart';
import 'comfy_graph_canvas.dart';
import 'reading_flow_view.dart';
import 'reading_flow_trace.dart';

/// Python owns the graph's semantics; LiteGraph owns canvas rendering and gestures.
class ComfyBlueprintPanel extends StatefulWidget {
  final String source, filename;
  final ValueChanged<int?>? openNodes;
  final Map? compiledGraph;
  final VoidCallback? closeNodes;
  final bool startAtLine;
  final int? activeLine;
  final ReadingTrace? trace;
  final VoidCallback? onReplay;
  final bool showFilename;
  final ValueChanged<int> onLineSelected;
  final Map<String, Offset>? layoutPositions;
  final GraphCanvasBuilder? canvasBuilder;
  const ComfyBlueprintPanel(
      {super.key,
      required this.source,
      required this.filename,
      required this.onLineSelected,
      this.activeLine,
      this.trace,
      this.openNodes,
      this.compiledGraph,
      this.closeNodes,
      this.startAtLine = false,
      this.onReplay,
      this.showFilename = false,
      this.layoutPositions,
      this.canvasBuilder});
  @override
  State<ComfyBlueprintPanel> createState() => _ComfyBlueprintPanelState();
}

class _ComfyBlueprintPanelState extends State<ComfyBlueprintPanel> {
  final parser = BlueprintService();
  final parsedSources = <String, Map>{};
  final folded = <String, Set<String>>{};
  late Map<String, Offset> positions;
  Map? graph, parseError;
  String? canvasError, group, selectedSection, selectedNode, detailId;
  String scope = 'main', graphSource = '';
  String rendererStatus = '加载画布…';
  int canvasGeneration = 0;
  bool lineMode = false, full = false, busy = true, showNodes = false;
  bool showIntermediate = false;
  int revision = 0, renderRevision = 0;
  int? line, sentLine;
  Timer? timer;
  Map<String, dynamic>? cachedScene;
  Map<String, dynamic>? displayedScene;
  final pendingLines = <Map>{};
  FlowSlice? currentSlice;
  List<Map> currentSections = [];

  @override
  void initState() {
    super.initState();
    positions = widget.layoutPositions ?? {};
    line = widget.activeLine;
    if (widget.compiledGraph != null) {
      showNodes = true;
      lineMode = widget.startAtLine;
      busy = false;
      install(widget.compiledGraph!, widget.source);
    } else {
      schedule();
    }
  }

  @override
  void didUpdateWidget(covariant ComfyBlueprintPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.compiledGraph != null) {
      if (!identical(widget.compiledGraph, oldWidget.compiledGraph)) {
        rendererStatus = '绘制中…';
        install(widget.compiledGraph!, widget.source);
      }
      return;
    }
    if (oldWidget.filename != widget.filename) {
      graph = null;
      parseError = null;
      canvasError = null;
      rendererStatus = '加载画布…';
      line = widget.activeLine;
      positions = widget.layoutPositions ?? {};
      scope = 'main';
      group = selectedSection = selectedNode = detailId = null;
      cachedScene = null;
      displayedScene = null;
    }
    if (widget.source != oldWidget.source ||
        widget.filename != oldWidget.filename) {
      schedule();
    }
    if (widget.trace != null &&
        !identical(widget.trace!.recording, oldWidget.trace?.recording)) {
      showNodes = false;
    }
    if (oldWidget.activeLine != widget.activeLine) {
      final ownSelection = sentLine == widget.activeLine;
      sentLine = null;
      line = widget.activeLine;
      if (!ownSelection) {
        group = selectedSection = selectedNode = detailId = null;
        locateScope();
        invalidate();
      }
    }
  }

  void invalidate() {
    cachedScene = null;
    renderRevision++;
  }

  void locateScope() {
    if (graph == null || line == null) return;
    final candidates = (graph!['line_views'] as List? ?? [])
        .cast<Map>()
        .where((v) => v['line'] == line)
        .toList()
      ..sort((a, b) => '${b['scope']}'
          .split('/')
          .length
          .compareTo('${a['scope']}'.split('/').length));
    if (candidates.isNotEmpty) scope = '${candidates.first['scope']}';
  }

  void schedule() {
    final token = ++revision;
    timer?.cancel();
    final source = widget.source;
    final cached = parsedSources.remove(source);
    if (cached != null) {
      parsedSources[source] = cached;
      busy = false;
      parseError = null;
      install(cached, source);
      return;
    }
    busy = true;
    timer = Timer(
        widget.trace == null
            ? const Duration(milliseconds: 350)
            : Duration.zero, () async {
      try {
        final result = await parser.parse(source,
            mode: widget.openNodes == null ? 'interactive' : 'overview');
        if (!mounted || token != revision) return;
        setState(() {
          busy = false;
          parseError = result['error'] as Map?;
          if (result['graph'] != null) {
            final parsed = result['graph'] as Map;
            parsedSources[source] = parsed;
            if (parsedSources.length > 8) {
              parsedSources.remove(parsedSources.keys.first);
            }
            install(parsed, source);
          }
        });
      } catch (error) {
        if (!mounted || token != revision) return;
        setState(() {
          busy = false;
          parseError = {'message': '$error'};
        });
      }
    });
  }

  void install(Map parsed, String source) {
    graph = parsed;
    graphSource = source;
    if (!(parsed['scopes'] as List? ?? []).any((s) => s['id'] == scope)) {
      scope = 'main';
      group = null;
    }
    locateScope();
    selectedNode = detailId = null;
    invalidate();
  }

  List<Map> get lines => (graph?['line_views'] as List? ?? [])
      .cast<Map>()
      .where((v) => v['scope'] == scope)
      .toList();
  Map? get whole => (graph?['whole_views'] as List? ?? [])
      .cast<Map>()
      .where((v) => v['scope'] == scope)
      .firstOrNull;

  Map? get lineView {
    final available = lines;
    return available.where((view) => view['line'] == line).firstOrNull ??
        available.firstOrNull;
  }

  Future<void> loadLineView(Map view, String source) async {
    try {
      final response = await parser.lineView(
          source, view['scope'] as String, view['line'] as int);
      if (response['graph'] is! Map) {
        throw StateError(response['error']?['message'] ?? '无法解析该行节点图');
      }
      view.addAll(response['graph'] as Map);
      if (mounted && identical(lineView, view)) setState(invalidate);
    } catch (error) {
      view['loadError'] = '$error';
      if (mounted && identical(lineView, view)) setState(() {});
    } finally {
      pendingLines.remove(view);
    }
  }

  Map<String, dynamic> scene() {
    if (cachedScene != null) return cachedScene!;
    final view = lineMode ? lineView : whole;
    var nodes = (view?['nodes'] as List? ?? []).cast<Map>();
    currentSections = (view?['sections'] as List? ?? []).cast<Map>();
    final target = selectedSection ??
        nodes.where((n) => n['line'] == line).firstOrNull?['section_id'];
    currentSlice = !lineMode && !full && view?['flow_tree'] is Map
        ? focusFlow(view!, target as String?, group)
        : null;
    if (currentSlice != null) {
      nodes = currentSlice!.nodes;
      currentSections = currentSlice!.sections;
    }
    final foldSet = folded.putIfAbsent(
        '${widget.filename}|$scope',
        () => {
              for (final s in (whole?['sections'] as List? ?? []).cast<Map>())
                sectionFoldKey(s)
            });
    final occurrences = <String, int>{};
    final keyed = [
      for (final n in nodes)
        {
          ...n,
          'layout_key': (() {
            final base = '$scope:${n['line']}:${n['kind']}:${n['code']}';
            final index =
                occurrences.update(base, (v) => v + 1, ifAbsent: () => 0);
            return '$base:$index';
          })()
        }
    ];
    final prefix = '$scope|${lineMode ? 'line' : 'whole'}|';
    final context = currentSlice?.groupId ?? (full ? '@full' : '@root');
    final density = showIntermediate ? 'detail' : 'compact';
    final shapes = graph?['collections'] as Map? ?? {};
    final collections = <String, Map>{};
    void includeCollection(Object? id) {
      if (id is! String || collections.containsKey(id)) return;
      final shape = shapes[id] as Map?;
      if (shape == null) return;
      collections[id] = shape;
      for (final row in (shape['rows'] as List).cast<Map>()) {
        includeCollection(row['collection']);
      }
    }

    for (final node in nodes) {
      includeCollection(node['collection_id'] ?? node['id']);
    }
    return cachedScene = {
      'revision': renderRevision,
      if (widget.compiledGraph != null) 'manualCamera': true,
      'key':
          '${widget.filename}|$scope|${lineMode ? 'line:$line' : context}|${detailId ?? ''}|$density',
      'compactNodes': !showIntermediate,
      'nodes': keyed,
      'collections': collections,
      'edges': view?['edges'] ?? [],
      'sections': currentSections,
      'section_links': currentSlice?.links ?? view?['section_links'] ?? [],
      'tree': currentSlice?.tree ?? view?['flow_tree'],
      'folded': [
        for (final s in currentSections)
          if (foldSet.contains(sectionFoldKey(s))) s['id']
      ],
      'positions': {
        for (final entry in positions.entries)
          if (entry.key.startsWith(prefix))
            entry.key.substring(prefix.length): [entry.value.dx, entry.value.dy]
      },
      'activeLine': line,
      'focusId': selectedNode ?? (detailId == null ? target : null),
      'detailId': detailId,
      'reveal': true
    };
  }

  void notifyLine(int? value) {
    if (value == null || graphSource != widget.source) return;
    sentLine = value;
    widget.onLineSelected(value);
  }

  void onEvent(Map event) {
    if (!mounted) return;
    final action = event['action'];
    if (action == 'layout') {
      final prefix = '$scope|${lineMode ? 'line' : 'whole'}|';
      for (final entry in (event['positions'] as Map? ?? {}).entries) {
        final p = entry.value as List;
        positions['$prefix${entry.key}'] =
            Offset((p[0] as num).toDouble(), (p[1] as num).toDouble());
      }
      return;
    }
    if (action == 'loading') {
      setState(() {
        canvasError = null;
        rendererStatus = '绘制中…';
      });
      return;
    }
    if (action == 'rendered') {
      setState(() {
        canvasError = null;
        rendererStatus = '${(event['nodes'] as num).toInt()} 个节点';
      });
      return;
    }
    if (action == 'select') {
      selectedNode = event['id'] as String?;
      line = (event['line'] as num?)?.toInt();
      notifyLine(line);
      return;
    }
    if (action == 'source') {
      line = (event['line'] as num?)?.toInt();
      group = selectedSection = selectedNode = detailId = null;
      locateScope();
      notifyLine(line);
    }
    if (action == 'error') {
      setState(() {
        canvasError = '${event['message']}';
        rendererStatus = '画布出错';
      });
      return;
    }
    setState(() {
      if (action == 'detail' && !lineMode) {
        detailId = event['id'] as String?;
        selectedSection = event['section'] as String?;
        selectedNode = null;
        line = (event['line'] as num?)?.toInt();
        notifyLine(line);
      }
      if (action == 'enter') {
        detailId = null;
        group = event['group'] as String?;
        selectedSection = event['id'] as String?;
        selectedNode = null;
        line = (event['line'] as num?)?.toInt();
        full = false;
        notifyLine(line);
      }
      if (action == 'fold') {
        final section =
            currentSections.where((s) => s['id'] == event['id']).firstOrNull;
        if (section != null) {
          final set = folded['${widget.filename}|$scope']!;
          final key = sectionFoldKey(section);
          if (!set.add(key)) set.remove(key);
          selectedSection = '${section['id']}';
          selectedNode = null;
          line = section['line'] as int;
          notifyLine(line);
        }
      }
      if (action == 'expandAll' || action == 'collapseAll') {
        final set = folded['${widget.filename}|$scope']!;
        for (final s in currentSections) {
          if (action == 'expandAll') {
            set.remove(sectionFoldKey(s));
          } else {
            set.add(sectionFoldKey(s));
          }
        }
      }
      if (action == 'reset') positions.clear();
      if (action == 'call') {
        final edge = (graph?['edges'] as List? ?? [])
            .cast<Map>()
            .where((e) => e['kind'] == 'call' && e['from'] == event['id'])
            .firstOrNull;
        final destination = (graph?['nodes'] as List? ?? [])
            .cast<Map>()
            .where((n) => n['id'] == edge?['to'])
            .firstOrNull;
        if (destination != null) {
          scope = '${destination['scope']}';
          line = destination['line'] as int;
          group = selectedSection = selectedNode = detailId = null;
          notifyLine(line);
        }
      }
      invalidate();
    });
  }

  @override
  void dispose() {
    revision++;
    timer?.cancel();
    parser.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedLine = showNodes && lineMode ? lineView : null;
    final waitingForLine =
        selectedLine != null && !selectedLine.containsKey('nodes');
    if (waitingForLine &&
        !selectedLine.containsKey('loadError') &&
        pendingLines.add(selectedLine)) {
      final source = graphSource;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) loadLineView(selectedLine, source);
      });
    }
    final data = graph == null || !showNodes
        ? null
        : waitingForLine
            ? displayedScene
            : displayedScene = scene();
    final lineError =
        waitingForLine ? selectedLine['loadError'] as String? : null;
    final reading = (graph?['reading'] as List? ?? []).cast<Map>();
    final scopes = (graph?['scopes'] as List? ?? []).cast<Map>();
    final filename = widget.filename.split(RegExp(r'[/\\]')).last;
    final mac = Theme.of(context).platform == TargetPlatform.macOS;
    return Column(children: [
      Container(
          width: mac ? double.infinity : null,
          decoration: BoxDecoration(
              color: mac ? PyvisColors.background : PyvisColors.surface,
              border: mac
                  ? const Border(bottom: BorderSide(color: PyvisColors.border))
                  : null),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                if (!showNodes)
                  const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Text('代码概览',
                          style: TextStyle(fontWeight: FontWeight.w600))),
                TextButton.icon(
                    onPressed: widget.closeNodes ??
                        (widget.openNodes != null
                            ? () => widget.openNodes!(null)
                            : () => setState(() => showNodes = !showNodes)),
                    icon: Icon(
                        showNodes
                            ? Icons.arrow_back
                            : Icons.account_tree_outlined,
                        size: 16),
                    label: Text(showNodes ? '返回代码概览' : '节点图')),
                if (showNodes) ...[
                  if (detailId != null)
                    TextButton.icon(
                        key: const ValueKey('comfy-collection-parent'),
                        icon: const Icon(Icons.arrow_back, size: 18),
                        label: const Text('返回集合'),
                        onPressed: () => setState(() {
                              selectedNode = detailId;
                              detailId = null;
                              invalidate();
                            }))
                  else if (currentSlice?.groupId != null && !lineMode)
                    IconButton(
                        key: const ValueKey('comfy-parent'),
                        tooltip: '返回上层流程',
                        icon: const Icon(Icons.arrow_back, size: 18),
                        onPressed: () => setState(() {
                              group = currentSlice!.parentId ?? '@root';
                              selectedSection = currentSlice!.headerId;
                              selectedNode = null;
                              invalidate();
                            })),
                  if (scopes.isNotEmpty)
                    DropdownButton<String>(
                        key: const ValueKey('comfy-scope'),
                        value: scope,
                        underline: const SizedBox(),
                        items: [
                          for (final s in scopes)
                            DropdownMenuItem(
                                value: '${s['id']}',
                                child: Text('${s['name']}'))
                        ],
                        onChanged: (value) => setState(() {
                              scope = value!;
                              group = selectedSection =
                                  selectedNode = detailId = null;
                              line = lines.firstOrNull?['line'] as int?;
                              invalidate();
                            })),
                  const SizedBox(width: 12),
                  SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('整段')),
                        ButtonSegment(value: true, label: Text('逐行'))
                      ],
                      selected: {
                        lineMode
                      },
                      onSelectionChanged: (value) => setState(() {
                            lineMode = value.single;
                            selectedNode = selectedSection = detailId = null;
                            invalidate();
                          })),
                  if (lineMode && lines.isNotEmpty)
                    Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: DropdownButton<int>(
                            key: const ValueKey('graph-line-picker'),
                            value: lines.any((v) => v['line'] == line)
                                ? line
                                : lines.first['line'] as int,
                            items: [
                              for (final v in lines)
                                DropdownMenuItem(
                                    value: v['line'] as int,
                                    child: Text('第 ${v['line']} 行'))
                            ],
                            onChanged: (value) => setState(() {
                                  line = value;
                                  selectedNode = null;
                                  notifyLine(line);
                                  invalidate();
                                }))),
                  Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: FilterChip(
                          label: const Text('显示中间节点'),
                          tooltip: '展开传参、接收返回值和数据传递等节点',
                          selected: showIntermediate,
                          onSelected: (value) => setState(() {
                                showIntermediate = value;
                                invalidate();
                              }))),
                  if (!lineMode && detailId == null) ...[
                    if (currentSections.length > 1)
                      PopupMenuButton<String>(
                          tooltip: '定位代码块',
                          icon: const Icon(Icons.my_location, size: 17),
                          itemBuilder: (_) => [
                                for (final section in currentSections)
                                  IdeMenuItem(
                                      value: '${section['id']}',
                                      child: Text(
                                          'L${section['line']} · ${section['title']}'))
                              ],
                          onSelected: (id) => setState(() {
                                final section = currentSections
                                    .where((s) => s['id'] == id)
                                    .firstOrNull;
                                if (section == null) return;
                                selectedSection = id;
                                selectedNode = null;
                                line = section['line'] as int;
                                notifyLine(line);
                                invalidate();
                              })),
                    IconButton(
                        tooltip: '折叠本层代码块',
                        onPressed: () => onEvent({'action': 'collapseAll'}),
                        icon: const Icon(Icons.unfold_less, size: 18)),
                    IconButton(
                        tooltip: '展开本层代码块',
                        onPressed: () => onEvent({'action': 'expandAll'}),
                        icon: const Icon(Icons.unfold_more, size: 18)),
                    FilterChip(
                        label: const Text('完整图'),
                        selected: full,
                        onSelected: (value) => setState(() {
                              full = value;
                              group = selectedSection = selectedNode = null;
                              invalidate();
                            }))
                  ],
                ],
                if (!showNodes &&
                    widget.showFilename &&
                    filename.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  Text(filename, style: const TextStyle(fontSize: 12)),
                ],
                if (!showNodes && widget.onReplay != null)
                  TextButton(
                      onPressed: widget.onReplay, child: const Text('运行记录')),
                const SizedBox(width: 14),
                if (widget.compiledGraph == null)
                  Text(busy ? '更新中…' : '已同步',
                      key: const ValueKey('graph-status'),
                      style: const TextStyle(
                          fontSize: 12, color: PyvisColors.muted)),
                if (showNodes) const SizedBox(width: 10),
                if (showNodes)
                  Text(waitingForLine ? '正在解析本行…' : rendererStatus,
                      key: const ValueKey('renderer-status'),
                      style: const TextStyle(
                          fontSize: 12, color: PyvisColors.muted))
              ]))),
      if (widget.compiledGraph != null &&
          (rendererStatus == '加载画布…' || rendererStatus == '绘制中…'))
        const LinearProgressIndicator(semanticsLabel: '正在绘制节点图'),
      if (lineError != null)
        ListTile(
          title: Text(lineError),
          trailing: TextButton(
              onPressed: () =>
                  setState(() => selectedLine?.remove('loadError')),
              child: const Text('重试本行')),
        ),
      if (parseError != null || (showNodes && canvasError != null))
        Container(
            key: const ValueKey('graph-error'),
            width: double.infinity,
            color: const Color(0xff3d2e2b),
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              Expanded(
                  child: Text((showNodes ? canvasError : null) ??
                      '第 ${parseError!['line'] ?? '?'} 行：${parseError!['message']}。保留最近一次有效图形。')),
              if (showNodes && canvasError != null)
                TextButton(
                    onPressed: () => setState(() {
                          canvasError = null;
                          rendererStatus = '加载画布…';
                          canvasGeneration++;
                        }),
                    child: const Text('重试画布')),
            ])),
      Expanded(
          child: graph == null
              ? Center(
                  child:
                      Text(parseError == null ? '正在解析代码…' : '修正提示中的语法后可查看流程'))
              : Stack(fit: StackFit.expand, children: [
                  if (widget.compiledGraph == null)
                    Offstage(
                        offstage: showNodes,
                        child: ReadingFlowView(
                            key: ValueKey(widget.filename),
                            items: reading,
                            line: line,
                            trace: graphSource == widget.source
                                ? widget.trace
                                : null,
                            onLine: (value) => setState(() {
                                  line = value;
                                  notifyLine(value);
                                }),
                            onNodes: widget.openNodes ??
                                (value) => setState(() {
                                      line = value;
                                      lineMode = true;
                                      showNodes = true;
                                      group = selectedSection =
                                          selectedNode = detailId = null;
                                      locateScope();
                                      notifyLine(value);
                                      invalidate();
                                    }))),
                  if (data != null)
                    IgnorePointer(
                        ignoring: waitingForLine,
                        child: KeyedSubtree(
                            key: ValueKey(canvasGeneration),
                            child: widget.canvasBuilder
                                    ?.call(context, data, onEvent) ??
                                ComfyGraphCanvas(
                                    key: const ValueKey('comfy-canvas'),
                                    scene: data,
                                    onEvent: onEvent)))
                ]))
    ]);
  }
}
