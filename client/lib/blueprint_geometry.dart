import 'dart:math' as math;
import 'dart:ui';

double graphNodeHeight(Map node) => (node['height'] as num? ?? 81).toDouble();
double graphNodeWidth(Map node) => (node['width'] as num? ?? 170).toDouble();
Rect graphNodeRect(Map node) => Rect.fromLTWH((node['x'] as num).toDouble(),
    (node['y'] as num).toDouble(), graphNodeWidth(node), graphNodeHeight(node));
Offset graphOutput(Map node) => graphNodeRect(node).centerRight;
Offset graphInput(Map node, int port) {
  final rect = graphNodeRect(node);
  final count = math.max(1, (node['inputs'] as List).length);
  return Offset(rect.left,
      rect.top + rect.height * ((port.clamp(0, count - 1) + 1) / (count + 1)));
}
