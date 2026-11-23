import 'pyvis_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'reading_flow_trace.dart';

/// One diagram for reading the source and following a recording.
class ReadingFlowView extends StatefulWidget {
  final List<Map> items;
  final int? line;
  final ReadingTrace? trace;
  final ValueChanged<int> onLine, onNodes;

  const ReadingFlowView(
      {super.key,
      required this.items,
      required this.line,
      required this.onLine,
      required this.onNodes,
      this.trace});

  @override
  State<ReadingFlowView> createState() => _ReadingFlowViewState();
}

class _ReadingFlowViewState extends State<ReadingFlowView> {
  final manual = <ReadingHop>[];
  final activeHeader = GlobalKey();
  bool following = true;
  String? lastActive;
  Object? lastRecording;
  static const muted = Color(0xffa9b1bf);
  static const blue = Color(0xffa5c7ff);
  static const routeColor = Color(0xff83dfbb);
  static const textStyle = TextStyle(fontSize: 12, color: muted);

  @override
  void didUpdateWidget(covariant ReadingFlowView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.trace != null &&
        !identical(lastRecording, widget.trace!.recording)) {
      lastRecording = widget.trace!.recording;
      following = true;
      lastActive = null;
    }
  }

  @override
  void initState() {
    super.initState();
    lastRecording = widget.trace?.recording;
  }

  void reveal(String? id) {
    if (id == lastActive) return;
    lastActive = id;
    if (id == null || !following) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = activeHeader.currentContext;
      if (!mounted || !following || lastActive != id || target == null) return;
      Scrollable.ensureVisible(target, alignment: .28);
    });
  }

  @override
  Widget build(BuildContext context) {
    final trace = widget.trace;
    final route =
        trace == null ? null : ReadingRoute.project(widget.items, trace);
    final runtime = route?.current;
    final open = trace != null && following
        ? runtime?.parents ?? const <ReadingHop>[]
        : manual;
    String? selected;
    if (trace == null && widget.line != null) {
      final position = readingPosition(widget.items, widget.line!);
      selected = position?.card['id'] as String?;
      if (position != null) {
        for (var i = 0; i < position.parents.length; i++) {
          if (i >= open.length || open[i] != position.parents[i]) {
            selected = position.parents[i].$1;
            break;
          }
        }
      }
    }
    var items = widget.items;
    var firstDepth = 0;
    final outer = <String>[];
    for (final (owner, index)
        in open.take((open.length - 4).clamp(0, open.length))) {
      final parent = items.where((item) => item['id'] == owner).firstOrNull;
      final branches = parent?['branches'] as List? ?? [];
      if (index >= branches.length) break;
      final arm = branches[index] as Map;
      outer.add(arm['label'] as String);
      items = readingChildren(arm);
      firstDepth++;
    }
    reveal(runtime?.card['id'] as String?);
    final mac = Theme.of(context).platform == TargetPlatform.macOS;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (trace != null)
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                      trace.pending
                          ? '待执行 · 第 ${trace.line} 行'
                          : '当前步骤 · 第 ${trace.line} 行',
                      style: TextStyle(
                          color: trace.pending ? blue : routeColor,
                          fontSize: 12)),
                  TextButton.icon(
                      onPressed: () => setState(() {
                            if (following) {
                              manual
                                ..clear()
                                ..addAll(open);
                            }
                            following = !following;
                            lastActive = null;
                          }),
                      icon: Icon(following ? Icons.pause : Icons.my_location,
                          size: 15),
                      label: Text(following ? '暂停跟随' : '定位当前步'))
                ])),
      if (outer.isNotEmpty)
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              TextButton(
                  onPressed: () => setState(() {
                        following = false;
                        final parent = open.take(firstDepth - 1).toList();
                        manual
                          ..clear()
                          ..addAll(parent);
                      }),
                  child: const Text('外层路径')),
              Expanded(
                  child: Text(outer.join(' / '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textStyle))
            ])),
      Expanded(
          child: items.isEmpty
              ? const Center(child: Text('这一层没有可执行的步骤'))
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                  child: Align(
                      alignment: mac ? Alignment.topLeft : Alignment.topCenter,
                      child: ConstrainedBox(
                          constraints: mac
                              ? const BoxConstraints()
                              : const BoxConstraints(maxWidth: 790),
                          child: _sequence(
                              items, open, route, selected, firstDepth)))))
    ]);
  }

  Widget _sequence(List<Map> items, List<ReadingHop> open, ReadingRoute? route,
      String? selected, int depth) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var index = 0; index < items.length; index++) ...[
        if (index > 0 && items[index - 1]['terminal'] != true)
          Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                  padding: const EdgeInsets.only(left: 13),
                  child: Icon(Icons.arrow_downward,
                      color: route?.current?.card['id'] ==
                                  items[index - 1]['id'] &&
                              route?.nextId == items[index]['id']
                          ? routeColor
                          : muted,
                      size: 17)))
        else if (index > 0)
          const SizedBox(height: 7),
        _card(items[index], open, route, selected, depth)
      ]
    ]);
  }

  Widget _card(Map item, List<ReadingHop> open, ReadingRoute? route,
      String? selection, int depth) {
    final id = item['id'] as String;
    final start = item['line'] as int;
    final end = item['end'] as int;
    final selected = selection == id;
    final running = route?.current?.card['id'] == id;
    final marker = widget.trace?.pending == true ? blue : routeColor;
    final returning = route?.loopReturn == id;
    final branch = route?.arms[id];
    final arms = (item['branches'] as List).cast<Map>();
    final opened = depth < open.length &&
            open[depth].$1 == id &&
            open[depth].$2 < arms.length
        ? open[depth].$2
        : null;
    final (icon, color) = switch (item['kind']) {
      'branch' => (Icons.alt_route, const Color(0xffe6bb79)),
      'loop' => (Icons.loop, const Color(0xffe6bb79)),
      'output' => (Icons.terminal, const Color(0xff9dd5b6)),
      'input' => (Icons.keyboard, const Color(0xff9dd5b6)),
      'data' => (Icons.data_object, blue),
      'note' => (Icons.notes, muted),
      'definition' => (Icons.functions, blue),
      'group' => (Icons.folder_open, blue),
      _ => (Icons.arrow_forward, blue)
    };
    final detail = item['detail'] as String;
    final expression = item['expression'] as String?;
    final excerpt = expression ??
        (detail.isEmpty && arms.isEmpty && item['kind'] != 'note'
            ? item['code'] as String?
            : null);
    return DecoratedBox(
        key: ValueKey('reading-card-$id'),
        decoration: BoxDecoration(
            color: running && widget.trace?.pending != true
                ? const Color(0xff203a33)
                : (selected || running)
                    ? const Color(0xff26324a)
                    : PyvisColors.surface,
            border: Border.all(
                color: running || returning
                    ? marker
                    : selected
                        ? blue
                        : PyvisColors.border),
            borderRadius: BorderRadius.circular(8)),
        child: Padding(
            padding: const EdgeInsets.fromLTRB(9, 8, 9, 8),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InkWell(
                      key: running ? activeHeader : null,
                      onTap: () => widget.onLine(start),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                                padding: const EdgeInsets.only(top: 1),
                                child: Icon(running ? Icons.play_arrow : icon,
                                    color: running ? marker : color, size: 18)),
                            const SizedBox(width: 7),
                            Expanded(
                                child: Text(item['title'] as String,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600))),
                            const SizedBox(width: 7),
                            Text(start == end ? 'L$start' : 'L$start–$end',
                                style: textStyle)
                          ])),
                  if (detail.isNotEmpty)
                    Padding(
                        padding: const EdgeInsets.fromLTRB(25, 2, 0, 2),
                        child: Text(detail, style: textStyle)),
                  if (excerpt != null && excerpt.isNotEmpty)
                    Padding(
                        padding: const EdgeInsets.fromLTRB(25, 5, 0, 2),
                        child: Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 3),
                                decoration: BoxDecoration(
                                    color: const Color(0xff1d222a),
                                    borderRadius: BorderRadius.circular(4)),
                                child: Text(excerpt,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontFamily: 'JetBrains Mono',
                                        fontSize: 12,
                                        color: Color(0xffc3d0e3)))))),
                  if (arms.isNotEmpty)
                    Padding(
                        padding: const EdgeInsets.only(top: 7),
                        child: LayoutBuilder(builder: (context, size) {
                          final lanes = [
                            for (var i = 0; i < arms.length; i++)
                              _arm(arms[i], id, i, opened == i, branch == i,
                                  open, depth)
                          ];
                          if (size.maxWidth >= 375 && lanes.length == 2) {
                            return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: lanes[0]),
                                  const SizedBox(width: 6),
                                  Expanded(child: lanes[1])
                                ]);
                          }
                          return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: lanes);
                        })),
                  if (opened != null &&
                      readingChildren(arms[opened]).isNotEmpty)
                    Container(
                        margin:
                            EdgeInsets.only(left: depth < 3 ? 5 : 0, top: 4),
                        padding: EdgeInsets.only(left: depth < 3 ? 7 : 2),
                        decoration: BoxDecoration(
                            border: Border(
                                left: BorderSide(
                                    width: 2,
                                    color: branch == opened
                                        ? routeColor
                                        : const Color(0xff475366)))),
                        child: _sequence(readingChildren(arms[opened]), open,
                            route, selection, depth + 1)),
                  if (item['kind'] == 'loop')
                    Padding(
                        padding: const EdgeInsets.only(left: 5, top: 5),
                        child: Row(children: [
                          Icon(Icons.keyboard_return,
                              size: 16, color: returning ? routeColor : muted),
                          const SizedBox(width: 6),
                          Expanded(
                              child: Text(returning ? '实际返回循环检查' : '继续循环时，回到检查',
                                  key: returning
                                      ? ValueKey('reading-return-$id')
                                      : null,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: returning ? routeColor : muted)))
                        ])),
                  if ((selected || running) &&
                      !const ['group', 'note'].contains(item['kind']))
                    Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                            onPressed: () => widget.onNodes(start),
                            child: const Text('查看本行节点')))
                ])));
  }

  Widget _arm(Map arm, String id, int index, bool opened, bool actual,
      List<ReadingHop> open, int depth) {
    final first = readingChildren(arm).firstOrNull;
    final note = first == null ? arm['empty'] as String : 'L${first['line']}';
    final code = first?['code'] as String? ?? '';
    final useCode = code.isNotEmpty &&
        const ['Assign', 'AnnAssign', 'AugAssign', 'Expr', 'Return', 'Raise']
            .contains(first?['syntax']);
    final preview = !opened && arm['role'] != null
        ? (useCode ? code : first?['title'] as String?)
        : null;
    return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Material(
            color: actual ? const Color(0xff29473e) : PyvisColors.raised,
            borderRadius: BorderRadius.circular(6),
            child: InkWell(
                key: actual ? ValueKey('reading-taken-$id-$index') : null,
                borderRadius: BorderRadius.circular(6),
                onTap: first == null
                    ? null
                    : () {
                        setState(() {
                          following = false;
                          final keep = open.take(depth).toList();
                          manual
                            ..clear()
                            ..addAll(keep);
                          if (!opened) manual.add((id, index));
                        });
                        if (!opened) widget.onLine(first['line'] as int);
                      },
                child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                    actual
                                        ? Icons.check_circle_outline
                                        : opened
                                            ? Icons.expand_more
                                            : Icons.chevron_right,
                                    color: actual ? routeColor : blue,
                                    size: 16),
                                const SizedBox(width: 5),
                                Expanded(
                                    child: Text(arm['label'] as String,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            color: actual ? routeColor : null,
                                            fontSize: 12))),
                                if (first != null) ...[
                                  const SizedBox(width: 5),
                                  Text(note, style: textStyle)
                                ]
                              ]),
                          if (preview != null ||
                              first == null && note.isNotEmpty)
                            Padding(
                                padding:
                                    const EdgeInsets.only(left: 21, top: 3),
                                child: Text(preview ?? note,
                                    style: useCode
                                        ? textStyle.copyWith(
                                            fontFamily: 'JetBrains Mono')
                                        : textStyle,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis))
                        ])))));
  }
}
