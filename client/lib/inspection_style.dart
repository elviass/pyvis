// Wave geometry references JetBrains WavePainter2D (Copyright 2000-2020 JetBrains s.r.o.).
// Apache License 2.0; see assets/ide/JetBrains-Apache-2.0.txt.
import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';

/// Islands Dark attributes, read from PyCharm 2026.2.3's bundled scheme.
/// Presentation and severity are separate: unused code fades; typos are green.
class InspectionStyle {
  final Color color;
  final Color? stripe;
  final bool wave, faded;
  final int priority;
  const InspectionStyle(this.color, this.stripe, this.priority,
      {this.wave = true, this.faded = false});
  static const error = InspectionStyle(Color(0xfffa6675), Color(0xffd64d5b), 4);
  static const warning =
      InspectionStyle(Color(0xfff2c55c), Color(0xffc29e4a), 3);
  static const weak = InspectionStyle(Color(0xffaeae80), Color(0xff756d56), 2);
  static const typo = InspectionStyle(Color(0xff7ec482), null, 1);
  static const unused =
      InspectionStyle(Color(0xff6f737a), null, 2, wave: false, faded: true);
  static InspectionStyle forIssue(Map issue) =>
      switch (issue['presentation'] ?? issue['severity']) {
        'error' => error,
        'typo' => typo,
        'unused' => unused,
        'weak_warning' => weak,
        _ => warning,
      };
}

/// One-pixel amplitude, four-pixel period, .7px stroke, continuous editor phase.
/// Geometry follows the documented WavePainter2D convention (lower boundary).
Path inspectionWave(Rect rect) {
  final path = Path();
  final start = rect.left.floorToDouble();
  final end = rect.right.ceilToDouble();
  for (var x = start; x <= end; x++) {
    final y = rect.bottom - 1.7 - math.cos(x * math.pi / 2);
    if (x == start) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  return path;
}
