import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:pyvis_editor/empty_editor.dart';
import 'package:re_editor/re_editor.dart';
import 'package:pyvis_editor/main.dart';
import 'package:pyvis_editor/line_theater.dart';
import 'package:pyvis_editor/comfy_blueprint_panel.dart';
import 'package:pyvis_editor/object_binding_view.dart';
import 'package:pyvis_editor/runtime_value_view.dart';
import 'package:pyvis_editor/trace_archive.dart';

class LocalPicker extends FilePicker {
  final String directory;
  String? savePath;
  String? pickPath;
  LocalPicker(this.directory);
  @override
  Future<String?> getDirectoryPath(
          {String? dialogTitle,
          bool lockParentWindow = false,
          String? initialDirectory}) async =>
      directory;
  @override
  Future<FilePickerResult?> pickFiles(
      {String? dialogTitle,
      String? initialDirectory,
      FileType type = FileType.any,
      List<String>? allowedExtensions,
      Function(FilePickerStatus)? onFileLoading,
      bool allowCompression = false,
      int compressionQuality = 0,
      bool allowMultiple = false,
      bool withData = false,
      bool withReadStream = false,
      bool lockParentWindow = false,
      bool readSequential = false}) async {
    if (pickPath == null) return null;
    final file = File(pickPath!);
    return FilePickerResult([
      PlatformFile(
          name: file.uri.pathSegments.last,
          size: await file.length(),
          path: file.path)
    ]);
  }

  @override
  Future<String?> saveFile(
          {String? dialogTitle,
          String? fileName,
          String? initialDirectory,
          FileType type = FileType.any,
          List<String>? allowedExtensions,
          Uint8List? bytes,
          bool lockParentWindow = false}) async =>
      savePath;
}

Future<void> realIo(WidgetTester tester, Future<void> Function() action) async {
  await tester.runAsync(action);
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  });
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await tester.pumpAndSettle();
}

Future<Directory> openFixture(WidgetTester tester, Map<String, String> files,
    {PyvisApp? app}) async {
  late Directory directory;
  await tester.runAsync(() async {
    directory = await Directory.systemTemp.createTemp('pyvis-workflow-test-');
    for (final item in files.entries) {
      final file = File('${directory.path}/${item.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(item.value);
    }
  });
  FilePicker.platform = LocalPicker(directory.path);
  addTearDown(() async {
    await directory.delete(recursive: true);
  });
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(app ?? const PyvisApp());
  await realIo(tester, () async {
    await tester.tap(find.byTooltip('打开项目').last);
  });
  return directory;
}

void main() {
  testWidgets('closing the last tab offers recent files and reopens the source',
      (tester) async {
    await openFixture(tester, {'main.py': 'print(7)\n'});
    await tester.tap(find.byTooltip('关闭文件'));
    await tester.pumpAndSettle();
    final empty = find.byType(EmptyEditor);
    expect(empty, findsOneWidget);
    expect(
        find.descendant(of: empty, matching: find.byType(Text)), findsNothing);
    final modifier = tester.widget<EmptyEditor>(empty).mac
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
    final recent = find.descendant(
        of: find.byType(AlertDialog), matching: find.text('main.py'));
    await realIo(tester, () async {
      await tester.tap(recent);
    });
    expect(tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!.text,
        'print(7)\n');
  });

  testWidgets('dropping Python files onto the empty editor opens their tabs',
      (tester) async {
    final folder = await openFixture(
        tester, {'main.py': 'print(7)\n', 'other.py': 'print(8)\n'});
    await tester.tap(find.byTooltip('关闭文件'));
    await tester.pumpAndSettle();
    final target = tester.widget<DropTarget>(find.byType(DropTarget));
    await realIo(tester, () async {
      target.onDragDone!(DropDoneDetails(files: [
        DropItemFile('${folder.path}/main.py'),
        DropItemFile('${folder.path}/other.py')
      ], localPosition: Offset.zero, globalPosition: Offset.zero));
    });
    expect(tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!.text,
        'print(8)\n');
    expect(find.byTooltip('关闭 main.py'), findsOneWidget);
  });
  testWidgets(
      'status controls navigate, apply indentation and save actual file bytes',
      (tester) async {
    const source = 'amount = 4\r\nprint("你好", amount)\r\n';
    final directory = await openFixture(tester, {'main.py': source});
    final file = File('${directory.path}/main.py');
    final code = tester.widget<CodeEditor>(find.byType(CodeEditor));
    final controller = code.controller!;
    expect(controller.text, source.replaceAll('\r\n', '\n'));
    expect(find.text('CRLF'), findsOneWidget);
    await tester.tap(find.byTooltip('转到行列'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '99:x');
    await tester.tap(find.text('转到'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请输入 1 至'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '2:1');
    await tester.tap(find.text('转到'));
    await tester.pumpAndSettle();
    expect(controller.selection.extentIndex, 1);
    expect(find.text('2:1'), findsOneWidget);
    await tester.tap(find.byTooltip('设置缩进宽度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 个空格'));
    await tester.pumpAndSettle();
    expect(controller.options.indentSize, 2);
    controller.applyIndent();
    await tester.pumpAndSettle();
    expect(controller.text.split('\n')[1], '  print("你好", amount)');
    controller.undo();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择换行符'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('LF（Unix / macOS）'));
    await tester.pumpAndSettle();
    expect(file.readAsStringSync(), source);
    await tester.tap(find.byTooltip('选择文件编码'));
    await tester.pumpAndSettle();
    await realIo(tester, () => tester.tap(find.text('GBK')));
    expect(controller.text, startsWith('# -*- coding: gbk -*-\n'));
    expect(file.readAsStringSync(), source);
    await realIo(tester, () => tester.tap(find.byTooltip('保存当前文件（有未保存修改）')));
    final bytes = file.readAsBytesSync();
    expect(bytes, isNot(contains(13)));
    final character = bytes.indexOf(0xc4);
    expect(character, greaterThanOrEqualTo(0));
    expect(bytes.sublist(character, character + 4), [0xc4, 0xe3, 0xba, 0xc3]);
    await tester.tap(find.byTooltip('查看 Python 运行环境'));
    await tester.pumpAndSettle();
    expect(find.text('Python 运行环境'), findsOneWidget);
    expect(find.text('可执行文件'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await realIo(tester, () => tester.tap(find.byTooltip('直接运行').first));
    expect(
        tester
            .widget<LineTheater>(find.byType(LineTheater))
            .events
            .where((e) => e['kind'] == 'output')
            .map((e) => e['text'])
            .join(),
        '你好 4\n');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'create dialog closes cleanly; save and save-as preserve file and entry',
      (tester) async {
    final directory = await openFixture(
        tester, {'main.py': 'print(1)\n', 'helper.py': 'x=2\n'});
    final previousController =
        tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
    await tester.tap(find.byTooltip('新建 Python 文件'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'practice');
    await realIo(tester, () async {
      await tester.tap(find.text('创建'));
    });
    expect(tester.takeException(), isNull);
    for (var i = 0;
        i < 30 &&
            identical(previousController,
                tester.widget<CodeEditor>(find.byType(CodeEditor)).controller);
        i++) {
      await realIo(tester, () async {});
    }
    final controller =
        tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
    expect(controller.text, isEmpty);
    controller.text = 'print("saved")\n';
    await tester.pump();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await realIo(tester, () async {
      await tester.tap(find.text('保存').last);
    });
    await tester.runAsync(() async {
      expect(await File('${directory.path}/practice.py').readAsString(),
          'print("saved")\n');
    });
    (FilePicker.platform as LocalPicker).savePath = '${directory.path}/copy.py';
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await realIo(tester, () async {
      await tester.tap(find.text('另存为…'));
    });
    for (var i = 0; i < 20 && find.text('copy.py').evaluate().isEmpty; i++) {
      await realIo(tester, () async {});
    }
    expect(find.text('copy.py'), findsWidgets);
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('直接运行').first);
    });
    final theater = tester.widget<LineTheater>(find.byType(LineTheater));
    expect(
        theater.events
            .where((e) => e['kind'] == 'output')
            .map((e) => e['text'])
            .join(),
        'saved\n');
    expect(
        theater.events
            .where((e) => e['file'] != null)
            .every((e) => e['file'].endsWith('copy.py')),
        isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'opening Python files validates extensions and preserves the current buffer on rejection',
      (tester) async {
    final directory = await openFixture(tester, {
      'main.py': 'print(1)\n',
      'new.PY': 'print(2)\n',
      'notes.txt': 'not Python'
    });
    final picker = FilePicker.platform as LocalPicker;
    final original =
        tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
    Future<void> choose(String name) async {
      picker.pickPath = '${directory.path}/$name';
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await realIo(tester, () async {
        await tester.tap(find.text('打开 Python 文件…'));
      });
    }

    await choose('notes.txt');
    expect(tester.widget<CodeEditor>(find.byType(CodeEditor)).controller,
        same(original));
    expect(original.text, 'print(1)\n');
    expect(find.text('请选择 Python 源码文件（.py）。'), findsOneWidget);
    await choose('new.PY');
    for (var i = 0;
        i < 20 &&
            identical(
                tester.widget<CodeEditor>(find.byType(CodeEditor)).controller,
                original);
        i++) {
      await realIo(tester, () async {});
    }
    expect(tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!.text,
        'print(2)\n');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'deep project folders and long names stay within the project pane',
      (tester) async {
    final nested =
        List.generate(14, (i) => 'section_${i}_with_a_long_name').join('/');
    await openFixture(tester, {
      'main.py': 'print(1)\n',
      '$nested/very_long_python_file_name.py': 'print(2)\n'
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('switching tabs preserves unsaved source and independent undo',
      (tester) async {
    final directory = await openFixture(
        tester, {'main.py': 'print(1)\n', 'helper.py': 'x=2\n'});
    final original =
        tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
    original.selectAll();
    original.replaceSelection('print("not saved")\n');
    await tester.pump();
    await realIo(tester, () async {
      await tester.tap(find.text('helper.py').first);
    });
    expect(find.text('保存当前修改？'), findsNothing);
    final helper =
        tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
    expect(identical(helper, original), false);
    expect(helper.text, 'x=2\n');
    await realIo(tester, () async {
      await tester.tap(find.text('main.py').first);
    });
    final restored =
        tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
    expect(identical(restored, original), true);
    expect(restored.text, 'print("not saved")\n');
    restored.undo();
    await tester.pumpAndSettle();
    expect(restored.text, 'print(1)\n');
    await tester.runAsync(() async {
      expect(
          await File('${directory.path}/main.py').readAsString(), 'print(1)\n');
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('real input reaches Python and stop works while awaiting input',
      (tester) async {
    await openFixture(
        tester, {'main.py': 'name=input("你的名字：")\nprint("你好", name)\n'});
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('直接运行').first);
    });
    expect(find.text('你的名字：'), findsOneWidget);
    final field = find.byType(TextField);
    await tester.enterText(field, '小林');
    await realIo(tester, () async {
      await tester.testTextInput.receiveAction(TextInputAction.done);
    });
    expect(find.textContaining('你好 小林'), findsWidgets);
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('直接运行').first);
    });
    await tester.tap(find.byTooltip('停止运行'));
    await tester.pumpAndSettle();
    expect(find.textContaining('运行已停止'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('multi-file entry executes imports and reports a Python error',
      (tester) async {
    await openFixture(tester, {
      'main.py': 'from helper import double\nprint(double(4))\nprint(1/0)\n',
      'helper.py': 'def double(x):\n    return x*2\n'
    });
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('直接运行').first);
    });
    final theater = tester.widget<LineTheater>(find.byType(LineTheater));
    expect(theater.events.any((e) => '${e['file']}'.endsWith('helper.py')),
        isTrue);
    expect(find.textContaining('ZeroDivisionError'), findsWidgets);
    expect(
        theater.events
            .where((e) => e['kind'] == 'output')
            .map((e) => e['text'])
            .join(),
        '8\n');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('find, replace and undo work on the actual editor buffer',
      (tester) async {
    await openFixture(tester, {'main.py': 'word=1\nprint(word)\n'});
    await tester.tap(find.byTooltip('查找'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.hintText == '查找'),
        'word');
    await realIo(tester, () async {});
    await tester.tap(find.byTooltip('展开替换'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.hintText == '替换为'),
        'name');
    await tester.tap(find.text('全部替换'));
    await tester.pumpAndSettle();
    final controller =
        tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
    expect(controller.text, 'name=1\nprint(name)\n');
    controller.undo();
    await tester.pumpAndSettle();
    expect(controller.text, 'word=1\nprint(word)\n');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'demo single step and stopping a running loop preserve recorded events',
      (tester) async {
    await openFixture(tester, {
      'main.py':
          'import time\nx=0\nwhile True:\n    x+=1\n    time.sleep(0.1)\n'
    });
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('演示运行').first);
    });
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('下一步'));
    });
    expect(find.byType(LineTheater), findsOneWidget);
    await tester.tap(find.byTooltip('停止运行'));
    await tester.pumpAndSettle();
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('直接运行').first);
    });
    final before =
        tester.widget<LineTheater>(find.byType(LineTheater)).events.length;
    await tester.tap(find.byTooltip('停止运行'));
    await tester.pumpAndSettle();
    expect(tester.widget<LineTheater>(find.byType(LineTheater)).events.length,
        greaterThanOrEqualTo(before));
    expect(find.textContaining('运行已停止'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'the same flow shows both alternatives and follows the recorded branch on replay',
      (tester) async {
    await openFixture(tester, {
      'main.py': 'values = [1, 1, 2]\n'
          'total = 0\n'
          'for item in values:\n'
          '    if item == 1:\n'
          '        total += item\n'
          '    else:\n'
          '        total += 10\n'
          'print(total)\n'
    });
    await tester.tap(find.text('代码流程图').first);
    await realIo(tester, () async {
      await tester.pump(const Duration(milliseconds: 450));
    });
    // AST parsing runs in a real process; wait for its visible result.
    for (var attempt = 0;
        attempt < 30 && find.text('每一轮执行').evaluate().isEmpty;
        attempt++) {
      await realIo(tester, () async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
    }
    await tester.tap(find.text('每一轮执行'));
    await tester.pumpAndSettle();
    expect(find.text('条件成立'), findsOneWidget);
    expect(find.text('条件不成立'), findsOneWidget);
    expect(find.byKey(const ValueKey('reading-taken-4:4-0')), findsNothing);

    await realIo(tester, () async {
      await tester.tap(find.byTooltip('直接运行').first);
      await Future<void>.delayed(const Duration(milliseconds: 450));
    });
    expect(find.text('代码概览'), findsOneWidget);
    expect(find.text('变量变化'), findsOneWidget);
    final stops = tester
        .widget<LineTheater>(find.byType(LineTheater))
        .events
        .where((e) =>
            e['kind'] == 'statement' ||
            (e['kind'] == 'call' && (e['frames'] as List).length > 1))
        .toList();
    Future<void> show(int line, {bool? taken, bool back = false}) async {
      final index = stops.indexWhere((e) =>
          e['line'] == line &&
          (taken == null || e['branch_taken'] == taken) &&
          (!back || e['next_line'] == 3));
      expect(index, greaterThanOrEqualTo(0));
      tester
          .widget<Slider>(find.byType(Slider).first)
          .onChanged!(index.toDouble());
      await tester.pumpAndSettle();
    }

    await show(4, taken: false);
    expect(find.byKey(const ValueKey('reading-taken-4:4-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('reading-taken-4:4-0')), findsNothing);
    expect(find.text('条件成立'), findsOneWidget);
    expect(find.text('条件不成立'), findsOneWidget);
    await show(4, taken: true);
    expect(find.byKey(const ValueKey('reading-taken-4:4-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('reading-taken-4:4-1')), findsNothing);
    await show(5, back: true);
    expect(find.byKey(const ValueKey('reading-return-3:0')), findsOneWidget);
    expect(find.text('原来 0'), findsOneWidget);
    expect(find.text('查看行内过程'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    await tester.tap(find.text('编辑代码'));
    await tester.pumpAndSettle();
    expect(find.byType(ComfyBlueprintPanel), findsNothing);
    expect(find.byType(Slider), findsNothing);
    await tester.tap(find.text('代码流程图'));
    await tester.pumpAndSettle();
    expect(find.byType(ComfyBlueprintPanel), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('运行时源码'), findsOneWidget);
    expect(find.text('原来 0'), findsOneWidget);
    final currentStep =
        tester.widget<LineTheater>(find.byType(LineTheater)).event;
    final traceStep = tester
        .widget<ComfyBlueprintPanel>(find.byType(ComfyBlueprintPanel))
        .trace!
        .sequence;
    await tester.tap(find.byTooltip('关闭变量变化'));
    await tester.pumpAndSettle();
    expect(find.text('变量变化'), findsNothing);
    expect(find.byType(Slider), findsOneWidget);
    expect(
        tester
            .widget<ComfyBlueprintPanel>(find.byType(ComfyBlueprintPanel))
            .trace!
            .sequence,
        traceStep);
    await tester.tap(find.text('显示变量变化'));
    await tester.pumpAndSettle();
    expect(tester.widget<LineTheater>(find.byType(LineTheater)).event,
        currentStep);
    await tester.tap(find.byTooltip('控制台'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('independent-console')), findsOneWidget);
    expect(tester.widget<LineTheater>(find.byType(LineTheater)).event,
        currentStep);
    await tester.tap(find.text('编辑代码'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('independent-console')), findsOneWidget);
    expect(find.byType(ComfyBlueprintPanel), findsNothing);
    await tester.tap(find.byTooltip('隐藏控制台'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('independent-console')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'one demo step completes a multiline dictionary and displays one referenced object',
      (tester) async {
    await openFixture(tester, {
      'main.py':
          'inventory = {\n    "笔记本": {"price": 20, "stock": 12},\n    "钢笔": {"price": 35, "stock": 8},\n    "书包": {"price": 120, "stock": 4},\n    "水杯": {"price": 45, "stock": 6},\n}\nprint(len(inventory))\n'
    });
    tester.view.physicalSize = const Size(1400, 784);
    await tester.pumpAndSettle();
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('演示运行').first);
    });
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('下一步'));
    });
    final theater = tester.widget<LineTheater>(find.byType(LineTheater));
    expect(theater.event['line'], 1);
    expect(theater.event['statement_type'], 'Assign');
    expect(theater.events.where((e) => e['kind'] == 'statement').length, 1);
    expect(find.byType(RuntimeValueView), findsOneWidget);
    expect(find.text('字典 · 4 项'), findsOneWidget);
    expect(tester.getBottomRight(find.byType(RuntimeValueView)).dy,
        lessThan(tester.getTopLeft(find.byType(Slider)).dy));
    await tester.tap(find.text('查看行内过程'));
    await tester.pumpAndSettle();
    expect(find.byType(ObjectBindingView), findsOneWidget);
    expect(find.byKey(const ValueKey('recorded-object')), findsOneWidget);
    expect(find.text('"price": 20'), findsOneWidget);
    expect(find.text('"水杯"'), findsOneWidget);
    await tester.ensureVisible(find.text('"水杯"'));
    await tester.pumpAndSettle();
    expect(tester.getBottomRight(find.text('"水杯"')).dy,
        lessThan(tester.getTopLeft(find.byType(Slider)).dy));
    await tester.tap(find.byTooltip('停止运行'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'demo preserves a return and the buffered caller assignment as separate steps',
      (tester) async {
    await openFixture(tester,
        {'main.py': 'def add():\n    return 3\nanswer=add()\nprint(answer)\n'});
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('演示运行').first);
    });
    Future<Map<String, dynamic>> next() async {
      await realIo(tester, () async {
        await tester.tap(find.byTooltip('下一步'));
      });
      return tester.widget<LineTheater>(find.byType(LineTheater)).event;
    }

    expect((await next())['statement_type'], 'FunctionDef');
    expect((await next())['kind'], 'call');
    final returned = await next();
    expect(returned['statement_type'], 'Return');
    expect(returned['line'], 2);
    final assigned = await next();
    expect(assigned['statement_type'], 'Assign');
    expect(assigned['line'], 3);
    expect(assigned['seq'], greaterThan(returned['seq']));
    expect((await next())['line'], 4);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'record export/import replays the saved run without executing modified code',
      (tester) async {
    final directory = await openFixture(tester, {
      'main.py': 'import random\nvalue=random.randint(1,10000)\nprint(value)\n'
    });
    await realIo(tester, () async {
      await tester.tap(find.byTooltip('直接运行').first);
    });
    final original =
        tester.widget<LineTheater>(find.byType(LineTheater)).events;
    final picker = FilePicker.platform as LocalPicker;
    picker.savePath = '${directory.path}/session.trace.json';
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await realIo(tester, () async {
      await tester.tap(find.text('保存执行记录'));
    });
    await tester.runAsync(() async {
      decodeTrace(await File(picker.savePath!).readAsString());
      await File('${directory.path}/main.py')
          .writeAsString('raise RuntimeError("must not rerun")\n');
    });
    picker.pickPath = picker.savePath;
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await realIo(tester, () async {
      await tester.tap(find.text('打开执行记录'));
    });
    tester
        .widget<Slider>(find.byType(Slider).first)
        .onChanged!((original.length - 1).toDouble());
    await tester.pumpAndSettle();
    expect(
        jsonEncode(tester.widget<LineTheater>(find.byType(LineTheater)).events),
        jsonEncode(original));
    expect(find.textContaining('must not rerun'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('malformed archives are rejected before replacing the active recording',
      () {
    expect(
        () => decodeTrace(
            '{"version":1,"events":[{"seq":0,"kind":"line"}],"sources":{}}'),
        throwsFormatException);
    final valid = {
      'version': 1,
      'events': [
        {
          'seq': 0,
          'kind': 'line',
          'line': 1,
          'frames': [],
          'heap': {},
          'values': []
        }
      ],
      'sources': {'main.py': 'pass'}
    };
    expect(decodeTrace(jsonEncode(valid))['events'], hasLength(1));
  });
}
