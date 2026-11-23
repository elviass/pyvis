import 'pyvis_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'learning_scene.dart';

/// A bounded preview of a recorded value. Opening it inspects the same snapshot;
/// it never evaluates Python or expands arbitrary object properties.
String valueSummary(dynamic value, Map heap) {
  final object = value is Map ? heap[value['ref']] : null;
  if (object is Map) {
    final count = object['length'] ??
        (object['items'] as List?)?.length ??
        (object['entries'] as List?)?.length ??
        (object['attributes'] as Map?)?.length;
    final type = switch (object['type'] ?? value['type']) {
      'dict' => '字典',
      'list' => '列表',
      'tuple' => '元组',
      'set' => '集合',
      _ => '${object['name'] ?? object['type'] ?? '对象'}'
    };
    return count == null ? type : '$type · $count 项';
  }
  return plainValue(value, heap);
}

List<(String, dynamic)> valueEntries(dynamic value, Map heap) {
  final object = value is Map ? heap[value['ref']] : null;
  if (object is! Map) return [];
  if (object['items'] is List) {
    final items = object['items'] as List;
    return [for (var i = 0; i < items.length; i++) ('[$i]', items[i])];
  }
  if (object['entries'] is List) {
    return [
      for (final pair in object['entries'] as List)
        (plainValue(pair[0], heap), pair[1])
    ];
  }
  if (object['attributes'] is Map) {
    return [
      for (final entry in (object['attributes'] as Map).entries)
        ('${entry.key}', entry.value)
    ];
  }
  return [];
}

class RuntimeValueView extends StatelessWidget {
  final SceneValue value;
  final SceneValue? previous;
  final bool compact;
  const RuntimeValueView(
      {super.key, required this.value, this.previous, this.compact = false});

  void inspect(BuildContext context) => showDialog<void>(
      context: context, builder: (context) => _ValueInspector(root: value));

  @override
  Widget build(BuildContext context) {
    final entries = valueEntries(value.value, value.heap);
    final object = value.value is Map ? value.heap[value.value['ref']] : null;
    final structured = object is Map &&
        (object['items'] is List ||
            object['entries'] is List ||
            object['attributes'] is Map);
    if (!structured) {
      final text = valueSummary(value.value, value.heap);
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Text(text,
            maxLines: compact ? 2 : 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontFamily: 'JetBrains Mono',
                fontSize: compact ? 15 : 21,
                fontWeight: FontWeight.w600)),
        if (text.length > (compact ? 50 : 90) || text.contains('\n'))
          TextButton(
              onPressed: () => inspect(context), child: const Text('查看完整值'))
      ]);
    }
    final oldEntries = previous == null
        ? <String, dynamic>{}
        : Map.fromEntries(valueEntries(previous!.value, previous!.heap)
            .map((e) => MapEntry(e.$1, e.$2)));
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(valueSummary(value.value, value.heap),
              style: const TextStyle(color: Color(0xffa5c7ff), fontSize: 13)),
          const SizedBox(height: 5),
          for (final entry in entries.take(compact ? 2 : 4))
            Builder(builder: (context) {
              final changed = previous != null &&
                  (!oldEntries.containsKey(entry.$1) ||
                      plainValue(oldEntries[entry.$1], previous!.heap) !=
                          plainValue(entry.$2, value.heap));
              return Container(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  color: changed ? const Color(0xff2d4838) : null,
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                            flex: 2,
                            child: Text(entry.$1,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Color(0xffaeb6c2), fontSize: 12))),
                        const SizedBox(width: 6),
                        Expanded(
                            flex: 3,
                            child: Text(valueSummary(entry.$2, value.heap),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12)))
                      ]));
            }),
          TextButton(
              onPressed: () => inspect(context),
              child: Text(
                  entries.isEmpty ? '查看内容' : '展开内容（${entries.length} 项已记录）',
                  style: const TextStyle(fontSize: 11)))
        ]);
  }
}

class _ValueInspector extends StatefulWidget {
  final SceneValue root;
  const _ValueInspector({required this.root});

  @override
  State<_ValueInspector> createState() => _ValueInspectorState();
}

class _ValueInspectorState extends State<_ValueInspector> {
  final stack = <(String, dynamic)>[];
  static const blue = Color(0xffa5c7ff), muted = Color(0xffacb6c5);
  static const mono = TextStyle(fontFamily: 'JetBrains Mono', fontSize: 13);
  Map get heap => widget.root.heap;

  (String, dynamic) get selected =>
      stack.lastOrNull ?? (widget.root.label, widget.root.value);

  Map? object(dynamic raw) => raw is Map ? heap[raw['ref']] as Map? : null;

  bool browsable(dynamic raw) {
    final current = object(raw);
    return current != null &&
        (current['items'] is List ||
            current['entries'] is List ||
            current['attributes'] is Map ||
            current['truncated'] == true);
  }

  bool refersToAncestor(dynamic raw) {
    if (raw is! Map || raw['ref'] == null) return false;
    final root = widget.root.value;
    return root is Map && root['ref'] == raw['ref'] ||
        stack.any((step) => step.$2 is Map && step.$2['ref'] == raw['ref']);
  }

  /// Display records together when the collection has a common set of short
  /// string keys. Other collections keep the two-column key/value view.
  List<String> recordColumns(Map? current, List<(String, dynamic)> entries) {
    if (current?['type'] != 'list' && current?['type'] != 'tuple') {
      return const [];
    }
    List<String>? common;
    for (final row in entries) {
      final pairs = object(row.$2)?['entries'] as List?;
      if (pairs == null || pairs.isEmpty || pairs.length > 7) return const [];
      final names = <String>[];
      for (final pair in pairs) {
        final key = pair[0];
        final label = key is Map && key['type'] == 'str' ? key['value'] : null;
        if (label is! String || label.length > 32) {
          return const [];
        }
        names.add(label);
      }
      if (common != null &&
          (common.length != names.length || !common.every(names.contains))) {
        return const [];
      }
      common ??= names;
    }
    return common ?? const [];
  }

  @override
  Widget build(BuildContext context) {
    final (label, raw) = selected;
    final current = object(raw);
    final entries = valueEntries(raw, heap);
    final columns = recordColumns(current, entries);
    final view = MediaQuery.sizeOf(context);
    final width = (view.width - 48).clamp(160.0, 790.0);
    final maxHeight = (view.height * .55).clamp(110.0, 490.0);
    final height = entries.isEmpty
        ? (browsable(raw) ? 82.0 : 190.0).clamp(60.0, maxHeight)
        : (54 + entries.length * 38.0).clamp(110.0, maxHeight);
    return AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        titlePadding: const EdgeInsets.fromLTRB(18, 13, 18, 2),
        contentPadding: const EdgeInsets.fromLTRB(18, 9, 18, 8),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (stack.isNotEmpty)
              IconButton(
                  tooltip: '返回上一级',
                  onPressed: () => setState(stack.removeLast),
                  icon: const Icon(Icons.arrow_back, size: 18)),
            Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600))),
            if (browsable(raw))
              Text(valueSummary(raw, heap),
                  style: const TextStyle(color: muted, fontSize: 12))
          ]),
          if (stack.isNotEmpty)
            Text(
                [widget.root.label, ...stack.map((step) => step.$1)]
                    .join(' / '),
                key: const ValueKey('value-path'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: blue))
        ]),
        content: SizedBox(
            width: width,
            height: height,
            child: entries.isEmpty
                ? SingleChildScrollView(
                    child: SelectableText(
                        browsable(raw)
                            ? (current?['truncated'] == true)
                                ? '运行记录未包含内部内容'
                                : '没有元素'
                            : plainValue(raw, heap),
                        style: mono))
                : _table(current, entries, columns)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('关闭'))
        ]);
  }

  Widget _table(
      Map? current, List<(String, dynamic)> entries, List<String> columns) {
    final header = current?['entries'] is List
        ? '键'
        : current?['attributes'] is Map
            ? '属性'
            : '索引';
    final truncated = current?['truncated'] == true ||
        (current?['length'] as int? ?? entries.length) > entries.length;
    return LayoutBuilder(builder: (context, size) {
      final tableWidth = columns.isEmpty
          ? size.maxWidth
          : (86 + columns.length * 128.0).clamp(size.maxWidth, double.infinity);
      return SingleChildScrollView(
          key: ValueKey(stack.length),
          child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                  width: tableWidth,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Table(
                            columnWidths: {
                              0: columns.isEmpty
                                  ? const FlexColumnWidth(1)
                                  : const FixedColumnWidth(76)
                            },
                            defaultColumnWidth: columns.isEmpty
                                ? const FlexColumnWidth(2)
                                : const FlexColumnWidth(),
                            defaultVerticalAlignment:
                                TableCellVerticalAlignment.middle,
                            border: const TableBorder(
                                horizontalInside:
                                    BorderSide(color: PyvisColors.border)),
                            children: [
                              TableRow(
                                  decoration: const BoxDecoration(
                                      color: PyvisColors.raised),
                                  children: [
                                    for (final item in [
                                      header,
                                      ...(columns.isEmpty ? ['值'] : columns)
                                    ])
                                      Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 9, vertical: 8),
                                          child: Text(item,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontSize: 12, color: muted)))
                                  ]),
                              for (var i = 0; i < entries.length; i++)
                                _row(entries[i], columns, i.isOdd)
                            ]),
                        if (truncated)
                          Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text('此快照记录了 ${entries.length} 项',
                                  style: const TextStyle(
                                      fontSize: 12, color: muted)))
                      ]))));
    });
  }

  TableRow _row((String, dynamic) entry, List<String> columns, bool alternate) {
    final (label, raw) = entry;
    final fields = columns.isEmpty
        ? const <String, dynamic>{}
        : {
            for (final pair in object(raw)!['entries'] as List)
              pair[0]['value'] as String: pair[1]
          };
    return TableRow(
        decoration: BoxDecoration(
            color: alternate ? PyvisColors.raised : PyvisColors.surface),
        children: [
          if (columns.isEmpty)
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                child: Text(label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: mono.copyWith(color: muted)))
          else
            _cell(label, raw, shown: label),
          if (columns.isEmpty)
            _cell(label, raw)
          else
            for (final name in columns) _cell('$label.$name', fields[name])
        ]);
  }

  Widget _cell(String label, dynamic raw, {String? shown}) {
    final reference = refersToAncestor(raw);
    final text = shown ?? (reference ? '引用上层对象' : valueSummary(raw, heap));
    final open = !reference &&
        (browsable(raw) || text.length > 120 || text.contains('\n'));
    final color = open || reference
        ? blue
        : pyvisTypeColor(raw is Map ? raw['type'] as String? : null);
    final data = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 9),
        child: Row(children: [
          Expanded(
              child: Text(text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: mono.copyWith(color: color))),
          if (open && browsable(raw))
            const Icon(Icons.chevron_right, size: 15, color: blue)
        ]));
    return open
        ? InkWell(
            onTap: () => setState(() => stack.add((label, raw))), child: data)
        : data;
  }
}
