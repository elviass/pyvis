import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pyvis_editor/editor_settings.dart';
import 'package:pyvis_editor/ide_chrome.dart';
import 'package:pyvis_editor/pyvis_theme.dart';

void main() {
  testWidgets('toolbar keyboard navigation activates enabled actions only',
      (tester) async {
    var activated = 0;
    await tester.pumpWidget(MaterialApp(
        theme: pyvisTheme(),
        home: Scaffold(
          body: Row(children: [
            IdeButton(icon: 'run', tooltip: '运行', onTap: () => activated++),
            const IdeButton(icon: 'stop', tooltip: '停止'),
          ]),
        )));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(activated, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings remains scrollable at narrow width and high DPI',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1100);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: pyvisTheme(),
        home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => EditorSettingsDialog(
                          preferences: EditorPreferences(fontSize: 28),
                          mac: true)),
                  child: const Text('打开设置'))),
        )));
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('键位'));
    await tester.pumpAndSettle();
    await tester.drag(
        find.byType(SingleChildScrollView).last, const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(EditorSettingsDialog), findsNothing);
  });
}
