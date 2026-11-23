import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyvis_editor/blueprint_geometry.dart';
import 'package:pyvis_editor/blueprint_routing.dart';

Map node(String id, double x, double y,
        {double width = 80, double height = 80}) =>
    {
      'id': id,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'inputs': ['值']
    };
Map edge(String a, String b) => {'from': a, 'to': b, 'kind': 'data', 'port': 0};
void avoidsOtherNodes(GraphRoute route, List<Map> nodes) {
  expect(route.blocked, isFalse, reason: '${route.edge}');
  expect(route.points.length, greaterThanOrEqualTo(2));
  for (var i = 1; i < route.points.length; i++) {
    final a = route.points[i - 1], b = route.points[i];
    expect(a.dx == b.dx || a.dy == b.dy, isTrue);
    for (final n in nodes) {
      // Even endpoint bodies must not be re-entered along a detour.
      expect(graphSegmentHitsRect(a, b, graphNodeRect(n)), isFalse,
          reason: '${route.edge} crosses ${n['id']}: $a -> $b');
    }
  }
}

void main() {
  test('wire detours around a node between its endpoints', () {
    final nodes = [
      node('a', 40, 100),
      node('b', 460, 100),
      node('block', 240, 70, height: 150)
    ];
    final route = BlueprintRouter().route(nodes, [edge('a', 'b')]).single;
    avoidsOtherNodes(route, nodes);
    expect(route.points.first, graphOutput(nodes[0]));
    expect(route.points.last, graphInput(nodes[1], 0));
    expect(route.points.any((p) => p.dy < 70 || p.dy > 220), isTrue);
  });
  test('backwards wire detours around both endpoint bodies and barriers', () {
    final nodes = [
      node('a', 480, 200),
      node('b', 40, 200),
      node('block', 250, 20, height: 360)
    ];
    avoidsOtherNodes(
        BlueprintRouter().route(nodes, [edge('a', 'b')]).single, nodes);
  });
  test('several barriers require a multi-turn path', () {
    final nodes = [
      node('a', 20, 160),
      node('b', 620, 160),
      node('one', 170, 30, width: 100, height: 260),
      node('two', 340, 160, width: 100, height: 270),
      node('three', 470, 20, width: 60, height: 220)
    ];
    avoidsOtherNodes(
        BlueprintRouter().route(nodes, [edge('a', 'b')]).single, nodes);
  });
  test('moving an unrelated node invalidates an obstructed cached route', () {
    final router = BlueprintRouter();
    final nodes = [
      node('a', 20, 120),
      node('b', 480, 120),
      node('block', 240, 300)
    ];
    final first = router.route(nodes, [edge('a', 'b')]).single;
    nodes[2]['y'] = 100.0;
    final next = router.route(nodes, [edge('a', 'b')]).single;
    avoidsOtherNodes(next, nodes);
    expect(next.points, isNot(first.points));
    nodes[0]['y'] = 190.0;
    final moved = router.route(nodes, [edge('a', 'b')]).single;
    avoidsOtherNodes(moved, nodes);
    expect(moved.points.first, graphOutput(nodes.first));
  });
  test('overlapping ports report a blocked wire without an unsafe fallback',
      () {
    final nodes = [
      node('a', 20, 100),
      node('b', 480, 100),
      node('block', 95, 100)
    ];
    final route = BlueprintRouter().route(nodes, [edge('a', 'b')]).single;
    expect(route.blocked, isTrue);
    expect(route.points, isEmpty);
  });
  test(
      'real whole-program routes avoid all atomic nodes, before and after drag',
      () {
    final view = jsonDecode(
        File('test/fixtures/whole_blueprint.json').readAsStringSync()) as Map;
    final nodes = (view['nodes'] as List).cast<Map>();
    final edges = (view['edges'] as List)
        .cast<Map>()
        .where((e) => e['kind'] != 'reference')
        .toList();
    final router = BlueprintRouter();
    final watch = Stopwatch()..start();
    for (final route in router.route(nodes, edges)) {
      avoidsOtherNodes(route, nodes);
    }
    expect(watch.elapsedMilliseconds, lessThan(3000));
    final moved = nodes.firstWhere((n) => n['kind'] == 'operator');
    moved['x'] = (moved['x'] as num) + 65;
    moved['y'] = (moved['y'] as num) + 95;
    for (final route in router.route(nodes, edges)) {
      if (!route.blocked) avoidsOtherNodes(route, nodes);
    }
  });
  test('branch paths use distinct ports and separate long channels', () {
    final nodes = [
      node('decision', 600, 100, width: 160, height: 88),
      node('yes', 40, 320),
      node('no', 40, 520)
    ];
    final edges = [
      {
        'from': 'decision',
        'to': 'yes',
        'kind': 'guard',
        'label': '成立',
        'port': 0
      },
      {
        'from': 'decision',
        'to': 'no',
        'kind': 'guard',
        'label': '不成立',
        'port': 0
      }
    ];
    final routes = BlueprintRouter().route(nodes, edges);
    expect(routes[0].points.first.dy, isNot(routes[1].points.first.dy));
    for (final route in routes) {
      avoidsOtherNodes(route, nodes);
    }
    var shared = 0.0;
    for (var i = 1; i < routes[0].points.length; i++) {
      final a = routes[0].points[i - 1], b = routes[0].points[i];
      for (var j = 1; j < routes[1].points.length; j++) {
        final c = routes[1].points[j - 1], d = routes[1].points[j];
        if (a.dx == b.dx && c.dx == d.dx && a.dx == c.dx) {
          final lo = a.dy < b.dy ? a.dy : b.dy, hi = a.dy > b.dy ? a.dy : b.dy;
          final otherLo = c.dy < d.dy ? c.dy : d.dy,
              otherHi = c.dy > d.dy ? c.dy : d.dy;
          final overlap =
              (hi < otherHi ? hi : otherHi) - (lo > otherLo ? lo : otherLo);
          if (overlap > 0) shared += overlap;
        }
      }
    }
    expect(shared, lessThan(30));
  });
  test('section rail detours after dragging a node into it', () {
    final nodes = [
      node('s1', 53.5, 40, width: 22, height: 22),
      node('s2', 53.5, 400, width: 22, height: 22),
      node('block', 180, 200)
    ];
    final link = {'from': 's1', 'to': 's2', 'kind': 'section', 'port': 0};
    final router = BlueprintRouter();
    final first = router.route(nodes, [link]).single;
    expect(first.points, [
      graphNodeRect(nodes[0]).bottomCenter,
      graphNodeRect(nodes[1]).topCenter
    ]);
    nodes[2]['x'] = 40.0;
    final moved = router.route(nodes, [link]).single;
    avoidsOtherNodes(moved, nodes);
    expect(moved.points.length, greaterThan(2));
  });
  test('unchanged geometry reuses routes and moved obstacles invalidate them',
      () {
    final router = BlueprintRouter();
    final nodes = [
      node('a', 20, 100),
      node('b', 500, 100),
      node('block', 240, 300)
    ];
    final edges = [edge('a', 'b')];
    final first = router.route(nodes, edges);
    expect(identical(first, router.route(nodes, edges)), isTrue);
    nodes[2]['y'] = 80.0;
    final changed = router.route(nodes, edges);
    expect(identical(first, changed), isFalse);
    avoidsOtherNodes(changed.single, nodes);
  });
}
