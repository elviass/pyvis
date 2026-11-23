import 'dart:math' as math;
import 'dart:ui';

String sectionFoldKey(Map section) => '${section['line']}:${section['title']}';

class FlowProjection {
  final List<Map> nodes, sections;
  FlowProjection(this.nodes, this.sections);
}

class FlowSlice {
  final List<Map> sections, nodes, links;
  final Map tree;
  final String? groupId, parentId, headerId;
  FlowSlice(this.sections, this.nodes, this.links, this.tree, this.groupId,
      this.parentId, this.headerId);
}

/// Condense nested control structures into navigable subflows. Connections
/// are contracted from real edges; adjacent cards never imply a connection.
FlowSlice focusFlow(Map view, String? targetSection, String? requestedGroup) {
  final root = view['flow_tree'] as Map;
  final groups = <String, Map>{}, parents = <String, String?>{};
  List<String> leaves(Map item) => item['kind'] == 'section'
      ? ['${item['id']}']
      : [
          for (final child in (item['children'] as List? ?? []).cast<Map>())
            ...leaves(child)
        ];
  String? nearest;
  void collect(Map item, String? parent) {
    if (item['kind'] == 'group') {
      final id = '${item['id']}';
      groups[id] = item;
      parents[id] = parent;
      if (leaves(item).contains(targetSection)) nearest = id;
      parent = id;
    }
    for (final child in (item['children'] as List? ?? []).cast<Map>()) {
      collect(child, parent);
    }
  }

  collect(root, null);
  final groupId = requestedGroup == '@root'
      ? null
      : groups.containsKey(requestedGroup)
          ? requestedGroup
          : nearest;
  final current = groups[groupId] ?? root;
  final owners = <String, String>{}, summaries = <String, Map>{};
  Map condense(Map item) {
    if (item['kind'] == 'group' && item['id'] != groupId) {
      final header = '${item['header']}';
      final members = leaves(item);
      for (final id in members) {
        owners[id] = header;
      }
      summaries[header] = {
        'subflow_group': item['id'],
        'subflow_sections': members.length,
        'end_line': item['end_line'],
        'subflow_nodes': (view['nodes'] as List)
            .where((n) => members.contains(n['section_id']))
            .length
      };
      return {'kind': 'section', 'id': header};
    }
    if (item['kind'] == 'section') {
      owners['${item['id']}'] = '${item['id']}';
      return item;
    }
    return {
      ...item,
      'children': [
        for (final child in (item['children'] as List? ?? []).cast<Map>())
          condense(child)
      ]
    };
  }

  final tree = condense(current);
  final visible = leaves(tree).toSet();
  final sections = <Map>[
    for (final section in (view['sections'] as List).cast<Map>())
      if (visible.contains(section['id']))
        {...section, ...?summaries[section['id']]}
  ];
  final seen = <String>{};
  final links = <Map>[];
  for (final link in (view['section_links'] as List).cast<Map>()) {
    final from = owners[link['source']], to = owners[link['target']];
    if (from == null || to == null || from == to) continue;
    final key = '$from:$to:${link['kind']}:${link['label']}';
    if (seen.add(key)) links.add({...link, 'source': from, 'target': to});
  }
  return FlowSlice(
      sections,
      (view['nodes'] as List)
          .cast<Map>()
          .where((n) => visible.contains(n['section_id']))
          .toList(),
      links,
      tree,
      groupId,
      parents[groupId],
      groups[groupId]?['header'] as String?);
}

class _Placement {
  final Size size;
  final Map<String, Rect> frames;
  final Map<String, String> labels;
  _Placement(this.size, this.frames, [Map<String, String>? labels])
      : labels = labels ?? {};
}

/// Lay out structured paths, independent of the order of the section list.
/// Folding changes section dimensions; drag offsets remain local to a section.
FlowProjection projectFlow(
    List<Map> nodes, List<Map> sections, Map tree, Set<String> folded) {
  final lookup = {for (final section in sections) '${section['id']}': section};
  _Placement place(Map item) {
    if (item['kind'] == 'section') {
      final id = '${item['id']}', section = lookup[id];
      if (section == null) return _Placement(Size.zero, {});
      final closed = folded.contains(sectionFoldKey(section)) ||
          section['subflow_group'] != null;
      final size = closed
          ? const Size(400, 148)
          : Size((section['width'] as num).toDouble(),
              (section['height'] as num).toDouble());
      return _Placement(size, {id: Offset.zero & size});
    }
    final parts =
        (item['children'] as List? ?? []).cast<Map>().map(place).toList();
    final fork = item['kind'] == 'fork';
    if (fork && parts.where((p) => p.frames.isNotEmpty).length == 1) {
      final index = parts.indexWhere((p) => p.frames.isNotEmpty);
      final part = parts[index];
      final first = part.frames.entries
          .reduce((a, b) => a.value.top <= b.value.top ? a : b);
      return _Placement(Size(part.size.width, part.size.height + 40), {
        for (final entry in part.frames.entries)
          entry.key: entry.value.shift(const Offset(0, 40))
      }, {
        ...part.labels,
        first.key: '${(item['labels'] as List)[index]}'
      });
    }
    if (!fork) parts.removeWhere((p) => p.frames.isEmpty);
    if (parts.isEmpty) return _Placement(Size.zero, {});
    final width = fork
        ? parts.fold(0.0, (w, p) => w + math.max(180, p.size.width)) +
            160 * (parts.length - 1)
        : parts.fold(0.0, (w, p) => math.max(w, p.size.width));
    final height = fork
        ? parts.fold(0.0, (h, p) => math.max(h, p.size.height)) + 40
        : parts.fold(0.0, (h, p) => h + p.size.height) +
            96 * (parts.length - 1);
    final frames = <String, Rect>{}, labels = <String, String>{};
    var cursor = 0.0;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      final offset = fork
          ? Offset(cursor, 40)
          : Offset((width - part.size.width) / 2, cursor);
      for (final entry in part.frames.entries) {
        frames[entry.key] = entry.value.shift(offset);
      }
      labels.addAll(part.labels);
      if (fork && part.frames.isNotEmpty) {
        final first = part.frames.entries
            .reduce((a, b) => a.value.top <= b.value.top ? a : b);
        labels[first.key] = '${(item['labels'] as List)[i]}';
      }
      cursor +=
          fork ? math.max(180, part.size.width) + 160 : part.size.height + 96;
    }
    return _Placement(Size(width, height), frames, labels);
  }

  final result = place(tree);
  final placed = <Map>[];
  for (final section in sections) {
    final id = '${section['id']}';
    final rect = result.frames[id]?.shift(const Offset(48, 32));
    if (rect == null) continue;
    placed.add({
      ...section,
      'rect': rect,
      'collapsed': folded.contains(sectionFoldKey(section)) ||
          section['subflow_group'] != null,
      'flow_label': result.labels[id],
      'node_count': section['subflow_nodes'] ??
          nodes.where((n) => n['section_id'] == id).length,
    });
  }
  final frames = {for (final section in placed) section['id']: section};
  return FlowProjection(
      nodes.map((node) {
        final section = frames[node['section_id']];
        if (section == null) return Map.of(node);
        final rect = section['rect'] as Rect;
        return {
          ...node,
          'x': (node['x'] as num) + rect.left - (section['x'] as num),
          'y': (node['y'] as num) + rect.top - (section['y'] as num),
          'hidden': section['collapsed'],
        };
      }).toList(),
      placed);
}
