/// The facts available at one replay position, in that invocation's frame.
class ReadingTrace {
  final Object recording;
  final int sequence, line;
  final int? column, nextLine, nextColumn;
  final String? syntax, function;
  final bool? taken;
  final bool pending;

  const ReadingTrace(
      {required this.recording,
      required this.sequence,
      required this.line,
      this.column,
      this.nextLine,
      this.nextColumn,
      this.syntax,
      this.function,
      this.taken,
      this.pending = false});

  static ReadingTrace? forEvent(Map? event, List<Map<String, dynamic>> events) {
    if (event == null || event['line'] is! int || event['line'] <= 0) {
      return null;
    }
    final sequence = event['seq'] as int;
    final kind = event['kind'];
    final statement = kind == 'statement';
    final frames = event['frames'] as List? ?? [];
    final frame = frames.lastOrNull as Map?;
    final frameId = frame?['id'];
    final exception = event['outcome'] == 'exception';
    var nextLine = event['next_line'] as int?;
    var nextColumn = event['next_column'] as int?;
    // Older saved traces have no next_line. A handled exception likewise gets
    // its destination from the first subsequent line in this same invocation.
    if ((statement && (!event.containsKey('next_line') || exception)) &&
        frameId != null) {
      for (var i = sequence + 1; i < events.length; i++) {
        final observed = events[i];
        final stack = observed['frames'] as List? ?? [];
        if (stack.isEmpty || stack.last['id'] != frameId) continue;
        if (observed['kind'] == 'return') break;
        if (observed['kind'] == 'line' && observed['file'] == event['file']) {
          nextLine = observed['line'] as int?;
          nextColumn = observed['column'] as int?;
          break;
        }
      }
    }
    return ReadingTrace(
        recording: events,
        sequence: sequence,
        line: event['line'] as int,
        column: event['column'] as int?,
        nextLine: nextLine,
        nextColumn: nextColumn,
        syntax: event['statement_type'] as String?,
        function: kind == 'call' ? (frame?['name'] as String?) : null,
        taken: event['branch_taken'] as bool?,
        pending: !statement && kind != 'call');
  }
}

typedef ReadingHop = (String, int);

class ReadingPosition {
  final Map card;
  final List<ReadingHop> parents;
  const ReadingPosition(this.card, this.parents);
}

List<Map> readingChildren(Map arm) => (arm['items'] as List? ?? []).cast<Map>();

/// Locates an AST card in this file. An exact header wins over its suite;
/// grouping and multiline expressions still keep their owning source span.
ReadingPosition? readingPosition(List<Map> items, int line,
    {int? column, String? syntax, String? function}) {
  ReadingPosition? best;
  var bestRank = -1;
  void visit(List<Map> cards, List<ReadingHop> parents) {
    for (final card in cards) {
      final start = card['line'] as int;
      final entry =
          function != null && card['name'] == function && card['entry'] == line;
      if ((!entry &&
              start > line &&
              !(function != null && card['kind'] == 'group')) ||
          (card['end'] as int) < line) {
        continue;
      }
      final arms = (card['branches'] as List).cast<Map>();
      if (card['kind'] != 'group') {
        final exact = start == line || entry;
        final exactColumn = column != null && card['id'] == '$line:$column';
        final rank = parents.length +
            (exact ? 10000 : 0) +
            (exact &&
                    (syntax != null && card['syntax'] == syntax ||
                        function != null && card['name'] == function)
                ? 20000
                : 0) +
            (exactColumn ? 40000 : 0);
        // Legacy traces cannot distinguish two statements on a single line.
        // Prefer the containing header when both start on that line.
        final score =
            exact && column == null && syntax == null && function == null
                ? rank - 2 * parents.length
                : rank;
        if (score > bestRank) {
          bestRank = score;
          best = ReadingPosition(card, parents);
        }
      }
      for (var i = 0; i < arms.length; i++) {
        visit(
            readingChildren(arms[i]), [...parents, (card['id'] as String, i)]);
      }
    }
  }

  visit(items, const []);
  return best;
}

class ReadingRoute {
  final ReadingPosition? current;
  final Map<String, int> arms;
  final String? loopReturn, nextId;
  const ReadingRoute(this.current, this.arms, this.loopReturn, this.nextId);

  factory ReadingRoute.project(List<Map> items, ReadingTrace trace) {
    final current = readingPosition(items, trace.line,
        column: trace.column, syntax: trace.syntax, function: trace.function);
    if (current == null) return const ReadingRoute(null, {}, null, null);
    final card = current.card;
    final id = card['id'] as String;
    final next = trace.nextLine == null
        ? null
        : readingPosition(items, trace.nextLine!, column: trace.nextColumn);
    final arms = {for (final (owner, arm) in current.parents) owner: arm};
    final branches = (card['branches'] as List).cast<Map>();
    final nextArm = next?.parents.where((hop) => hop.$1 == id).firstOrNull;
    final choice = trace.taken == true
        ? 'taken'
        : trace.taken == false
            ? card['kind'] == 'loop'
                ? 'exhausted'
                : 'skipped'
            : null;
    if (!trace.pending && choice != null) {
      final index = branches.indexWhere((arm) => arm['role'] == choice);
      if (index >= 0) arms[id] = index;
    } else if (!trace.pending &&
        nextArm != null &&
        card['kind'] != 'definition') {
      arms[id] = nextArm.$2;
    } else if (!trace.pending &&
        trace.function != null &&
        card['kind'] == 'definition' &&
        card['name'] == trace.function) {
      arms[id] = 0;
    } else if (!trace.pending &&
        next != null &&
        nextArm == null &&
        trace.nextLine! > (card['end'] as int)) {
      // Legacy recordings still carry the actual successor. An unseen branch
      // with a same-line body cannot be decided from line numbers.
      final first =
          branches.isEmpty ? null : readingChildren(branches.first).firstOrNull;
      if (first != null && (first['line'] as int) > trace.line) {
        final index = branches.indexWhere((arm) =>
            const ['skipped', 'exhausted'].contains(arm['role']) &&
            readingChildren(arm).isEmpty);
        if (index >= 0) arms[id] = index;
      }
    }
    if (card['syntax'] == 'Break' && !trace.pending && next != null) {
      Map? loop;
      var level = items;
      for (final (parent, branch) in current.parents) {
        final owner = level.firstWhere((node) => node['id'] == parent);
        if (owner['kind'] == 'loop' &&
            owner['branches'][branch]['role'] == 'taken') {
          loop = owner;
        }
        level = readingChildren(owner['branches'][branch] as Map);
      }
      if (loop != null &&
          next.card['id'] != loop['id'] &&
          !next.parents.any((hop) => hop.$1 == loop!['id'])) {
        final exits = loop['branches'] as List;
        final exit = exits.indexWhere((path) => path['role'] == 'break');
        if (exit >= 0) arms[loop['id'] as String] = exit;
      }
    }
    final nextId = next?.card['id'] as String?;
    final loopReturn = next?.card['kind'] == 'loop' &&
            current.parents.any((hop) => hop.$1 == nextId)
        ? nextId
        : null;
    return ReadingRoute(current, arms, loopReturn, nextId);
  }
}
