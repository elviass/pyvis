import 'pyvis_theme.dart';
import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';
import 'python_completion.dart';
import 'inspection_style.dart';

int pythonColumnOffset(String text, int column) =>
    String.fromCharCodes(text.runes.take(math.max(0, column - 1))).length;

class InlineCodeSuggestion {
  final String source, suffix;
  final int line, column;
  const InlineCodeSuggestion(this.source, this.line, this.column, this.suffix);
}

/// Context continuations stay in the presentation layer until Tab accepts them.
InlineCodeSuggestion? inlineSuggestion(
    CodeLineEditingController editor, Map analysis) {
  final selection = editor.selection;
  if (!selection.isCollapsed || editor.isComposing) return null;
  final lines = editor.text.split('\n');
  final line = editor.index2lineIndex(selection.extentIndex),
      column = selection.extentOffset;
  if (line >= lines.length || column != lines[line].length) return null;
  final prefix = lines[line];
  if (!pythonCodePosition([...lines.take(line), prefix].join('\n'))) {
    return null;
  }
  final indent = RegExp(r'^\s*').firstMatch(prefix)![0]!;
  final typed = prefix.substring(indent.length);
  if (typed.isEmpty) return null;
  final following = lines.skip(line + 1).where((s) => s.trim().isNotEmpty);
  final hasBody = following.isNotEmpty &&
      RegExp(r'^\s*').firstMatch(following.first)![0]!.length > indent.length;
  final symbols = ((analysis['symbols'] as List?) ?? []).cast<Map>().where((s) {
    final start = s['start'] as int? ?? 0, end = s['end'] as int? ?? 0;
    return (start == 0 || (line + 1 >= start && line + 1 <= end + 1)) &&
        (s['line'] as int? ?? 0) <= line + 1;
  }).toList()
    ..sort(
        (a, b) => (b['line'] as int? ?? 0).compareTo(a['line'] as int? ?? 0));
  final candidates = <String>[];
  if (RegExp(r'^for(?:\s|$)').hasMatch(typed)) {
    final parts = RegExp(r'^for\s+(.*?)\s+in(?:\s+(.*))?$').firstMatch(typed);
    var variables =
        parts?.group(1) ?? typed.replaceFirst(RegExp(r'^for\s*'), '');
    // The final 'in' may still be a partially entered keyword.
    variables = variables.replaceFirst(RegExp(r'\s+i(?:n)?$'), '');
    final valid = RegExp(r'^[A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]*\w*)?$');
    if (variables.isNotEmpty && !valid.hasMatch(variables)) return null;
    final explicit = variables.isNotEmpty;
    final pair = variables.contains(',');
    for (final symbol in symbols) {
      final name = '${symbol['name']}';
      final kind = '${symbol['detail']}';
      if (kind == 'dict') {
        var binding = explicit ? variables : 'key, value';
        if (binding.trimRight().endsWith(',')) binding += ' value';
        final items = !explicit || pair;
        final iterable = items ? '$name.items()' : name;
        candidates.add(
            'for $binding in $iterable:${hasBody ? '' : '\n$indent    print($binding)'}');
        if (!explicit) {
          candidates.add(
              'for key in $name:${hasBody ? '' : '\n$indent    print(key)'}');
        }
      } else if (const ['list', 'tuple', 'set', 'str', 'range']
          .contains(kind)) {
        var binding = explicit ? variables : 'item';
        if (binding.trimRight().endsWith(',')) binding += ' item';
        final iterable = pair ? 'enumerate($name)' : name;
        candidates.add(
            'for $binding in $iterable:${hasBody ? '' : '\n$indent    print($binding)'}');
      } else if (kind == 'int') {
        final binding = explicit ? variables : 'i';
        if (!pair) {
          candidates.add(
              'for $binding in range($name):${hasBody ? '' : '\n$indent    print($binding)'}');
        }
      }
    }
  } else if (RegExp(r'^try\s*:?$').hasMatch(typed)) {
    candidates.add(
        'try:${hasBody ? '' : '\n$indent    pass\n${indent}except Exception as error:\n$indent    print(error)'}');
  } else if (RegExp(r'^while(?:\s|$)').hasMatch(typed)) {
    for (final symbol in symbols.where((s) => s['detail'] == 'bool')) {
      candidates.add(
          'while ${symbol['name']}:${hasBody ? '' : '\n$indent    break'}');
    }
    candidates.add('while True:${hasBody ? '' : '\n$indent    break'}');
  } else if (RegExp(r'^def [A-Za-z_]\w*(?:\(\))?:?$').hasMatch(typed)) {
    final name = RegExp(r'^def ([A-Za-z_]\w*)').firstMatch(typed)!.group(1)!;
    candidates.add('def $name():${hasBody ? '' : '\n$indent    pass'}');
  } else if (RegExp(r'^if(?:\s|$)').hasMatch(typed)) {
    for (final symbol in symbols.where((s) => const [
          'bool',
          'list',
          'dict',
          'str',
          'set',
          'tuple'
        ].contains(s['detail']))) {
      candidates
          .add('if ${symbol['name']}:${hasBody ? '' : '\n$indent    pass'}');
    }
  }
  // Commas can be typed with or without spaces; do not rewrite what was typed.
  String compact(String value) =>
      value.replaceAll(RegExp(r'(?<=,)\s+|\s+(?=,)'), '');
  for (final candidate in candidates) {
    var consumed = 0;
    while (consumed <= candidate.length &&
        compact(candidate.substring(0, consumed)) != compact(typed)) {
      consumed++;
    }
    if (consumed < candidate.length) {
      return InlineCodeSuggestion(
          editor.text, line, column, candidate.substring(consumed));
    }
  }
  // A previously written statement in the same file is a valid continuation,
  // but a definition/assignment target must never be copied automatically.
  if (typed.length >= 3 &&
      !RegExp(r'^(?:def|class|import|from)\b').hasMatch(typed) &&
      !typed.contains('=')) {
    for (final previous in lines.take(line).toList().reversed) {
      final statement = previous.trim();
      if (statement.startsWith(typed) &&
          statement.length > typed.length &&
          !statement.endsWith(':') &&
          !RegExp(r'(?<![=!<>])=(?!=)').hasMatch(statement)) {
        return InlineCodeSuggestion(
            editor.text, line, column, statement.substring(typed.length));
      }
    }
  }
  return null;
}

class EditorDecorations extends CodeParagraphDecorator {
  final CodeLineEditingController editor;
  final FocusNode focus;
  final void Function(Map<String, dynamic>, Rect)? onHover;
  final VoidCallback? onHoverExit;
  Map analysis = {};
  List<Map<String, dynamic>> diagnostics = [];
  InlineCodeSuggestion? ghost;
  InlineCodeSuggestion? _modelGhost;
  bool modelMode = false;
  List<List<int>> activeBrackets = [];
  String? _diagnosticSource, _inlineSource, _suppressed;
  EditorDecorations(this.editor, this.focus, {this.onHover, this.onHoverExit}) {
    editor.addListener(_changed);
    focus.addListener(_changed);
  }
  String get _position =>
      '${editor.text}\u0000${editor.selection.extentIndex}:${editor.selection.extentOffset}';
  void setAnalysis(Map data, String source, List<Map<String, dynamic>> issues) {
    if (source != editor.text) return;
    analysis = data;
    _inlineSource = source;
    diagnostics = issues;
    _diagnosticSource = source;
    _changed(force: true);
  }

  void setContext(Map data, String source) {
    if (source != editor.text) return;
    analysis = {...analysis, ...data};
    _inlineSource = source;
    _changed(force: true);
  }

  void setModelPrediction(String source, int line, int column, String suffix) {
    if (source != editor.text ||
        line != editor.index2lineIndex(editor.selection.extentIndex) ||
        column != editor.selection.extentOffset) {
      return;
    }
    _modelGhost = InlineCodeSuggestion(source, line, column, suffix);
    _changed(force: true);
  }

  bool get _contextMatches {
    final snapshot = _inlineSource;
    if (snapshot == null) return false;
    if (snapshot == editor.text) return true;
    final line = editor.index2lineIndex(editor.selection.extentIndex);
    return snapshot.split('\n').take(line).join('\n') ==
        editor.text.split('\n').take(line).join('\n');
  }

  void clearForFile() {
    analysis = {};
    diagnostics = [];
    _diagnosticSource = null;
    _inlineSource = null;
    ghost = null;
    _modelGhost = null;
    _suppressed = null;
    notifyListeners();
  }

  InlineCodeSuggestion? _carryModelPrediction(
      String source, int line, int column) {
    final previous = _modelGhost;
    if (previous == null || previous.source == source) return previous;
    final consumed = column - previous.column;
    if (ghost == null ||
        !focus.hasFocus ||
        !editor.selection.isCollapsed ||
        editor.isComposing ||
        previous.line != line ||
        consumed <= 0 ||
        consumed >= previous.suffix.length ||
        source.length != previous.source.length + consumed) {
      return null;
    }
    final typed = previous.suffix.substring(0, consumed);
    if (typed.contains('\n')) return null;
    final rows = previous.source.split('\n');
    final offset = rows.take(line).fold<int>(0, (n, row) => n + row.length + 1) +
        previous.column;
    // Applying the remaining preview must produce the same already validated code.
    if (previous.source.replaceRange(offset, offset, typed) != source) return null;
    return InlineCodeSuggestion(
        source, line, column, previous.suffix.substring(consumed));
  }

  void _changed({bool force = false}) {
    if (_diagnosticSource != editor.text && diagnostics.isNotEmpty) {
      diagnostics = [];
      force = true;
    }
    final sourceLine = editor.index2lineIndex(editor.selection.extentIndex) + 1;
    final text = editor.codeLines[editor.selection.extentIndex].text;
    final column =
        text.substring(0, editor.selection.extentOffset).runes.length;
    final nextBrackets = <List<int>>[];
    if (_diagnosticSource == editor.text && focus.hasFocus) {
      for (final pair in (analysis['brackets'] as List? ?? [])) {
        final points = [
          (pair['start'] as List).cast<int>(),
          (pair['end'] as List).cast<int>()
        ];
        if (points.any((point) =>
            point[0] == sourceLine &&
            (point[1] == column || point[1] + 1 == column))) {
          nextBrackets.addAll(points);
          break;
        }
      }
    }
    if (nextBrackets.toString() != activeBrackets.toString()) {
      force = true;
      activeBrackets = nextBrackets;
    }
    final model = _modelGhost = _carryModelPrediction(
        editor.text, sourceLine - 1, editor.selection.extentOffset);
    final modelMatches = model?.source == editor.text &&
        model?.line == sourceLine - 1 &&
        model?.column == editor.selection.extentOffset;
    final next = focus.hasFocus &&
            !editor.isComposing &&
            (modelMode || _contextMatches) &&
            _suppressed != _position
        ? (modelMode
            ? (modelMatches ? model : null)
            : inlineSuggestion(editor, analysis))
        : null;
    if (!force &&
        next?.source == ghost?.source &&
        next?.line == ghost?.line &&
        next?.column == ghost?.column &&
        next?.suffix == ghost?.suffix) {
      return;
    }
    ghost = next;
    notifyListeners();
  }

  bool acceptInline() {
    final value = ghost;
    if (value == null ||
        value.source != editor.text ||
        value.line != editor.index2lineIndex(editor.selection.extentIndex) ||
        value.column != editor.selection.extentOffset) {
      return false;
    }
    ghost = null;
    editor.replaceSelection(value.suffix);
    onHoverExit?.call();
    return true;
  }

  bool dismissInline() {
    if (ghost == null) return false;
    _suppressed = _position;
    ghost = null;
    notifyListeners();
    return true;
  }

  @override
  IParagraph decorate(
      int index, IParagraph paragraph, TextStyle style, double maxWidth) {
    final line = editor.index2lineIndex(index);
    final source = editor.text.split('\n')[line];
    final issues = diagnostics
        .where((d) =>
            d['line'] <= line + 1 && (d['end_line'] ?? d['line']) >= line + 1)
        .map((d) => <String, dynamic>{
              ...d,
              '_original': d,
              'column': d['line'] == line + 1 ? d['column'] : 1,
              'end_column': (d['end_line'] ?? d['line']) == line + 1
                  ? d['end_column']
                  : source.runes.length + 1
            })
        .toList()
      ..sort((a, b) => InspectionStyle.forIssue(b)
          .priority
          .compareTo(InspectionStyle.forIssue(a).priority));
    final inline = ghost?.line == line ? ghost!.suffix : null;
    final brackets = activeBrackets
        .where((point) => point[0] == line + 1)
        .map((point) => pythonColumnOffset(source, point[1] + 1))
        .toList();
    final indent = RegExp(r'^ +').firstMatch(source)?[0]?.length ?? 0;
    if (issues.isEmpty && inline == null && brackets.isEmpty && indent == 0) {
      return paragraph;
    }
    return DecoratedCodeParagraph(paragraph, source, style, maxWidth,
        issues: issues,
        bracketOffsets: brackets,
        indentColumns: indent,
        ghostText: inline,
        onHover: onHover,
        onHoverExit: onHoverExit);
  }

  @override
  void dispose() {
    editor.removeListener(_changed);
    focus.removeListener(_changed);
    super.dispose();
  }
}

class DecoratedCodeParagraph implements IParagraph {
  final IParagraph base;
  final String source;
  final List<Map<String, dynamic>> issues;
  final String? ghostText;
  final List<int> bracketOffsets;
  final int indentColumns;
  late final double _spaceWidth;
  final void Function(Map<String, dynamic>, Rect)? onHover;
  final VoidCallback? onHoverExit;
  final List<TextPainter> _ghostPainters = [];
  final Map<InlineSpan, TextRange> _spans = {};
  late final Offset _end;
  double _extraHeight = 0, _width = 0;
  DecoratedCodeParagraph(
      this.base, this.source, TextStyle style, double maxWidth,
      {this.issues = const [],
      this.bracketOffsets = const [],
      this.indentColumns = 0,
      this.ghostText,
      this.onHover,
      this.onHoverExit}) {
    _end = base.getOffset(TextPosition(offset: source.length)) ?? Offset.zero;
    _width = base.width;
    final space = TextPainter(
        text: TextSpan(text: ' ', style: style),
        textDirection: TextDirection.ltr)
      ..layout();
    _spaceWidth = space.width;
    space.dispose();
    if (ghostText != null) {
      final pieces = ghostText!.split('\n');
      for (var i = 0; i < pieces.length; i++) {
        final painter = TextPainter(
            text: TextSpan(
                text: pieces[i].isEmpty ? ' ' : pieces[i],
                style: style.copyWith(color: const Color(0xff777b84))),
            textDirection: TextDirection.ltr)
          ..layout(
              maxWidth: maxWidth.isFinite
                  ? math.max(40, maxWidth - (i == 0 ? _end.dx : 0))
                  : double.infinity);
        _ghostPainters.add(painter);
        _width = math.max(_width, painter.width + (i == 0 ? _end.dx : 0));
        _extraHeight += painter.height;
      }
      _extraHeight = math.max(0, _extraHeight - base.preferredLineHeight);
    }
    for (final issue in issues) {
      final range = issueRange(issue);
      final span = MouseTrackerAnnotationTextSpan(
          text: source.substring(range.start, range.end),
          onEnterWithRect: (_, __, rects) {
            if (rects.isNotEmpty) {
              onHover?.call(
                  (issue['_original'] as Map<String, dynamic>?) ?? issue,
                  rects.first);
            }
          },
          onExitWithRect: (_, __, ___) => onHoverExit?.call());
      _spans[span] = range;
    }
  }
  TextRange issueRange(Map issue) {
    final start =
        pythonColumnOffset(source, (issue['column'] as num?)?.toInt() ?? 1)
            .clamp(0, source.length);
    final end = pythonColumnOffset(
            source,
            (issue['end_column'] as num?)?.toInt() ??
                (issue['column'] as num?)?.toInt() ??
                1)
        .clamp(start, source.length);
    if (end > start) return TextRange(start: start, end: end);
    if (start < source.length) return TextRange(start: start, end: start + 1);
    return TextRange(start: start, end: start);
  }

  @override
  double get width => _width;
  @override
  double get height => base.height + _extraHeight;
  @override
  double get preferredLineHeight => base.preferredLineHeight;
  @override
  bool get trucated => base.trucated;
  @override
  int get length => base.length;
  @override
  int get lineCount => base.lineCount;
  @override
  TextPosition getPosition(Offset offset) => offset.dy >= base.height
      ? TextPosition(offset: source.length)
      : base.getPosition(offset);
  @override
  TextRange getWord(Offset offset) => base.getWord(offset);
  @override
  InlineSpan? getSpanForPosition(TextPosition position) {
    for (final entry in _spans.entries) {
      if (position.offset >= entry.value.start &&
          position.offset < entry.value.end) {
        return entry.key;
      }
    }
    return base.getSpanForPosition(position);
  }

  @override
  TextRange getRangeForSpan(InlineSpan span) =>
      _spans[span] ?? base.getRangeForSpan(span);
  @override
  TextRange getLineBoundary(TextPosition position) =>
      base.getLineBoundary(position);
  @override
  Offset? getOffset(TextPosition position) => base.getOffset(position);
  @override
  List<Rect> getRangeRects(TextRange range) => base.getRangeRects(range);
  @override
  void draw(Canvas canvas, Offset offset) {
    final guide = Paint()
      ..color = const Color(0xff383a40)
      ..strokeWidth = 1;
    for (var column = 0; column < indentColumns; column += 4) {
      canvas.drawLine(offset + Offset(column * _spaceWidth, 0),
          offset + Offset(column * _spaceWidth, base.height), guide);
    }
    for (final position in bracketOffsets) {
      for (final rect in base
          .getRangeRects(TextRange(start: position, end: position + 1))) {
        canvas.drawRect(rect.shift(offset).inflate(1),
            Paint()..color = const Color(0xff3b4c69));
      }
    }
    final faded = <Rect>[
      for (final issue
          in issues.where((d) => InspectionStyle.forIssue(d).faded))
        ...base.getRangeRects(issueRange(issue)).map((r) => r.shift(offset))
    ];
    if (faded.isEmpty) {
      base.draw(canvas, offset);
    } else {
      var visible = Path()
        ..addRect(offset & Size(math.max(width, base.width), height));
      for (final rect in faded) {
        visible = Path.combine(
            PathOperation.difference, visible, Path()..addRect(rect));
      }
      canvas.save();
      canvas.clipPath(visible);
      base.draw(canvas, offset);
      canvas.restore();
      for (final rect in faded) {
        canvas.save();
        canvas.clipRect(rect);
        canvas.saveLayer(
            rect,
            Paint()
              ..colorFilter =
                  const ColorFilter.mode(Color(0xff6f737a), BlendMode.srcIn));
        base.draw(canvas, offset);
        canvas.restore();
        canvas.restore();
      }
    }
    final covered = <TextRange>[];
    for (final issue in issues) {
      final style = InspectionStyle.forIssue(issue);
      if (!style.wave) continue;
      final range = issueRange(issue);
      var pieces = <TextRange>[range];
      for (final higher in covered) {
        pieces = [
          for (final piece in pieces) ...[
            if (higher.end <= piece.start || higher.start >= piece.end)
              piece
            else ...[
              if (higher.start > piece.start)
                TextRange(start: piece.start, end: higher.start),
              if (higher.end < piece.end)
                TextRange(start: higher.end, end: piece.end)
            ]
          ]
        ];
      }
      covered.add(range);
      for (final piece in pieces) {
        var rects = base.getRangeRects(piece);
        if (rects.isEmpty && piece.isCollapsed) {
          final point =
              base.getOffset(TextPosition(offset: piece.start)) ?? Offset.zero;
          rects = [
            Rect.fromLTWH(point.dx, point.dy, _spaceWidth, preferredLineHeight)
          ];
        }
        for (final rect in rects) {
          final box = rect.shift(offset);
          canvas.save();
          canvas.clipRect(
              Rect.fromLTRB(box.left, box.bottom - 3.2, box.right, box.bottom));
          canvas.drawPath(
              inspectionWave(box),
              Paint()
                ..color = style.color
                ..style = PaintingStyle.stroke
                ..strokeWidth = .7
                ..isAntiAlias = true);
          canvas.restore();
        }
      }
    }
    var y = _end.dy;
    for (var i = 0; i < _ghostPainters.length; i++) {
      final painter = _ghostPainters[i];
      painter.paint(canvas, offset + Offset(i == 0 ? _end.dx : 0, y));
      y += painter.height;
    }
    if (_ghostPainters.isNotEmpty) {
      final last = _ghostPainters.last;
      final tip = TextPainter(
          text: const TextSpan(
              text: 'Tab 以补全',
              style: TextStyle(color: Color(0xff9398a4), fontSize: 11)),
          textDirection: TextDirection.ltr)
        ..layout();
      tip.paint(
          canvas,
          offset +
              Offset(
                  ((_ghostPainters.length == 1) ? _end.dx : 0) +
                      last.width +
                      12,
                  y - last.height + 3));
    }
  }
}

/// One overview scrollbar beside the minimap, with clickable diagnostic marks.
class InspectionStripe extends StatelessWidget {
  final List<Map<String, dynamic>> diagnostics;
  final int lineCount;
  final ValueChanged<Map<String, dynamic>> onSelect;
  final ScrollController? scrollController;
  final Listenable? geometry;
  const InspectionStripe(
      {super.key,
      required this.diagnostics,
      required this.lineCount,
      required this.onSelect,
      this.scrollController,
      this.geometry});
  @override
  Widget build(BuildContext context) => SizedBox(
      width: 8,
      child: AnimatedBuilder(
          animation: Listenable.merge([
            if (scrollController != null) scrollController!,
            if (geometry != null) geometry!
          ]),
          builder: (context, _) =>
              LayoutBuilder(builder: (context, constraints) {
                final height = constraints.maxHeight;
                final controller = scrollController;
                final position = controller?.hasClients == true
                    ? controller!.positions.last
                    : null;
                final extent = position?.hasContentDimensions == true
                    ? position!.maxScrollExtent
                    : 0.0;
                final viewport = position?.hasViewportDimension == true
                    ? position!.viewportDimension
                    : height;
                final thumbHeight = (height *
                        viewport /
                        (viewport + extent).clamp(1, double.infinity))
                    .clamp(math.min(24, height), height)
                    .toDouble();
                final track =
                    (height - thumbHeight).clamp(1, double.infinity).toDouble();
                final top = extent <= 0
                    ? 0.0
                    : ((position!.pixels / extent).clamp(0, 1) * track)
                        .toDouble();
                void jump(double offset) =>
                    position?.jumpTo(offset.clamp(0, extent));
                return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: extent <= 0
                        ? null
                        : (d) => jump((d.localPosition.dy - thumbHeight / 2) /
                            track *
                            extent),
                    child: ColoredBox(
                        color: PyvisColors.canvas,
                        child: Stack(children: [
                          if (extent > 0)
                            Positioned(
                                key: const ValueKey('editor-overview-thumb'),
                                left: 0,
                                right: 1,
                                top: top,
                                height: thumbHeight,
                                child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onVerticalDragUpdate: (d) => jump(
                                        (position?.pixels ?? 0) +
                                            d.delta.dy / track * extent),
                                    child: DecoratedBox(
                                        decoration: BoxDecoration(
                                            color: const Color(0xff494b50),
                                            borderRadius:
                                                BorderRadius.circular(4))))),
                          for (var i = 0; i < diagnostics.length; i++)
                            if (InspectionStyle.forIssue(diagnostics[i]).stripe !=
                                null)
                              Positioned(
                                  key: ValueKey('inspection-mark-$i'),
                                  left: 0,
                                  right: 0,
                                  top: (((diagnostics[i]['line'] as num).toDouble() - 1) /
                                          math.max(1, lineCount - 1) *
                                          (height - 6))
                                      .clamp(0, math.max(0, height - 4)),
                                  child: Tooltip(
                                      message:
                                          '${diagnostics[i]['message']}\n第 ${diagnostics[i]['line']} 行',
                                      child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () => onSelect(diagnostics[i]),
                                          child: Container(
                                              height: 6,
                                              alignment: Alignment.center,
                                              child: Container(
                                                  height: 3,
                                                  color: InspectionStyle.forIssue(
                                                          diagnostics[i])
                                                      .stripe)))))
                        ])));
              })));
}

/// Chooses a full row above/below the caret without covering source or lookup.
Rect? placeParameterHint(Rect caret, Size size, Rect viewport, {Rect? avoid}) {
  if (size.width <= 0 ||
      size.height <= 0 ||
      viewport.height < size.height ||
      caret.bottom < viewport.top ||
      caret.top > viewport.bottom ||
      size.width > viewport.width) {
    return null;
  }
  final left =
      caret.left.clamp(viewport.left, viewport.right - size.width).toDouble();
  final currentLine =
      Rect.fromLTRB(viewport.left, caret.top, viewport.right, caret.bottom);
  final tops = [
    caret.top - size.height - 6,
    caret.bottom + 6,
    if (avoid != null) avoid.bottom + 6,
    if (avoid != null) avoid.top - size.height - 6
  ];
  for (final top in tops) {
    final box = Rect.fromLTWH(left, top, size.width, size.height);
    if (box.top < viewport.top ||
        box.bottom > viewport.bottom ||
        box.overlaps(currentLine) ||
        (avoid != null && box.overlaps(avoid))) {
      continue;
    }
    return box;
  }
  return null;
}

class ParameterHint extends StatelessWidget {
  static const height = 30.0;
  final Map<String, dynamic> signature;
  const ParameterHint({super.key, required this.signature});
  @override
  Widget build(BuildContext context) {
    final parameters = (signature['parameters'] as List? ?? []).cast<String>();
    final selected = (signature['index'] as num?)?.toInt();
    return Container(
        key: const ValueKey('parameter-hint'),
        height: height,
        alignment: Alignment.centerLeft,
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
            color: PyvisColors.raised,
            border: Border.all(color: const Color(0xff56585c)),
            borderRadius: BorderRadius.circular(5),
            boxShadow: const [
              BoxShadow(color: Color(0x50000000), blurRadius: 6)
            ]),
        child: RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
                style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'JetBrains Mono',
                    color: Color(0xffbfc0c5)),
                children: [
                  TextSpan(text: '${signature['name']}('),
                  for (var i = 0; i < parameters.length; i++) ...[
                    if (i > 0) const TextSpan(text: ', '),
                    TextSpan(
                        text: parameters[i],
                        style: i == selected
                            ? const TextStyle(
                                color: PyvisColors.accent,
                                fontWeight: FontWeight.bold)
                            : null)
                  ],
                  const TextSpan(text: ')')
                ])));
  }
}
