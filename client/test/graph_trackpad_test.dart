import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyvis_editor/comfy_graph_canvas.dart';

void main() {
  testWidgets(
      'trackpad swipes pan, pinches zoom, and mouse wheel still reaches the web view',
      (tester) async {
    final updates = <(Offset, double)>[];
    final pans = <(Offset, Offset)>[];
    var wheelEvents = 0;
    var starts = 0, ends = 0;
    await tester.pumpWidget(
      Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: GraphTrackpad(
            onStart: () => starts++,
            onEnd: () => ends++,
            onZoom: (anchor, scale) => updates.add((anchor, scale)),
            onPan: (anchor, delta) => pans.add((anchor, delta)),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerSignal: (_) => wheelEvents++,
              child: const SizedBox(width: 300, height: 200),
            ),
          ),
        ),
      ),
    );

    const global = Offset(100, 110);
    const local = Offset(60, 70);
    final trackpad = TestPointer(1, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(trackpad.panZoomStart(global));
    await tester.sendEventToBinding(
        trackpad.panZoomUpdate(global, pan: const Offset(0, 25)));
    expect(updates, isEmpty);
    expect(pans, [(local, const Offset(0, 25))]);

    await tester.sendEventToBinding(
        trackpad.panZoomUpdate(global, scale: 1.25, pan: const Offset(3, 26)));
    await tester.sendEventToBinding(
        trackpad.panZoomUpdate(global, scale: 1.25, pan: const Offset(3, 30)));
    await tester.sendEventToBinding(trackpad.panZoomUpdate(global, scale: 1.5));
    await tester.sendEventToBinding(trackpad.panZoomEnd());
    expect(updates, [(local, 1.25), (local, 1.5)]);
    expect(pans, hasLength(1));

    await tester.sendEventToBinding(trackpad.panZoomStart(global));
    await tester.sendEventToBinding(trackpad.panZoomUpdate(global, scale: 0.8));
    await tester.sendEventToBinding(trackpad.panZoomEnd());
    expect(updates.last, (local, 0.8));

    await tester.sendEventToBinding(trackpad.panZoomStart(global));
    await tester.sendEventToBinding(
        trackpad.panZoomUpdate(global, pan: const Offset(40, 0)));
    await tester.sendEventToBinding(trackpad.panZoomEnd());
    expect(pans.last, (local, const Offset(40, 0)));

    final mouse = TestPointer(2, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(global));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
    expect(wheelEvents, 1);
    expect(updates, hasLength(3));
    expect((starts, ends), (3, 3));
  });
}
