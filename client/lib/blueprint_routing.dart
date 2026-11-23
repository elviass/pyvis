import 'dart:math' as math;
import 'dart:ui';
import 'blueprint_geometry.dart';

/// Orthogonal, obstacle-aware wires. An impossible route is reported rather
/// than falling back to a line through a node (e.g. overlapping dragged nodes).
class GraphRoute {
  final Map edge;
  final List<Offset> points;
  final bool blocked;
  const GraphRoute(this.edge, this.points, {this.blocked = false});
}

bool graphSegmentHitsRect(Offset a, Offset b, Rect r) {
  const epsilon = .001;
  if ((a.dx - b.dx).abs() < epsilon) {
    return a.dx > r.left + epsilon &&
        a.dx < r.right - epsilon &&
        math.max(a.dy, b.dy) > r.top + epsilon &&
        math.min(a.dy, b.dy) < r.bottom - epsilon;
  }
  if ((a.dy - b.dy).abs() < epsilon) {
    return a.dy > r.top + epsilon &&
        a.dy < r.bottom - epsilon &&
        math.max(a.dx, b.dx) > r.left + epsilon &&
        math.min(a.dx, b.dx) < r.right - epsilon;
  }
  return true;
}

bool executionEdge(Map edge) =>
    edge['kind'] == 'flow' ||
    edge['kind'] == 'guard' ||
    edge['kind'] == 'exception';
Offset wireOutput(Map node, Map edge) => edge['kind'] == 'section'
    ? edge['back'] == true
        ? graphNodeRect(node).centerLeft
        : Offset(
            graphNodeRect(node).left +
                graphNodeRect(node).width *
                    (edge['label'] == '成立'
                        ? .28
                        : const ['不成立', '结束'].contains(edge['label'])
                            ? .72
                            : .5),
            graphNodeRect(node).bottom)
    : executionEdge(edge)
        ? graphNodeRect(node).topRight +
            Offset(
                0, edge['kind'] == 'guard' && edge['label'] == '不成立' ? 37 : 19)
        : graphOutput(node);
Offset wireInput(Map node, Map edge) => edge['kind'] == 'section'
    ? edge['back'] == true
        ? graphNodeRect(node).centerLeft
        : graphNodeRect(node).topCenter
    : executionEdge(edge)
        ? graphNodeRect(node).topLeft + const Offset(0, 19)
        : graphInput(node, edge['port'] as int? ?? 0);

class BlueprintRouter {
  final _cache = <String, List<Offset>>{};
  int? _signature;
  List<GraphRoute>? _lastRoutes;
  List<GraphRoute> route(List<Map> nodes, List<Map> edges) {
    final signature = Object.hash(
        Object.hashAll(nodes.map((n) => Object.hash(n['id'], n['x'], n['y'],
            n['width'], n['height'], (n['inputs'] as List).length))),
        Object.hashAll(edges.map((e) => Object.hash(
            e['from'], e['to'], e['kind'], e['port'], e['label'], e['back']))));
    if (_signature == signature && _lastRoutes != null) return _lastRoutes!;
    final lookup = {for (final n in nodes) n['id']: n};
    final obstacles = {
      for (final n in nodes) n['id']: graphNodeRect(n).inflate(8)
    };
    bool clear(Offset a, Offset b) =>
        !obstacles.values.any((r) => graphSegmentHitsRect(a, b, r));
    bool pathClear(List<Offset> points) {
      for (var i = 1; i < points.length; i++) {
        if (!clear(points[i - 1], points[i])) return false;
      }
      return true;
    }

    final reserved = <(Offset, Offset)>[];
    double congestion(Offset a, Offset b) {
      var shared = 0.0;
      for (final segment in reserved) {
        final c = segment.$1, d = segment.$2;
        if (a.dx == b.dx && c.dx == d.dx && (a.dx - c.dx).abs() < .1) {
          shared += math.max(
              0,
              math.min(math.max(a.dy, b.dy), math.max(c.dy, d.dy)) -
                  math.max(math.min(a.dy, b.dy), math.min(c.dy, d.dy)));
        } else if (a.dy == b.dy && c.dy == d.dy && (a.dy - c.dy).abs() < .1) {
          shared += math.max(
              0,
              math.min(math.max(a.dx, b.dx), math.max(c.dx, d.dx)) -
                  math.max(math.min(a.dx, b.dx), math.min(c.dx, d.dx)));
        }
      }
      return shared;
    }

    double pathCongestion(List<Offset> path) {
      var total = 0.0;
      for (var i = 1; i < path.length; i++) {
        total += congestion(path[i - 1], path[i]);
      }
      return total;
    }

    final result = <GraphRoute>[];
    final used = <String>{};
    for (final edge in edges) {
      final a = lookup[edge['from']], b = lookup[edge['to']];
      if (a == null || b == null) continue;
      final from = wireOutput(a, edge), to = wireInput(b, edge);
      final section = edge['kind'] == 'section';
      final lead = edge['kind'] == 'section'
          ? edge['back'] == true
              ? const Offset(-22, 0)
              : const Offset(0, 22)
          : const Offset(14, 0);
      final start = from + lead,
          end = edge['kind'] == 'section' && edge['back'] == true
              ? to + lead
              : to - lead;
      final key =
          '${edge['from']}:${edge['to']}:${edge['kind']}:${edge['port']}';
      used.add(key);
      final portsBlocked = obstacles.entries.any((o) =>
          o.key != a['id'] && graphSegmentHitsRect(from, start, o.value) ||
          o.key != b['id'] && graphSegmentHitsRect(end, to, o.value));
      if (portsBlocked) {
        result.add(GraphRoute(edge, const [], blocked: true));
        continue;
      }
      var middle = _cache[key];
      if (middle == null ||
          middle.first != start ||
          middle.last != end ||
          !pathClear(middle) ||
          !section && pathCongestion(middle) > 24) {
        middle = null;
        final midX = (start.dx + end.dx) / 2;
        final midY = (start.dy + end.dy) / 2;
        final corridor =
            graphNodeRect(a).expandToInclude(graphNodeRect(b)).inflate(400);
        final exitLane = obstacles.values
                .where((r) =>
                    r.overlaps(corridor) &&
                    r.bottom > start.dy &&
                    r.top < end.dy)
                .fold(math.max(start.dx, end.dx),
                    (x, r) => math.max(x, r.right)) +
            24;
        final candidates = <List<Offset>>[
          if (section && edge['label'] == '结束')
            [start, Offset(exitLane, start.dy), Offset(exitLane, end.dy), end],
          if (start.dy == end.dy || start.dx == end.dx) [start, end],
          [start, Offset(end.dx, start.dy), end],
          [start, Offset(start.dx, end.dy), end],
          [start, Offset(midX, start.dy), Offset(midX, end.dy), end],
          [start, Offset(start.dx, midY), Offset(end.dx, midY), end],
          if (section)
            for (final x in <double>{
              math.min(start.dx, end.dx) - 32,
              math.max(start.dx, end.dx) + 32,
              for (final rect in obstacles.values) ...[
                rect.left - 16,
                rect.right + 16
              ]
            })
              [start, Offset(x, start.dy), Offset(x, end.dy), end],
        ];
        for (final candidate in candidates) {
          // Section wires may share a clear trunk at a merge. Treating a shared
          // trunk as a collision causes repeated grid searches on large graphs.
          if (pathClear(candidate) &&
              (section || pathCongestion(candidate) <= 24)) {
            middle = candidate;
            break;
          }
        }
        middle ??= _search(
            start, end, obstacles.values.toList(), clear, congestion, reserved);
      }
      if (middle == null) {
        result.add(GraphRoute(edge, const [], blocked: true));
      } else {
        _cache[key] = middle;
        for (var i = 1; i < middle.length; i++) {
          reserved.add((middle[i - 1], middle[i]));
        }
        result.add(GraphRoute(edge, _simplify([from, ...middle, to])));
      }
    }
    _cache.removeWhere((key, _) => !used.contains(key));
    _signature = signature;
    _lastRoutes = result;
    return result;
  }

  List<Offset>? _search(
      Offset start,
      Offset end,
      List<Rect> obstacles,
      bool Function(Offset, Offset) clear,
      double Function(Offset, Offset) congestion,
      List<(Offset, Offset)> reserved) {
    final xs = <double>{start.dx, end.dx}, ys = <double>{start.dy, end.dy};
    for (final r in obstacles) {
      xs.addAll([r.left - 2, r.right + 2]);
      ys.addAll([r.top - 2, r.bottom + 2]);
    }
    for (final segment in reserved) {
      for (final p in [segment.$1, segment.$2]) {
        xs.addAll([p.dx - 7, p.dx + 7]);
        ys.addAll([p.dy - 7, p.dy + 7]);
      }
    }
    final x = xs.toList()..sort(), y = ys.toList()..sort();
    final nx = x.length;
    final startCell = y.indexOf(start.dy) * nx + x.indexOf(start.dx);
    final endCell = y.indexOf(end.dy) * nx + x.indexOf(end.dx);
    Offset point(int cell) => Offset(x[cell % nx], y[cell ~/ nx]);
    final heap = _Heap();
    final distance = <int, double>{startCell * 3: 0};
    final previous = <int, int>{};
    final segmentCache = <int, bool>{};
    double heuristic(int cell) =>
        (point(cell).dx - end.dx).abs() + (point(cell).dy - end.dy).abs();
    heap.add(_Step(startCell * 3, 0, heuristic(startCell)));
    var explored = 0;
    while (heap.isNotEmpty && explored++ < 60000) {
      final step = heap.pop(), state = step.state;
      if (step.cost != distance[state]) continue;
      final cell = state ~/ 3, direction = state % 3;
      if (cell == endCell) {
        final path = <Offset>[];
        int? current = state;
        while (current != null) {
          path.add(point(current ~/ 3));
          current = previous[current];
        }
        return _simplify(path.reversed.toList());
      }
      final col = cell % nx, row = cell ~/ nx;
      final adjacent = <int>[
        if (col > 0) cell - 1,
        if (col < nx - 1) cell + 1,
        if (row > 0) cell - nx,
        if (row < y.length - 1) cell + nx,
      ];
      for (final next in adjacent) {
        final segmentKey =
            (math.min(cell, next) * nx * y.length + math.max(cell, next))
                .toInt();
        if (!(segmentCache[segmentKey] ??= clear(point(cell), point(next)))) {
          continue;
        }
        final nextDirection = next ~/ nx == row ? 1 : 2;
        final nextState = next * 3 + nextDirection;
        final cost = step.cost +
            (point(next) - point(cell)).distance +
            (direction != 0 && direction != nextDirection ? 28 : 0) +
            congestion(point(cell), point(next)) * 4;
        if (cost >= (distance[nextState] ?? double.infinity)) continue;
        distance[nextState] = cost;
        previous[nextState] = state;
        heap.add(_Step(nextState, cost, cost + heuristic(next)));
      }
    }
    return null;
  }
}

List<Offset> _simplify(List<Offset> points) {
  final result = <Offset>[];
  for (final p in points) {
    if (result.isNotEmpty && result.last == p) continue;
    while (result.length > 1) {
      final a = result[result.length - 2], b = result.last;
      if ((a.dx == b.dx && b.dx == p.dx) || (a.dy == b.dy && b.dy == p.dy)) {
        result.removeLast();
      } else {
        break;
      }
    }
    result.add(p);
  }
  return result;
}

class _Step {
  final int state;
  final double cost, score;
  _Step(this.state, this.cost, this.score);
}

class _Heap {
  final _items = <_Step>[];
  bool get isNotEmpty => _items.isNotEmpty;
  void add(_Step item) {
    _items.add(item);
    var i = _items.length - 1;
    while (i > 0) {
      final parent = (i - 1) ~/ 2;
      if (_items[parent].score <= item.score) break;
      _items[i] = _items[parent];
      i = parent;
    }
    _items[i] = item;
  }

  _Step pop() {
    final first = _items.first, last = _items.removeLast();
    if (_items.isEmpty) return first;
    var i = 0;
    while (i * 2 + 1 < _items.length) {
      var child = i * 2 + 1;
      if (child + 1 < _items.length &&
          _items[child + 1].score < _items[child].score) {
        child++;
      }
      if (last.score <= _items[child].score) break;
      _items[i] = _items[child];
      i = child;
    }
    _items[i] = last;
    return first;
  }
}
