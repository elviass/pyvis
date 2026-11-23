import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pyvis_editor/android_node_graph.dart';

void main() {
  testWidgets('edits keep the last compiled scene until a successful rebuild',
      (tester) async {
    final compilation = NodeCompilation()..open(null);
    addTearDown(compilation.dispose);
    var source = 'x = 1';
    Map? scene;
    Future<void> show() => tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListenableBuilder(
                listenable: compilation,
                builder: (_, child) => AndroidNodeGraph(
                    compilation: compilation,
                    source: source,
                    filename: 'example.py',
                    onLine: (_) {},
                    positions: const {},
                    canvasBuilder: (_, data, event) {
                      scene = data;
                      return const SizedBox();
                    })))));

    await show();
    expect(find.text('尚未编译节点图'), findsOneWidget);
    expect(scene, isNull);

    Future<void> compile() async {
      final button = tester.widget<TextButton>(find.widgetWithText(
          TextButton, compilation.graph == null ? '编译节点图' : '重新编译'));
      await tester.runAsync(() async {
        button.onPressed!();
      });
      await tester.pump();
      expect(find.bySemanticsLabel('正在编译节点图'), findsWidgets);
      for (var i = 0; i < 100 && compilation.busy; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      expect(compilation.busy, isFalse);
    }

    await compile();
    expect(compilation.source, source);
    final first = scene;
    expect(first, isNotNull);
    source = 'x = ';
    await show();
    expect(find.textContaining('源码已修改'), findsOneWidget);
    expect(identical(first, scene), isTrue);
    await compile();
    expect(find.textContaining('编译失败'), findsOneWidget);
    expect(identical(first, scene), isTrue);
    source = 'x = 2';
    await show();
    await compile();
    expect(compilation.source, source);
    expect(scene, isNot(same(first)));
    await tester.pumpWidget(const SizedBox());
  });
}
