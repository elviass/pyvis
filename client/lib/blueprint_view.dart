import 'dart:async';
import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'blueprint_service.dart';
import 'blueprint_teaching.dart';
import 'blueprint_geometry.dart';
import 'blueprint_routing.dart';
import 'blueprint_flow_layout.dart';
export 'blueprint_geometry.dart';

const _ink = Color(0xffe4e8ef),
    _dim = Color(0xff9ca6b5),
    _data = Color(0xff79c6df);
Color nodeColor(String kind) => switch (kind) {
      'write' ||
      'variable' ||
      'symbol' ||
      'reference' =>
        const Color(0xff8dcea7),
      'condition' ||
      'control' ||
      'join' ||
      'truth' ||
      'branch' =>
        const Color(0xffdfbb79),
      'call' ||
      'entry' ||
      'parameter' ||
      'return' ||
      'argument' ||
      'receive' =>
        const Color(0xffb6a0e9),
      'unsupported' ||
      'exception' ||
      'raise' ||
      'unbound' =>
        const Color(0xffe0a09a),
      'try' ||
      'finally' ||
      'context_enter' ||
      'context_exit' =>
        const Color(0xffdfbb79),
      'literal' => const Color(0xffbec6d3),
      _ => _data
    };
String nodeKind(String kind) => switch (kind) {
      'comment' => '说明',
      'try' => '异常保护',
      'exception' => '异常',
      'raise' => '传递异常',
      'finally' => '清理',
      'context_enter' => '进入',
      'context_exit' => '清理',
      'pending_return' => '准备返回',
      'format' => '格式化',
      'import' => '导入',
      'unbound' => '可能未定义',
      'reference' => '引用',
      'read' => '动作',
      'literal' => '数值',
      'operator' => '运算',
      'write' => '赋值',
      'variable' => '汇合',
      'symbol' => '变量',
      'value' => '值',
      'argument' => '传参',
      'receive' => '接回',
      'lookup' => '定位',
      'element' => '元素',
      'construct' => '创建',
      'truth' => '真值',
      'branch' => '路径',
      'condition' => '判断',
      'call' => '调用',
      'return' => '返回',
      'entry' => '入口',
      'parameter' => '参数',
      'definition' => '定义',
      'container' => '容器',
      'join' => '汇合',
      'control' => '跳转',
      _ => '未展开'
    };

/// Trace ancestors and descendants separately, keeping unrelated branches quiet.
Set<String> graphConnections(String? selected, List<Map> edges) {
  if (selected == null) return {};
  final incoming = <String, List<String>>{},
      outgoing = <String, List<String>>{};
  for (final edge in edges) {
    if (!const ['data', 'binding', 'reference'].contains(edge['kind'])) {
      continue;
    }
    incoming.putIfAbsent('${edge['to']}', () => []).add('${edge['from']}');
    outgoing.putIfAbsent('${edge['from']}', () => []).add('${edge['to']}');
  }
  final result = <String>{selected};
  for (final links in [incoming, outgoing]) {
    final visited = <String>{selected}, queue = <String>[selected];
    while (queue.isNotEmpty) {
      for (final next in links[queue.removeLast()] ?? <String>[]) {
        if (visited.add(next)) {
          result.add(next);
          queue.add(next);
        }
      }
    }
  }
  return result;
}

class BlueprintPanel extends StatefulWidget {
  final String source, filename;
  final ValueChanged<int> onLineSelected;
  final Map<String, Offset>? layoutPositions;
  final int? activeLine;
  final bool initialLineMode;
  const BlueprintPanel(
      {super.key,
      required this.source,
      required this.filename,
      required this.onLineSelected,
      this.layoutPositions,
      this.activeLine,
      this.initialLineMode = true});
  @override
  State<BlueprintPanel> createState() => _BlueprintPanelState();
}

class _BlueprintPanelState extends State<BlueprintPanel> {
  final service = BlueprintService();
  final transform = TransformationController();
  final viewportKey = GlobalKey();
  final router = BlueprintRouter(), sectionRouter = BlueprintRouter();
  final folds = <String, Set<String>>{};
  bool needOverview = false;
  late Map<String, Offset> positions;
  Timer? debounce;
  int revision = 0;
  Map<String, dynamic>? graph;
  Map? error;
  String scope = 'main', graphSource = '';
  String? selected, focusedSection, flowContext;
  bool layered = true;
  int? currentLine, sentLine;
  bool lineMode = true, plainLanguage = true;
  bool busy = false, needFit = true, showControl = false;
  Size viewport = Size.zero;
  Offset? dragStart, nodeStart;
  @override
  void initState() {
    super.initState();
    positions = widget.layoutPositions ?? {};
    lineMode = widget.initialLineMode;
    showControl = !lineMode;
    transform.addListener(cameraChanged);
    schedule();
  }

  void cameraChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant BlueprintPanel old) {
    super.didUpdateWidget(old);
    final fromGraph = sentLine != null && widget.activeLine == sentLine;
    sentLine = null;
    if (widget.activeLine != old.activeLine &&
        widget.activeLine != null &&
        !fromGraph) {
      if (widget.source == old.source && graph != null) {
        focusedSection = null;
        flowContext = null;
        scopeForLine(widget.activeLine);
        currentLine = chooseLine(widget.activeLine);
        selected = null;
        needFit = true;
      }
    }
    if (widget.source != old.source || widget.filename != old.filename) {
      if (widget.filename != old.filename) {
        graph = null;
        positions = widget.layoutPositions ?? {};
        selected = null;
        scope = 'main';
        currentLine = null;
        focusedSection = null;
        flowContext = null;
        needFit = true;
      }
      schedule();
    }
  }

  void schedule() {
    final token = ++revision;
    debounce?.cancel();
    busy = true;
    debounce = Timer(const Duration(milliseconds: 350), () async {
      final source = widget.source;
      try {
        final response = await service.parse(source);
        if (!mounted || token != revision) return;
        setState(() {
          busy = false;
          error = response['error'] as Map?;
          if (response['graph'] != null) {
            final oldName = (graph?['scopes'] as List? ?? [])
                .where((s) => s['id'] == scope)
                .firstOrNull?['name'];
            graph = Map<String, dynamic>.from(response['graph']);
            graphSource = source;
            final scopes = graph!['scopes'] as List;
            if (!scopes.any((s) => s['id'] == scope)) {
              final same = scopes.where((s) => s['name'] == oldName);
              scope = same.length == 1 ? '${same.single['id']}' : 'main';
              needFit = true;
            }
            final used = <String>{};
            final duplicates = <String, int>{};
            for (final node in [
              ...graph!['nodes'] as List,
              for (final v in graph!['whole_views'] as List? ?? [])
                ...((v['nodes'] as List).where((n) => n['kind'] == 'reference'))
            ]) {
              final base =
                  '${node['scope']}:${node['kind']}:${node['line']}:${node['code']}';
              final count = duplicates.update(base, (value) => value + 1,
                  ifAbsent: () => 0);
              node['layout_key'] = '$base:$count';
              used.add('$base:$count');
            }
            positions.removeWhere((key, _) => !used.contains(
                key.contains('|node|')
                    ? key.substring(key.indexOf('|node|') + 6)
                    : key));
            scopeForLine(widget.activeLine);
            final nextLine = chooseLine(widget.activeLine ?? currentLine);
            if (nextLine != currentLine) needFit = true;
            currentLine = nextLine;
            selected = null;
          }
        });
      } catch (e) {
        if (mounted && token == revision) {
          setState(() {
            busy = false;
            error = {'message': '$e'};
          });
        }
      }
    });
  }

  void scopeForLine(int? line) {
    if (!lineMode || line == null) return;
    final candidates = (graph?['line_views'] as List? ?? [])
        .where((v) => v['line'] == line)
        .toList();
    if (candidates.any((v) => v['scope'] == scope) || candidates.isEmpty) {
      return;
    }
    candidates.sort((a, b) => '${b['scope']}'
        .split('/')
        .length
        .compareTo('${a['scope']}'.split('/').length));
    scope = '${candidates.first['scope']}';
    needFit = true;
  }

  int? chooseLine(int? requested) {
    final lines = (graph?['line_views'] as List? ?? [])
        .where((v) => v['scope'] == scope)
        .map((v) => v['line'] as int)
        .toList()
      ..sort();
    if (lines.isEmpty) return null;
    if (requested == null) return lines.last;
    final preceding = lines.where((line) => line <= requested);
    return preceding.isEmpty ? lines.first : preceding.last;
  }

  void showLine(int line, {bool notify = true}) {
    setState(() {
      currentLine = line;
      selected = null;
      needFit = true;
    });
    if (notify && graphSource == widget.source) {
      sentLine = line;
      widget.onLineSelected(line);
    }
  }

  @override
  void dispose() {
    revision++;
    debounce?.cancel();
    service.dispose();
    transform.removeListener(cameraChanged);
    transform.dispose();
    super.dispose();
  }

  void fit(Size content, {bool overview = false}) {
    if (viewport.isEmpty) return;
    final fitted = math.min((viewport.width - 32) / content.width,
        (viewport.height - 32) / content.height);
    final scale = overview ? fitted.clamp(.02, 1.0) : 1.0;
    transform.value = Matrix4.identity()
      ..scaleByDouble(scale, scale, 1, 1)
      ..setTranslationRaw(
          math.max(16, (viewport.width - content.width * scale) / 2),
          overview
              ? math.max(16, (viewport.height - content.height * scale) / 2)
              : 24,
          0);
  }

  void zoom(double factor) {
    final old = transform.value, scale = old[0].abs();
    final next = (scale * factor).clamp(.02, 2.5),
        center = viewport.center(Offset.zero);
    transform.value = Matrix4.identity()
      ..scaleByDouble(next, next, 1, 1)
      ..setTranslationRaw(center.dx - (center.dx - old[12]) * next / scale,
          center.dy - (center.dy - old[13]) * next / scale, 0);
  }

  Offset scenePoint(Offset global) {
    final box = viewportKey.currentContext!.findRenderObject()! as RenderBox;
    return transform.toScene(box.globalToLocal(global));
  }

  void select(Map node) {
    setState(() {
      selected = '${node['id']}';
      focusedSection = node['section_id'] as String?;
    });
    if (graphSource == widget.source) {
      sentLine = node['line'] as int;
      widget.onLineSelected(node['line'] as int);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scopes = graph?['scopes'] as List? ??
        [
          {'id': 'main', 'name': '主程序'}
        ];
    final views = (graph?['line_views'] as List? ?? [])
        .where((v) => v['scope'] == scope)
        .cast<Map>()
        .toList();
    final view = lineMode
        ? views.where((v) => v['line'] == currentLine).firstOrNull
        : (graph?['whole_views'] as List? ?? [])
            .where((v) => v['scope'] == scope)
            .firstOrNull;
    final detailed = view?['detailed'] == true && !lineMode;
    final rawNodes = view?['nodes'] as List? ??
        (graph?['nodes'] as List? ?? [])
            .where((n) => n['scope'] == scope)
            .toList();
    final flowView = !lineMode && view?['flow_tree'] is Map;
    final targetSection = focusedSection ??
        rawNodes
            .cast<Map>()
            .where((n) =>
                n['line'] == (widget.activeLine ?? currentLine) &&
                !const ['reference', 'variable', 'unbound'].contains(n['kind']))
            .firstOrNull?['section_id'];
    final slice = flowView && layered
        ? focusFlow(view!, targetSection as String?, flowContext)
        : null;
    final folded = flowView
        ? folds.putIfAbsent(
            '${widget.filename}|$scope',
            () => (view!['sections'] as List)
                .cast<Map>()
                .map(sectionFoldKey)
                .toSet())
        : <String>{};
    final projection = flowView
        ? projectFlow(
            slice?.nodes ?? rawNodes.cast<Map>(),
            slice?.sections ?? (view!['sections'] as List).cast<Map>(),
            slice?.tree ?? view!['flow_tree'] as Map,
            folded)
        : null;
    final bases = {
      for (final n in [
        ...graph?['nodes'] as List? ?? [],
        ...rawNodes.where((n) => n['kind'] == 'reference')
      ])
        n['id']: n['layout_key']
    };
    final allLayoutNodes = (projection?.nodes ?? rawNodes).map((raw) {
      final n = Map<String, dynamic>.from(raw as Map);
      n['layout_key'] =
          '$scope:${lineMode ? 'line-$currentLine' : flowView ? 'flow' : 'all'}|node|${bases[n['id']]}';
      n['base_x'] = flowView ? n['x'] : 0.0;
      n['base_y'] = flowView ? n['y'] : 0.0;
      final offset = positions[n['layout_key']];
      if (offset != null) {
        n['x'] = offset.dx + (n['base_x'] as num);
        n['y'] = offset.dy + (n['base_y'] as num);
      }
      return n;
    }).toList();
    final nodes = allLayoutNodes.where((n) => n['hidden'] != true).toList();
    final ids = nodes.map((n) => n['id']).toSet();
    final allEdges = (graph?['edges'] as List? ?? []).cast<Map>();
    final edges = (view?['edges'] as List? ?? allEdges.toList())
        .cast<Map>()
        .where((e) => ids.contains(e['from']) && ids.contains(e['to']))
        .toList();
    var focus = graphConnections(selected, edges);
    final chosen = nodes.where((n) => n['id'] == selected).firstOrNull;
    final callEdge = allEdges
        .where((e) => e['from'] == selected && e['kind'] == 'call')
        .firstOrNull;
    final destination = callEdge == null
        ? null
        : (graph!['nodes'] as List)
            .where((n) => n['id'] == callEdge['to'])
            .firstOrNull;
    final sections = <Map>[];
    for (final raw
        in projection?.sections ?? (view?['sections'] as List? ?? [])) {
      final members = allLayoutNodes.where((n) => n['section_id'] == raw['id']);
      if (members.isEmpty) continue;
      var bounds = raw['rect'] as Rect?;
      if (raw['collapsed'] != true) {
        for (final n in members) {
          final nodeRect = graphNodeRect(n);
          final padded = Rect.fromLTRB(nodeRect.left - 36, nodeRect.top - 56,
              nodeRect.right + 36, nodeRect.bottom + 28);
          bounds = bounds?.expandToInclude(padded) ?? padded;
        }
      }
      sections.add({...raw, 'order': sections.length + 1, 'rect': bounds!});
    }
    final visibleScene = Rect.fromPoints(
            transform.toScene(Offset.zero),
            transform.toScene(Offset(
                math.max(1, viewport.width), math.max(1, viewport.height))))
        .inflate(220);
    final drawnNodes = detailed
        ? nodes.where((n) => graphNodeRect(n).overlaps(visibleScene)).toList()
        : nodes;
    final drawnIds = drawnNodes.map((n) => n['id']).toSet();
    final drawnSections = detailed
        ? sections
            .where((s) => (s['rect'] as Rect).overlaps(visibleScene))
            .toList()
        : sections;
    final sectionNodes = <Map>[
      for (final section in sections)
        {
          'id': section['id'],
          'x': (section['rect'] as Rect).left,
          'y': (section['rect'] as Rect).top,
          'width': (section['rect'] as Rect).width,
          'height': (section['rect'] as Rect).height,
          'inputs': <String>[]
        }
    ];
    final sectionIds = sectionNodes.map((n) => n['id']).toSet();
    final links =
        slice?.links ?? (view?['section_links'] as List? ?? []).cast<Map>();
    final sectionLookup = {for (final s in sections) s['id']: s};
    final sectionEdges = <Map>[
      for (final link in links)
        if (sectionIds.contains(link['source']) &&
            sectionIds.contains(link['target']) &&
            (!detailed ||
                (sectionLookup[link['source']]!['rect'] as Rect)
                    .overlaps(visibleScene) ||
                (sectionLookup[link['target']]!['rect'] as Rect)
                    .overlaps(visibleScene)))
          {
            'from': link['source'],
            'to': link['target'],
            'kind': 'section',
            'label': link['label'] == '' && link['kind'] == 'exception'
                ? '异常'
                : link['label'],
            'exception_path': link['kind'] == 'exception',
            'back': link['kind'] != 'exception' &&
                (sectionLookup[link['target']]!['rect'] as Rect).top <=
                    (sectionLookup[link['source']]!['rect'] as Rect).top,
            'port': 0
          }
    ];
    final visibleEdges = edges.where((edge) {
      final direct = edge['from'] == selected || edge['to'] == selected;
      if (detailed &&
          !drawnIds.contains(edge['from']) &&
          !drawnIds.contains(edge['to'])) {
        return false;
      }
      if (edge['kind'] == 'exception') {
        return direct &&
            (!detailed ||
                drawnIds.contains(edge['from']) &&
                    drawnIds.contains(edge['to']));
      }
      if (edge['kind'] == 'reference') {
        return direct &&
            (!detailed ||
                drawnIds.contains(edge['from']) &&
                    drawnIds.contains(edge['to']));
      }
      if (edge['kind'] == 'data' ||
          edge['kind'] == 'binding' ||
          edge['kind'] == 'guard') {
        return true;
      }
      return showControl ||
          direct ||
          edge['kind'] == 'flow' && edge['label'] != '';
    }).toList();
    final routeIds = {
      ...drawnIds,
      for (final e in visibleEdges) e['from'],
      for (final e in visibleEdges) e['to']
    };
    final routeNodes = detailed
        ? nodes.where((n) => routeIds.contains(n['id'])).toList()
        : nodes;
    for (final n in drawnNodes) {
      n['exec_in'] =
          visibleEdges.any((e) => executionEdge(e) && e['to'] == n['id']);
      n['exec_out'] =
          visibleEdges.any((e) => executionEdge(e) && e['from'] == n['id']);
      n['exec_false'] = visibleEdges.any((e) =>
          e['kind'] == 'guard' && e['from'] == n['id'] && e['label'] == '不成立');
    }
    final routes = [
      ...sectionRouter.route(sectionNodes, sectionEdges),
      ...router.route(routeNodes, visibleEdges)
    ];
    final blocked = routes.where((r) => r.blocked).length;
    final content = Size(
        math.max(
            300,
            sections.fold(
                nodes.fold(
                    0.0, (w, n) => math.max(w, graphNodeRect(n).right + 80)),
                (w, s) => math.max(w, (s['rect'] as Rect).right + 80))),
        math.max(
            200,
            sections.fold(
                nodes.fold(
                    0.0, (h, n) => math.max(h, graphNodeRect(n).bottom + 80)),
                (h, s) => math.max(h, (s['rect'] as Rect).bottom + 80))));
    Map? sectionForLine(int? line) {
      final exact = allLayoutNodes
          .where((n) =>
              n['line'] == line &&
              !const ['reference', 'variable', 'unbound'].contains(n['kind']))
          .firstOrNull;
      return sections
              .where((s) => s['id'] == exact?['section_id'])
              .firstOrNull ??
          sections.where((s) => (s['line'] as int) <= (line ?? 1)).lastOrNull ??
          sections.firstOrNull;
    }

    final activeSection =
        sections.where((s) => s['id'] == focusedSection).firstOrNull ??
            sectionForLine(widget.activeLine ?? currentLine);
    final activeIndex =
        activeSection == null ? -1 : sections.indexOf(activeSection);
    for (final section in sections) {
      section['active'] = section['id'] == activeSection?['id'];
    }
    void visitSection(Map section, {bool notify = true}) {
      final rect = section['rect'] as Rect;
      focusedSection = '${section['id']}';
      var horizontal = rect;
      if (slice != null &&
          section['collapsed'] == true &&
          sections.isNotEmpty) {
        horizontal = sections
            .map((s) => s['rect'] as Rect)
            .reduce((a, b) => a.expandToInclude(b));
      }
      final scale = ((viewport.width - 160) / horizontal.width).clamp(.85, 1.0);
      transform.value = Matrix4.identity()
        ..scaleByDouble(scale, scale, 1, 1)
        ..setTranslationRaw(
            80 - horizontal.left * scale, 32 - rect.top * scale, 0);
      if (notify && graphSource == widget.source) {
        sentLine = section['line'] as int;
        widget.onLineSelected(sentLine!);
      }
    }

    void toggleSection(Map section) {
      setState(() {
        final key = sectionFoldKey(section);
        if (section['subflow_group'] != null) {
          flowContext = '${section['subflow_group']}';
          folded.add(key);
        } else if (!folded.remove(key)) {
          folded.add(key);
        }
        selected = null;
        focusedSection = '${section['id']}';
        needFit = true;
      });
      if (graphSource == widget.source) {
        sentLine = section['line'] as int;
        widget.onLineSelected(sentLine!);
      }
    }

    final outgoing = detailed && activeSection != null
        ? links.where((l) => l['source'] == activeSection['id']).toList()
        : <Map>[];
    final Map? teaching = lineMode
        ? (view?['teaching'] as Map?)
        : (activeSection?['teaching'] as Map?);
    if (plainLanguage && selected == null && activeSection != null) {
      final primary = nodes
          .where((n) =>
              n['section_id'] == activeSection['id'] &&
              const ['condition', 'write', 'call', 'return']
                  .contains(n['kind']))
          .firstOrNull;
      if (primary != null) focus = graphConnections('${primary['id']}', edges);
    }
    if (focus.isNotEmpty && !drawnNodes.any((n) => focus.contains(n['id']))) {
      focus = {};
    }
    void followTeachingStep(Map step) {
      final line = step['line'] as int;
      if (lineMode) {
        if (line != currentLine) {
          showLine(line);
          return;
        }
      } else {
        final target = sectionForLine(line);
        if (target != null && target['collapsed'] == true) {
          toggleSection(target);
          return;
        }
        if (target != null && target['id'] != activeSection?['id']) {
          setState(() => selected = null);
          visitSection(target);
          return;
        }
      }
      var node = nodes
          .where((n) =>
              n['line'] == line &&
              n['kind'] == step['target_kind'] &&
              (step['target_operator'] == null ||
                  n['title'] == step['target_operator']) &&
              (step['function_suffix'] == null ||
                  '${n['function']}'.endsWith('${step['function_suffix']}')))
          .firstOrNull;
      if (node == null && step['target_kind'] == 'read') {
        node = nodes
            .where((n) =>
                n['line'] == line &&
                const ['literal', 'reference'].contains(n['kind']))
            .firstOrNull;
      }
      if (node != null) select(node);
    }

    String nextLabel(Map link, Map? target) {
      if (!plainLanguage) {
        return '${link['kind'] == 'exception' ? '出错时' : link['label'] == '' ? '接下来' : link['label']} → L${target?['line']}';
      }
      final title =
          (target?['teaching'] as Map?)?['title'] ?? target?['title'] ?? '下一步';
      if (link['kind'] == 'exception') return '发生异常 → 选择处理分支';
      if (link['label'] == '结束') return '条件不成立 → 退出循环';
      if (link['label'] == '下一轮') return '本轮结束 → 再次判断条件';
      if (link['label'] == '成立') return '条件成立 → $title';
      if (link['label'] == '不成立') return '条件不成立 → $title';
      return '继续执行 → $title';
    }

    void jumpToSection(Map section) {
      if (section['rect'] != null) {
        visitSection(section);
        return;
      }
      setState(() {
        focusedSection = '${section['id']}';
        flowContext = null;
        selected = null;
        needFit = true;
      });
      if (graphSource == widget.source) {
        sentLine = section['line'] as int;
        widget.onLineSelected(sentLine!);
      }
    }

    void showOverview() {
      final catalog = slice == null
          ? sections
          : <Map>[
              for (final raw in (view!['sections'] as List).cast<Map>())
                {...raw, 'order': (view['sections'] as List).indexOf(raw) + 1}
            ];
      var query = '';
      showDialog<void>(
          context: context,
          builder: (dialogContext) =>
              StatefulBuilder(builder: (context, update) {
                final matches = catalog
                    .where((s) =>
                        '${s['title']} L${s['line']} ${(s['path'] as List? ?? []).join(' ')}'
                            .toLowerCase()
                            .contains(query.toLowerCase()))
                    .toList();
                return AlertDialog(
                    title: const Text('分区总览'),
                    content: SizedBox(
                        width: math.min(720, viewport.width),
                        height: math.min(620, viewport.height * .8),
                        child: Column(children: [
                          TextField(
                              key: const ValueKey('graph-section-search'),
                              decoration: const InputDecoration(
                                  hintText: '搜索代码、行号或分区名称',
                                  prefixIcon: Icon(Icons.search)),
                              onChanged: (value) =>
                                  update(() => query = value)),
                          const SizedBox(height: 8),
                          Expanded(
                              child: ListView.builder(
                                  key: ValueKey('section-results-$query'),
                                  itemCount: matches.length,
                                  itemBuilder: (context, i) {
                                    final section = matches[i],
                                        path = section['path'] as List? ?? [];
                                    return ListTile(
                                        contentPadding: EdgeInsets.only(
                                            left:
                                                math.min(3, path.length) * 12.0,
                                            right: 8),
                                        title: Text(
                                            '${section['order']}. ${section['title']} · L${section['line']}',
                                            style:
                                                const TextStyle(fontSize: 14)),
                                        subtitle: path.isEmpty
                                            ? null
                                            : Text(path.join(' / '),
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                    fontSize: 11)),
                                        onTap: () {
                                          Navigator.pop(dialogContext);
                                          jumpToSection(section);
                                        });
                                  }))
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('关闭'))
                    ]);
              }));
    }

    return ColoredBox(
        color: const Color(0xff181b20),
        child: Column(children: [
          Container(
              color: const Color(0xff252930),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              child: Wrap(
                  spacing: 10,
                  runSpacing: 5,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Icon(Icons.account_tree_outlined,
                        size: 18, color: _data),
                    DropdownButton<String>(
                        value: scope,
                        isDense: true,
                        items: scopes
                            .map((s) => DropdownMenuItem<String>(
                                value: '${s['id']}',
                                child: Text('${s['name']}',
                                    style: const TextStyle(fontSize: 13))))
                            .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              scope = value;
                              flowContext = null;
                              focusedSection = null;
                              currentLine = chooseLine(null);
                              selected = null;
                              needFit = true;
                            });
                          }
                        }),
                    Text(busy ? '更新中…' : '已同步',
                        key: const ValueKey('graph-status'),
                        style: const TextStyle(fontSize: 11, color: _dim)),
                    IconButton(
                        tooltip: '缩小流程图',
                        onPressed: () => zoom(.8),
                        icon: const Icon(Icons.remove, size: 17),
                        visualDensity: VisualDensity.compact),
                    AnimatedBuilder(
                        animation: transform,
                        builder: (context, child) => Text(
                            '${(transform.value[0].abs() * 100).round()}%',
                            style: const TextStyle(fontSize: 11, color: _ink))),
                    IconButton(
                        tooltip: '放大流程图',
                        onPressed: () => zoom(1.25),
                        icon: const Icon(Icons.add, size: 17),
                        visualDensity: VisualDensity.compact),
                    IconButton(
                        key: const ValueKey('readable-zoom'),
                        tooltip: '适合阅读',
                        onPressed: () => setState(() {
                              needFit = true;
                              needOverview = false;
                            }),
                        icon: const Icon(Icons.text_increase, size: 18),
                        visualDensity: VisualDensity.compact),
                    if (detailed)
                      IconButton(
                          tooltip: '查看全图',
                          onPressed: () => fit(content, overview: true),
                          icon: const Icon(Icons.fit_screen, size: 18),
                          visualDensity: VisualDensity.compact),
                    IconButton(
                        tooltip: detailed ? '分区总览' : '查看全图',
                        onPressed: detailed
                            ? showOverview
                            : () => fit(content, overview: true),
                        icon: const Icon(Icons.fit_screen, size: 18),
                        visualDensity: VisualDensity.compact),
                    IconButton(
                        tooltip: '重新自动排布',
                        onPressed: () {
                          setState(() {
                            positions.clear();
                            selected = null;
                            needFit = true;
                          });
                        },
                        icon: const Icon(Icons.auto_awesome_mosaic_outlined,
                            size: 18),
                        visualDensity: VisualDensity.compact)
                  ])),
          if (error != null)
            Container(
                width: double.infinity,
                color: const Color(0xff413126),
                padding: const EdgeInsets.all(10),
                child: Text(
                    '${error!['line'] == null ? '' : '第 ${error!['line']} 行：'}${error!['message']}\n${graph == null ? '代码完整后自动生成' : '保留上次有效图，写完后自动更新'}',
                    key: const ValueKey('graph-error'),
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xffecc79a)))),
          Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Color(0xff343c47)))),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SegmentedButton<bool>(
                              segments: const [
                                ButtonSegment(value: true, label: Text('逐行')),
                                ButtonSegment(value: false, label: Text('整段'))
                              ],
                              selected: {
                                lineMode
                              },
                              onSelectionChanged: (values) => setState(() {
                                    lineMode = values.first;
                                    if (lineMode) {
                                      scopeForLine(widget.activeLine);
                                      currentLine =
                                          chooseLine(widget.activeLine);
                                    }
                                    showControl = !lineMode;
                                    selected = null;
                                    needFit = true;
                                  })),
                          if (lineMode && views.isNotEmpty)
                            SizedBox(
                                width: 270,
                                child: DropdownButton<int>(
                                    key: const ValueKey('graph-line-picker'),
                                    value: currentLine,
                                    isExpanded: true,
                                    isDense: true,
                                    items: views
                                        .map((v) => DropdownMenuItem<int>(
                                            value: v['line'] as int,
                                            child: Text(
                                                '第 ${v['line']} 行  ${v['code']}',
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                    fontSize: 16))))
                                        .toList(),
                                    onChanged: (line) {
                                      if (line != null) showLine(line);
                                    })),
                          if (lineMode && views.isNotEmpty)
                            IconButton(
                                tooltip: '上一行流程',
                                onPressed: views.indexWhere(
                                            (v) => v['line'] == currentLine) >
                                        0
                                    ? () => showLine(views[views.indexWhere(
                                            (v) => v['line'] == currentLine) -
                                        1]['line'] as int)
                                    : null,
                                icon: const Icon(Icons.chevron_left)),
                          if (lineMode && views.isNotEmpty)
                            IconButton(
                                tooltip: '下一行流程',
                                onPressed: views.indexWhere(
                                            (v) => v['line'] == currentLine) <
                                        views.length - 1
                                    ? () => showLine(views[views.indexWhere(
                                            (v) => v['line'] == currentLine) +
                                        1]['line'] as int)
                                    : null,
                                icon: const Icon(Icons.chevron_right)),
                          FilterChip(
                              label: const Text('步骤说明'),
                              selected: plainLanguage,
                              onSelected: (value) =>
                                  setState(() => plainLanguage = value)),
                          if (flowView)
                            FilterChip(
                                key: const ValueKey('full-flow-toggle'),
                                label: const Text('完整图'),
                                selected: !layered,
                                onSelected: (value) => setState(() {
                                      layered = !value;
                                      flowContext = null;
                                      selected = null;
                                      needFit = true;
                                    })),
                          if (flowView)
                            TextButton.icon(
                                key: const ValueKey('fold-all-sections'),
                                icon: const Icon(Icons.unfold_less, size: 17),
                                label: const Text('折叠全部'),
                                onPressed: () => setState(() {
                                      folded
                                          .addAll(sections.map(sectionFoldKey));
                                      selected = null;
                                      needFit = true;
                                      needOverview = false;
                                    })),
                          if (flowView)
                            TextButton.icon(
                                key: const ValueKey('expand-all-sections'),
                                icon: const Icon(Icons.unfold_more, size: 17),
                                label: const Text('展开全部'),
                                onPressed: () => setState(() {
                                      folded.clear();
                                      needFit = true;
                                    })),
                          if (!lineMode)
                            FilterChip(
                                label: Text(plainLanguage ? '显示执行顺序' : '区内执行线'),
                                selected: showControl,
                                onSelected: (value) =>
                                    setState(() => showControl = value))
                        ]),
                  ])),
          if (plainLanguage &&
              teaching != null &&
              (lineMode || activeSection?['collapsed'] != true))
            BlueprintTeaching(lesson: teaching, onStep: followTeachingStep),
          if (slice?.groupId != null && !detailed)
            Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                    key: const ValueKey('flow-parent'),
                    onPressed: () => setState(() {
                          flowContext = slice!.parentId ?? '@root';
                          focusedSection = slice.headerId;
                          selected = null;
                          needFit = true;
                        }),
                    icon: const Icon(Icons.subdirectory_arrow_left, size: 16),
                    label: const Text('返回上层流程'))),
          if (sections.isNotEmpty && !detailed)
            SizedBox(
                height: 38,
                child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (var i = 0; i < sections.length; i++)
                        Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: TextButton(
                                key: ValueKey(
                                    'section-jump-${sections[i]['id']}'),
                                onPressed: () => visitSection(sections[i]),
                                child: Text(
                                    '${sections[i]['title']} · L${sections[i]['line']}',
                                    style: const TextStyle(fontSize: 12))))
                    ])),
          if (detailed && activeSection != null)
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(children: [
                  if (slice != null)
                    IconButton(
                        key: const ValueKey('flow-parent'),
                        tooltip: '返回上层流程',
                        onPressed: slice.groupId == null
                            ? null
                            : () => setState(() {
                                  flowContext = slice.parentId ?? '@root';
                                  focusedSection = slice.headerId;
                                  selected = null;
                                  needFit = true;
                                }),
                        icon: const Icon(Icons.subdirectory_arrow_left)),
                  IconButton(
                      tooltip: '上一个分区',
                      onPressed: activeIndex > 0
                          ? () => visitSection(sections[activeIndex - 1])
                          : null,
                      icon: const Icon(Icons.chevron_left)),
                  Expanded(
                      child: DropdownButton<String>(
                          key: const ValueKey('graph-section-picker'),
                          value: '${activeSection['id']}',
                          isExpanded: true,
                          menuMaxHeight: 360,
                          items: [
                            for (var i = 0; i < sections.length; i++)
                              DropdownMenuItem(
                                  value: '${sections[i]['id']}',
                                  child: Text(
                                      '${sections[i]['title']} · L${sections[i]['line']}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13)))
                          ],
                          onChanged: (id) {
                            final target = sections
                                .where((s) => s['id'] == id)
                                .firstOrNull;
                            if (target != null) visitSection(target);
                          })),
                  IconButton(
                      tooltip: '下一个分区',
                      onPressed: activeIndex < sections.length - 1
                          ? () => visitSection(sections[activeIndex + 1])
                          : null,
                      icon: const Icon(Icons.chevron_right)),
                  Text('${sections.length} 个${slice == null ? '分区' : '代码块'}',
                      key: const ValueKey('graph-section-count'),
                      style: const TextStyle(fontSize: 11, color: _dim))
                ])),
          if (detailed && activeSection?['collapsed'] != true)
            SizedBox(
                height: 30,
                child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      if (outgoing.isEmpty)
                        const Text('本路径到此结束',
                            style: TextStyle(fontSize: 12, color: _dim)),
                      for (final link in outgoing)
                        TextButton(
                            onPressed: () {
                              final target = sections
                                  .where((s) => s['id'] == link['target'])
                                  .firstOrNull;
                              if (target != null) visitSection(target);
                            },
                            child: Text(
                                nextLabel(
                                    link,
                                    sections
                                        .where((s) => s['id'] == link['target'])
                                        .firstOrNull),
                                style: TextStyle(
                                    fontSize: 11,
                                    color: link['kind'] == 'exception'
                                        ? const Color(0xffe0a09a)
                                        : _data)))
                    ])),
          Expanded(child: LayoutBuilder(builder: (context, constraints) {
            viewport = constraints.biggest;
            if (needFit && (nodes.isNotEmpty || sections.isNotEmpty)) {
              needFit = false;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  if (needOverview) {
                    needOverview = false;
                    fit(content, overview: true);
                  } else if (detailed && activeSection != null) {
                    visitSection(activeSection, notify: false);
                  } else if (plainLanguage &&
                      !lineMode &&
                      activeSection != null) {
                    visitSection(activeSection, notify: false);
                  } else {
                    fit(content);
                  }
                }
              });
            }
            return ClipRect(
                key: viewportKey,
                child: Stack(children: [
                  const Positioned.fill(child: CustomPaint(painter: _Grid())),
                  if (blocked > 0)
                    Positioned(
                        right: 12,
                        bottom: 12,
                        child: IgnorePointer(
                            child: Text('$blocked 条连线暂时无法绕开，请移开重叠节点',
                                key: const ValueKey('blocked-wires'),
                                style: const TextStyle(
                                    fontSize: 11, color: Color(0xffdfbb79))))),
                  if (nodes.isEmpty && sections.isEmpty)
                    Center(
                        child: Text(busy ? '正在解析 Python 语法…' : '写下代码，就能看见它的组成',
                            style: const TextStyle(color: _dim)))
                  else
                    Positioned.fill(
                        child: InteractiveViewer(
                            key: const ValueKey('blueprint-canvas'),
                            transformationController: transform,
                            constrained: false,
                            minScale: .02,
                            maxScale: 2.5,
                            boundaryMargin: const EdgeInsets.all(2000),
                            child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => setState(() => selected = null),
                                child: SizedBox(
                                    width: content.width,
                                    height: content.height,
                                    child: Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          if (sections.isNotEmpty)
                                            Positioned.fill(
                                                child: IgnorePointer(
                                                    child: CustomPaint(
                                                        painter: _Sections(
                                                            drawnSections,
                                                            plainLanguage)))),
                                          Positioned.fill(
                                              child: CustomPaint(
                                                  key: const ValueKey(
                                                      'graph-wires'),
                                                  painter: BlueprintWires(
                                                      nodes,
                                                      edges,
                                                      selected,
                                                      focus,
                                                      showControl,
                                                      routes: routes))),
                                          for (final section in drawnSections)
                                            Positioned(
                                                left: (section['rect'] as Rect)
                                                    .left,
                                                top: (section['rect'] as Rect)
                                                    .top,
                                                width: (section['rect'] as Rect)
                                                        .width -
                                                    44,
                                                height:
                                                    section['collapsed'] == true
                                                        ? 148
                                                        : 88,
                                                child: MouseRegion(
                                                    cursor: SystemMouseCursors
                                                        .click,
                                                    child: GestureDetector(
                                                        key: ValueKey(
                                                            'section-header-${section['id']}'),
                                                        behavior:
                                                            HitTestBehavior
                                                                .opaque,
                                                        onTap: () =>
                                                            toggleSection(
                                                                section),
                                                        child: Semantics(
                                                            label:
                                                                '${section['title']}，第 ${section['line']} 行，${section['subflow_group'] != null ? '进入子流程' : section['collapsed'] == true ? '展开代码块' : '折叠代码块'}',
                                                            button: true,
                                                            child: const SizedBox
                                                                .expand())))),
                                          for (final section in drawnSections)
                                            Positioned(
                                                left: (section['rect'] as Rect)
                                                        .right -
                                                    42,
                                                top: (section[
                                                            'rect'] as Rect)
                                                        .top +
                                                    6,
                                                width: 36,
                                                height: 36,
                                                child: IconButton(
                                                    key: ValueKey(
                                                        'section-fold-${section['id']}'),
                                                    tooltip: section[
                                                                'subflow_group'] !=
                                                            null
                                                        ? '进入子流程'
                                                        : section[
                                                                    'collapsed'] ==
                                                                true
                                                            ? '展开代码块'
                                                            : '折叠代码块',
                                                    onPressed: () =>
                                                        toggleSection(section),
                                                    icon: Icon(
                                                        section['subflow_group'] !=
                                                                null
                                                            ? Icons.open_in_new
                                                            : section['collapsed'] ==
                                                                    true
                                                                ? Icons
                                                                    .unfold_more
                                                                : Icons
                                                                    .unfold_less,
                                                        size: 20))),
                                          for (final node in drawnNodes)
                                            Positioned(
                                                key: ValueKey(
                                                    'graph-node-${node['id']}'),
                                                left: (node['x'] as num)
                                                    .toDouble(),
                                                top: (node['y'] as num)
                                                    .toDouble(),
                                                width: graphNodeWidth(node),
                                                height: graphNodeHeight(node),
                                                child: GestureDetector(
                                                    behavior:
                                                        HitTestBehavior.opaque,
                                                    onTap: () => select(node),
                                                    dragStartBehavior:
                                                        DragStartBehavior.down,
                                                    onPanStart: (details) {
                                                      dragStart = scenePoint(
                                                          details
                                                              .globalPosition);
                                                      nodeStart =
                                                          graphNodeRect(node)
                                                              .topLeft;
                                                      select(node);
                                                    },
                                                    onPanUpdate: (details) {
                                                      final delta = scenePoint(
                                                              details
                                                                  .globalPosition) -
                                                          dragStart!;
                                                      setState(() => positions[
                                                              '${node['layout_key']}'] =
                                                          Offset(
                                                              math.max(
                                                                      12,
                                                                      nodeStart!
                                                                              .dx +
                                                                          delta
                                                                              .dx) -
                                                                  (node['base_x']
                                                                          as num)
                                                                      .toDouble(),
                                                              math.max(
                                                                      12,
                                                                      nodeStart!
                                                                              .dy +
                                                                          delta
                                                                              .dy) -
                                                                  (node['base_y']
                                                                          as num)
                                                                      .toDouble()));
                                                    },
                                                    onPanCancel: () {
                                                      dragStart = null;
                                                      nodeStart = null;
                                                    },
                                                    onPanEnd: (_) {
                                                      dragStart = null;
                                                      nodeStart = null;
                                                    },
                                                    child: Opacity(
                                                        opacity: focus
                                                                    .isEmpty ||
                                                                focus.contains(
                                                                    node['id'])
                                                            ? 1
                                                            : .34,
                                                        child: _Node(
                                                            node: node,
                                                            plainLanguage:
                                                                plainLanguage,
                                                            selected:
                                                                node['id'] ==
                                                                    selected))))
                                        ])))))
                ]));
          })),
          if (chosen != null)
            Container(
                width: double.infinity,
                color: const Color(0xff252930),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('第 ${chosen['line']} 行',
                          key: const ValueKey('selected-graph-line'),
                          style: const TextStyle(fontSize: 12, color: _data)),
                      if (plainLanguage)
                        SizedBox(
                            width: math.min(680, viewport.width - 40),
                            child: Text(explainGraphNode(chosen),
                                key: const ValueKey('node-plain-explanation'),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13, color: _ink))),
                      Text('${chosen['code']}'.split('\n').first,
                          style: const TextStyle(
                              fontFamily: 'JetBrains Mono',
                              fontSize: 12,
                              color: _ink)),
                      if (chosen['origin_id'] != null)
                        TextButton(
                            onPressed: () {
                              final origin = nodes
                                  .where((n) => n['id'] == chosen['origin_id'])
                                  .firstOrNull;
                              if (origin == null) return;
                              select(origin);
                              final rect = graphNodeRect(origin);
                              transform.value = Matrix4.identity()
                                ..setTranslationRaw(
                                    120 - rect.left, 80 - rect.top, 0);
                            },
                            child: Text('定位来源 · 第 ${chosen['origin_line']} 行')),
                      if (destination != null)
                        TextButton(
                            onPressed: () => setState(() {
                                  scope = '${destination['scope']}';
                                  currentLine =
                                      chooseLine(destination['line'] as int?);
                                  selected = '${destination['id']}';
                                  needFit = true;
                                }),
                            child: const Text('展开函数内部')),
                      IconButton(
                          tooltip: '取消节点选择',
                          onPressed: () => setState(() => selected = null),
                          icon: const Icon(Icons.close, size: 16),
                          visualDensity: VisualDensity.compact)
                    ])),
          if ((graph?['warnings'] as List? ?? []).isNotEmpty)
            Padding(
                padding: const EdgeInsets.all(6),
                child: Text((graph!['warnings'] as List).take(2).join('；'),
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xffe0a09a))))
        ]));
  }
}

class _Node extends StatelessWidget {
  final Map node;
  final bool selected, plainLanguage;
  const _Node(
      {required this.node,
      required this.selected,
      required this.plainLanguage});
  @override
  Widget build(BuildContext context) {
    final color = nodeColor('${node['kind']}'), rect = graphNodeRect(node);
    final inputs = node['inputs'] as List;
    final entity = const ['literal', 'symbol', 'value', 'reference']
        .contains(node['kind']);
    final radius = entity ? 28.0 : 7.0;
    return Semantics(
        button: true,
        label:
            '第 ${node['line']} 行，${node['title']}${node['symbol'] == null ? '' : ' ${node['symbol']}'}${node['function'] == null ? '' : ' ${node['function']}'}，可拖动',
        child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: Container(
                decoration: BoxDecoration(
                    color: const Color(0xff262c36),
                    borderRadius: BorderRadius.circular(radius),
                    border: Border.all(
                        color: selected ? _data : color.withValues(alpha: .65),
                        width: selected ? 2 : 1),
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x35000000),
                          blurRadius: 8,
                          offset: Offset(0, 3))
                    ]),
                child: Stack(clipBehavior: Clip.none, children: [
                  Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(children: [
                              Expanded(
                                  child: Text(
                                      plainLanguage
                                          ? plainNodeKind(
                                              node, nodeKind('${node['kind']}'))
                                          : nodeKind('${node['kind']}'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: color, fontSize: 12))),
                              if (selected ||
                                  node['context'] == true ||
                                  node['kind'] == 'reference')
                                Text('L${node['line']}',
                                    key: ValueKey('node-line-${node['id']}'),
                                    style: const TextStyle(
                                        color: _dim, fontSize: 11))
                            ]),
                            Expanded(
                                child: Center(
                                    child: Tooltip(
                                        message: '${node['code']}',
                                        child: Text(
                                            plainLanguage
                                                ? plainNodeTitle(node)
                                                : '${node['title']}',
                                            maxLines: const [
                                              'symbol',
                                              'reference'
                                            ].contains(node['kind'])
                                                ? 1
                                                : 2,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                                color: _ink,
                                                fontSize: plainLanguage &&
                                                        node['kind'] == 'write'
                                                    ? 20
                                                    : const [
                                                        'operator',
                                                        'write'
                                                      ].contains(node['kind'])
                                                        ? 28
                                                        : node['kind'] ==
                                                                'comment'
                                                            ? 14
                                                            : node['literal_type'] ==
                                                                    'str'
                                                                ? 16
                                                                : const [
                                                                    'literal',
                                                                    'symbol',
                                                                    'reference'
                                                                  ].contains(node[
                                                                        'kind'])
                                                                    ? 24
                                                                    : 16,
                                                fontFamily:
                                                    node['kind'] == 'operator'
                                                        ? 'JetBrains Mono'
                                                        : null,
                                                fontWeight:
                                                    FontWeight.w600))))),
                            if (node['reference_label'] != null)
                              Text(
                                  plainLanguage
                                      ? '${node['reference_label']}'
                                          .replaceFirst('下一轮的值', '上一轮更新值')
                                      : '${node['reference_label']}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontSize: 11, color: _dim)),
                          ])),
                  Positioned(
                      right: -3,
                      top: rect.height / 2 - 3,
                      child: _Port(color: color)),
                  if (node['exec_in'] == true)
                    const Positioned(
                        left: -5,
                        top: 13,
                        child: Icon(Icons.play_arrow, size: 12, color: _ink)),
                  if (node['exec_out'] == true)
                    const Positioned(
                        right: -7,
                        top: 13,
                        child: Icon(Icons.play_arrow, size: 12, color: _ink)),
                  if (node['exec_false'] == true)
                    const Positioned(
                        right: -7,
                        top: 31,
                        child: Icon(Icons.play_arrow, size: 12, color: _ink)),
                  for (var i = 0;
                      i <
                          (node['kind'] == 'reference'
                              ? 0
                              : math.max(1, inputs.length));
                      i++)
                    Positioned(
                        left: -3,
                        top: rect.height *
                                (i + 1) /
                                (math.max(1, inputs.length) + 1) -
                            3,
                        child: Tooltip(
                            message: inputs.isEmpty ? '来源' : '${inputs[i]}',
                            child: const _Port(color: _data)))
                ]))));
  }
}

class _Port extends StatelessWidget {
  final Color color;
  const _Port({required this.color});
  @override
  Widget build(BuildContext context) => Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
          color: const Color(0xff181b20),
          border: Border.all(color: color, width: 1.5),
          shape: BoxShape.circle));
}

class BlueprintWires extends CustomPainter {
  final List<Map> nodes, edges;
  final String? selected;
  final Set<String> focus;
  final bool showControl;
  final List<GraphRoute> routes;
  BlueprintWires(
      this.nodes, this.edges, this.selected, this.focus, this.showControl,
      {List<GraphRoute>? routes})
      : routes = routes ?? BlueprintRouter().route(nodes, edges);
  @override
  void paint(Canvas canvas, Size size) {
    for (final route in routes) {
      if (route.blocked || route.points.length < 2) continue;
      final edge = route.edge;
      final data = edge['kind'] == 'data' || edge['kind'] == 'binding';
      final reference = edge['kind'] == 'reference';
      final exceptional =
          edge['kind'] == 'exception' || edge['exception_path'] == true;
      final section = edge['kind'] == 'section';
      final direct = edge['from'] == selected || edge['to'] == selected;
      final relevant = focus.isEmpty ||
          focus.contains(edge['from']) && focus.contains(edge['to']);
      final color = (data
              ? _data
              : exceptional
                  ? const Color(0xffe0a09a)
                  : reference
                      ? const Color(0xffb6a0e9)
                      : section && edge['back'] == true
                          ? const Color(0xffdfbb79)
                          : _ink)
          .withValues(
              alpha: section
                  ? .85
                  : relevant || direct
                      ? .9
                      : .14);
      final path = Path()..moveTo(route.points.first.dx, route.points.first.dy);
      for (final p in route.points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      final paint = Paint()
        ..color = color
        ..strokeWidth = direct
            ? 2.7
            : section || relevant
                ? 2.0
                : 1.2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;
      if (reference || exceptional) {
        for (final metric in path.computeMetrics()) {
          for (double d = 0; d < metric.length; d += 12) {
            canvas.drawPath(
                metric.extractPath(d, math.min(d + 6, metric.length)), paint);
          }
        }
      } else {
        canvas.drawPath(path, paint);
      }
      final to = route.points.last,
          previous = route.points[route.points.length - 2];
      final direction = (to - previous) / (to - previous).distance;
      final side = Offset(-direction.dy, direction.dx) * 3.5;
      final base = to - direction * 7;
      canvas.drawPath(
          Path()
            ..moveTo(to.dx, to.dy)
            ..lineTo((base + side).dx, (base + side).dy)
            ..lineTo((base - side).dx, (base - side).dy)
            ..close(),
          Paint()..color = color);
      if (!data && !reference && '${edge['label'] ?? ''}'.isNotEmpty) {
        final text = TextPainter(
            text: TextSpan(
                text: section && edge['label'] == '结束'
                    ? '结束循环'
                    : section && edge['back'] == true
                        ? '返回判断'
                        : '${edge['label']}',
                style: TextStyle(
                    fontFamily: 'Roboto', fontSize: 11, color: color)),
            textDirection: TextDirection.ltr)
          ..layout();
        final point = route.points.first +
            (section
                ? edge['back'] == true
                    ? Offset(-text.width - 14, -18)
                    : const Offset(6, 8)
                : const Offset(10, -18));
        canvas.drawRect(
            Rect.fromLTWH(
                point.dx - 3, point.dy - 2, text.width + 6, text.height + 4),
            Paint()..color = const Color(0xff181b20));
        text.paint(canvas, point);
      }
    }
  }

  @override
  bool shouldRepaint(covariant BlueprintWires old) => true;
}

class _Sections extends CustomPainter {
  final List<Map> sections;
  final bool plainLanguage;
  _Sections(this.sections, this.plainLanguage);
  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < sections.length; i++) {
      final section = sections[i], rect = section['rect'] as Rect;
      final shape = RRect.fromRectAndRadius(rect, const Radius.circular(12));
      canvas.drawRRect(
          shape,
          Paint()
            ..color = section['collapsed'] == true
                ? const Color(0xff25303b)
                : const Color(0xff20252d));
      canvas.drawRRect(
          shape,
          Paint()
            ..color =
                section['active'] == true ? _data : const Color(0xff667386)
            ..strokeWidth = section['active'] == true ? 1.7 : 1
            ..style = PaintingStyle.stroke);
      final friendlyTitle =
          (section['teaching'] as Map?)?['title'] ?? section['title'];
      final displayTitle = plainLanguage ? friendlyTitle : section['title'];
      final category = switch (section['category']) {
        'Join' => '汇合',
        'LoopExit' => '循环结束',
        'Finally' => '清理',
        'ContextExit' => '退出上下文',
        'While' || 'For' || 'AsyncFor' => '循环',
        'If' => '条件判断',
        'Assign' || 'AnnAssign' => '赋值',
        'AugAssign' => '更新变量',
        'Try' => '异常处理',
        'With' || 'AsyncWith' => '上下文管理',
        'Return' => '返回',
        'FunctionDef' || 'AsyncFunctionDef' => '函数',
        'Import' || 'ImportFrom' => '导入',
        'Entry' => '入口',
        _ => '操作',
      };
      final metadata = TextPainter(
          text: TextSpan(
              text:
                  '$category   ·   L${section['line']}${section['end_line'] == section['line'] ? '' : '–${section['end_line']}'}',
              style: const TextStyle(
                  fontFamily: 'Roboto', color: _data, fontSize: 13)),
          textDirection: TextDirection.ltr)
        ..layout(maxWidth: rect.width - 72);
      metadata.paint(canvas, rect.topLeft + const Offset(18, 12));
      final title = TextPainter(
          maxLines: section['collapsed'] == true ? 2 : 1,
          ellipsis: '…',
          text: TextSpan(
              text: '$displayTitle',
              style: const TextStyle(
                  fontFamily: 'Roboto',
                  color: _ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w600)),
          textDirection: TextDirection.ltr)
        ..layout(maxWidth: rect.width - 36);
      title.paint(canvas, rect.topLeft + const Offset(18, 36));
      final code = TextPainter(
          maxLines: 1,
          ellipsis: '…',
          text: TextSpan(
              text: '${section['code'] ?? ''}',
              style: const TextStyle(
                  fontFamily: 'JetBrains Mono',
                  color: Color(0xffb4c5db),
                  fontSize: 14)),
          textDirection: TextDirection.ltr)
        ..layout(maxWidth: rect.width - 36);
      code.paint(canvas,
          rect.topLeft + Offset(18, section['collapsed'] == true ? 88 : 64));
      if (section['collapsed'] == true) {
        final summary = TextPainter(
            text: TextSpan(
                text: section['subflow_group'] != null
                    ? '包含 ${section['subflow_sections']} 个代码块 · 进入子流程'
                    : '${section['node_count']} 个节点 · 点击展开',
                style: const TextStyle(
                    fontFamily: 'Roboto', color: _dim, fontSize: 12)),
            textDirection: TextDirection.ltr)
          ..layout(maxWidth: rect.width - 36);
        summary.paint(canvas, rect.topLeft + const Offset(18, 120));
      }
      if (section['flow_label'] != null) {
        final label = TextPainter(
            text: TextSpan(
                text: '${section['flow_label']}',
                style: const TextStyle(
                    fontFamily: 'Roboto',
                    color: Color(0xffdfbb79),
                    fontSize: 13)),
            textDirection: TextDirection.ltr)
          ..layout();
        label.paint(canvas, rect.topLeft - const Offset(0, 26));
      }
      for (final lane in section['lanes'] as List? ?? []) {
        final y = (lane['y'] as num).toDouble();
        // Lane captions stay with the generated layout; dragged nodes remain independent.
        if (y < rect.top + 45 || y > rect.bottom) continue;
        canvas.drawLine(Offset(rect.left + 16, y), Offset(rect.right - 16, y),
            Paint()..color = const Color(0xff3b4655));
        final text = TextPainter(
            text: TextSpan(
                text: '${lane['title']}',
                style: const TextStyle(
                    fontFamily: 'Roboto',
                    color: Color(0xffdfbb79),
                    fontSize: 12)),
            textDirection: TextDirection.ltr)
          ..layout();
        text.paint(canvas, Offset(rect.left + 16, y - 18));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _Sections old) => true;
}

class _Grid extends CustomPainter {
  const _Grid();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xff29303a);
    for (double x = 0; x < size.width; x += 22) {
      for (double y = 0; y < size.height; y += 22) {
        canvas.drawCircle(Offset(x, y), .55, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _Grid old) => false;
}
