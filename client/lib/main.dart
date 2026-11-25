import 'welcome_workspace.dart';
import 'about_pyvis.dart';
import 'empty_editor.dart';
import 'learning_ai.dart';
import 'learning_ai_view.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/python.dart';
import 'python_syntax.dart';
import 'runtime_adapter.dart';
import 'line_theater.dart';
import 'learning_scene.dart' show SceneValue;
import 'runtime_value_view.dart';
import 'execution_flow.dart';
import 'ide_chrome.dart';
import 'pyvis_theme.dart';
import 'provider_logo.dart';
import 'trace_archive.dart';
import 'find_panel.dart';
import 'comfy_blueprint_panel.dart';
import 'android_node_graph.dart';
import 'reading_flow_trace.dart';
import 'comfy_graph_canvas.dart';
import 'python_analysis_service.dart';
import 'python_completion.dart';
import 'editor_decorations.dart';
import 'editor_commands.dart';
import 'editor_chrome.dart';
import 'quick_documentation.dart';
import 'editor_document.dart';
import 'python_source_file.dart';
import 'editor_settings.dart';
import 'inspection_style.dart';
import 'local_completion.dart';
import 'windows_title_bar.dart';

void main() => runApp(const PyvisApp(startOnWelcome: true));

const bg = PyvisColors.background;
const panel = PyvisColors.surface;
const accent = PyvisColors.accent;
const muted = PyvisColors.muted;
const editorBg = PyvisColors.background;

bool get _usesWindowsChrome => defaultTargetPlatform == TargetPlatform.windows;

class PyvisApp extends StatelessWidget {
  final GraphCanvasBuilder? graphCanvasBuilder;
  final InlineCompletionModel? inlineModel;
  final bool aiEnabled;
  final bool startOnWelcome;
  const PyvisApp(
      {super.key,
      this.aiEnabled = false,
      this.startOnWelcome = false,
      this.graphCanvasBuilder,
      this.inlineModel});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Pyvis · Python 学习编辑器',
        theme: pyvisTheme(),
        builder: (context, child) {
          if (_usesWindowsChrome) return WindowsWindowFrame(child: child!);
          if (Platform.isAndroid) {
            return ColoredBox(color: bg, child: SafeArea(child: child!));
          }
          return child!;
        },
        home: EditorPage(
            aiEnabled: aiEnabled,
            startOnWelcome: startOnWelcome,
            graphCanvasBuilder: graphCanvasBuilder,
            inlineModel: inlineModel),
      );
}

class EditorPage extends StatefulWidget {
  final GraphCanvasBuilder? graphCanvasBuilder;
  final InlineCompletionModel? inlineModel;
  final bool aiEnabled;
  final bool startOnWelcome;
  const EditorPage(
      {super.key,
      this.aiEnabled = false,
      this.startOnWelcome = false,
      this.graphCanvasBuilder,
      this.inlineModel});
  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  late bool welcome;
  final recentProjects = <String>[];
  final recentFiles = <String>[];
  File? androidRecentFile;

  File? get recentFile {
    if (Platform.isAndroid) return androidRecentFile;
    final dir = EditorPreferences.file?.parent;
    return dir == null ? null : File(p.join(dir.path, 'recent-projects.json'));
  }

  Future<void> loadRecentProjects() async {
    try {
      if (Platform.isAndroid) {
        final path = await const MethodChannel('dev.pyvis/workspace')
            .invokeMethod<String>('recentProjectsPath');
        if (!mounted || path == null) return;
        androidRecentFile = File(path);
      }
      final file = recentFile;
      if (file == null) return;
      final hasNewProjects = recentProjects.isNotEmpty;
      if (file.existsSync()) {
        final stored =
            (jsonDecode(file.readAsStringSync()) as List).whereType<String>();
        final merged = {...recentProjects, ...stored}.take(15).toList();
        recentProjects
          ..clear()
          ..addAll(merged);
      }
      if (hasNewProjects) saveRecentProjects();
    } on Object {
      return;
    }
  }

  void rememberProject(String folder) {
    recentProjects.remove(folder);
    recentProjects.insert(0, folder);
    if (recentProjects.length > 15) recentProjects.removeLast();
    saveRecentProjects();
  }

  void saveRecentProjects() {
    try {
      final file = recentFile;
      file?.parent.createSync(recursive: true);
      file?.writeAsStringSync(jsonEncode(recentProjects));
    } on FileSystemException {
      return;
    }
  }

  late CodeLineEditingController editor;
  late final RuntimeAdapter runtime;
  late CodeFindController finder;
  final input = TextEditingController();
  Future<void>? _saveInFlight;
  late final AppLifecycleListener lifecycle;
  bool fileBusy = false;
  final analysis = PythonAnalysisService();
  final semantics = PythonAnalysisService();
  final inlineChecks = PythonAnalysisService();
  late final InlineCompletionModel inlineModel;
  Timer? inlineTimer;
  int inlineGeneration = 0;
  final documents = <String, EditorDocument>{};
  bool editorServicesReady = false;
  late final EditorContextMenuController editorContextMenu;
  bool formatting = false, inspectionBusy = false, inspectionAgain = false;
  bool softWrap = false, showMiniMap = true;
  bool showLineNumbers = true,
      highlightCurrentLine = true,
      autoClosePairs = true;
  Set<String> dictionaryWords = {};
  Set<String> enabledInspections = {
    'syntax',
    'types',
    'references',
    'unused',
    'style',
    'spelling'
  };
  List<Map<String, dynamic>> allDiagnostics = [];
  double editorFontSize = 14;
  bool get editorWritable =>
      !fileBusy &&
      !checkingRun &&
      !formatting &&
      !(documents[currentFile]?.readOnly ?? false);
  bool get macKeys => Theme.of(context).platform == TargetPlatform.macOS;
  PyCharmKeymap get keymap => PyCharmKeymap(macKeys);
  bool get miniMapVisible =>
      showMiniMap && !blueprintMode && MediaQuery.sizeOf(context).width >= 900;
  late PythonPromptsBuilder completions;
  late PythonCompletionActions completionKeys;
  late EditorDecorations decorations;
  final editorFocus = FocusNode();
  final completionPopup = CodeAutocompleteController();
  final gutterKey = GlobalKey();
  CodeIndicatorValueNotifier? renderedLines;
  final hintGeometry = ValueNotifier(0);
  bool hintGeometryQueued = false;
  OverlayEntry? diagnosticHover;
  String? renameHint;
  Timer? renameHintTimer;
  Timer? semanticTimer;
  int semanticGeneration = 0;
  bool semanticBusy = false, semanticAgain = false;
  List<Map<String, dynamic>> signatures = [];
  String? signatureSource;
  CodeLineSelection? signatureSelection;
  final codeScroll = CodeScrollController();
  Timer? analysisTimer;
  int analysisGeneration = 0;
  bool analyzing = false, checkingRun = false;
  String? checkedSource, analysisFailure, analyzedFile;
  List<Map<String, dynamic>> diagnostics = [];
  bool animationsPaused = false;
  bool pendingDemoStep = false;
  final stageScroll = ScrollController(keepScrollOffset: false);
  int? stageSequence;
  int fileLoadToken = 0;
  ExecutionRecording recording = ExecutionRecording();
  List<Map<String, dynamic>> get events => recording.events;
  set events(List<Map<String, dynamic>> initial) {
    recording = ExecutionRecording(initial);
  }
  List<int> get playbackStops => recording.stops;
  bool codeSyncScheduled = false;

  Map<String, dynamic> sources = {};
  Map<String, dynamic>? error;
  List<File> files = [];
  int projectScan = 0;
  Future<void>? fileRefreshTask;
  String? currentFile, project, entry;
  String status = '打开示例，观察程序里的每一次变化';
  String console = '';
  String? prompt;
  bool running = false, playing = false, demo = false;
  bool _loading = false;
  bool get dirty => documents[currentFile]?.dirty ?? editor.text.isNotEmpty;
  String _lastText = '';
  int cursor = 0, selectedFrame = -1;
  bool showConsole = false, showProblems = false;
  int? inspectedTraceLine;
  String? runEntry;
  int? graphSelectedLine;
  final nodeCompilations = <String, NodeCompilation>{};
  final graphLayouts = <String, Map<String, Offset>>{};
  bool showExecution = false, showProject = true, showVariableChanges = true;
  late final Future<({String version, String executable})?> pythonDetails =
      RuntimeAdapter.describePython();
  bool blueprintMode = false, projectBeforeBlueprint = true;
  double projectWidth = 256;
  final Set<String> collapsedDirs = {};
  double speed = 1;
  Timer? timer;
  Map<String, dynamic>? get event =>
      events.isEmpty ? null : events[cursor.clamp(0, events.length - 1)];
  List<dynamic> get frames =>
      (selectedStep ?? event)?['frames'] as List<dynamic>? ?? [];
  Map<String, dynamic> get frame => frames.isEmpty
      ? {}
      : Map<String, dynamic>.from(frames[
          (selectedFrame < 0 ? frames.length - 1 : selectedFrame)
              .clamp(0, frames.length - 1)]);

  @override
  void initState() {
    super.initState();
    welcome = widget.startOnWelcome;
    if (welcome && widget.aiEnabled) {
      learningContext = {};
      showLearningAi = true;
      chatTabSelected = false;
    }
    loadRecentProjects();
    inlineModel = widget.inlineModel ?? LocalCompletionModel();
    inlineModel.addListener(updateInlineStatus);
    if (Platform.isMacOS) {
      const MethodChannel('dev.pyvis/editor_commands')
          .setMethodCallHandler((call) async {
        if (!mounted) return;
        if (call.method.startsWith('edit')) {
          await performNativeEdit(call.method);
          return;
        }
        switch (call.method) {
          case 'find':
            finder.findMode();
          case 'replace':
            finder.replaceMode();
          case 'new':
            await createFile();
          case 'open':
            await openPythonFile();
          case 'project':
            await pickProject();
          case 'save':
            await saveAllDocuments();
          case 'saveAs':
            await save(saveAs: true);
          case 'close':
            await closeFile();
          case 'format':
            await formatBuffer();
          case 'imports':
            await formatBuffer(imports: true);
          case 'duplicateCode':
          case 'startNewLine':
          case 'completeStatement':
            if (!editorFocus.hasFocus) return;
            final command = switch (call.method) {
              'duplicateCode' => EditorCommand.duplicate,
              'startNewLine' => EditorCommand.startNewLine,
              _ => EditorCommand.completeStatement,
            };
            editorCommands[command]?.call();
          case 'intentions':
            if (editorFocus.hasFocus) await showIntentions();
          case 'check':
            await checkCode();
          case 'settings':
            await openEditorSettings();
          case 'about':
            await openAbout();
          case 'keymap':
            await openEditorSettings(initialPage: 3);
          case 'showCode':
            setState(() => switchWorkspace(false));
          case 'showFlow':
            setState(() => switchWorkspace(true));
          case 'toggleProject':
            setState(() => showProject = !showProject);
          case 'toggleConsole':
            toggleConsole();
          case 'showProblems':
            setState(openProblems);
          case 'goToLine':
            await goToLineDialog();
          case 'renameVariable':
            await renameVariable();
          case 'definition':
            await showSymbol('definition');
          case 'documentation':
            await showSymbol('documentation');
          case 'parameters':
            scheduleSemantic();
          case 'nextIssue':
            navigateIssue(1);
          case 'previousIssue':
            navigateIssue(-1);
          case 'run':
          case 'runDemo':
            if (entry != null) await run(call.method == 'runDemo');
          case 'stopRun':
            if (running) stopRun();
          case 'openTrace':
            if (!running && !checkingRun) await importTrace();
          case 'saveTrace':
            if (events.isNotEmpty || console.isNotEmpty) await exportTrace();
        }
      });
    }
    editor = CodeLineEditingController(
        options: const CodeLineOptions(indentSize: 4));
    bindEditorServices();
    editorContextMenu = EditorContextMenuController(editorMenuEntries, () {
      completionPopup.dismiss();
      decorations.dismissInline();
      hideDiagnosticHover();
    });
    editorFocus.addListener(() {
      if (!editorFocus.hasFocus) editorContextMenu.hide(context);
    });
    editorFocus.addListener(scheduleSemantic);
    editorFocus.addListener(scheduleInline);
    FocusManager.instance.addListener(updatePlatformEditState);
    lifecycle = AppLifecycleListener(onExitRequested: () async {
      if (!mounted) return AppExitResponse.exit;
      if (!await confirmWorkspaceClose()) return AppExitResponse.cancel;
      inlineTimer?.cancel();
      inlineGeneration++;
      await inlineModel.stop();
      return AppExitResponse.exit;
    });
    runtime = RuntimeAdapter(
        onEvent: receive,
        onFailure: (text) {
          if (mounted) {
            setState(() {
              console += text;
              status = '运行环境错误';
              running = false;
              showConsole = true;
              prompt = null;
              playing = false;
              timer?.cancel();
            });
          }
        });
    final path = p.join(RuntimeAdapter.root, 'examples', '逐行运算.py');
    final example = File(path);
    final source = example.existsSync()
        ? PythonSourceFile.tryUtf8(example.readAsBytesSync())
        : null;
    if (source != null) {
      _loading = true;
      editor.text = source.text;
      _loading = false;
      currentFile = path;
      recentFiles.add(path);
      entry = path;
      project = p.dirname(path);
      documents[path] =
          EditorDocument.existing(path, editor, source.text, source.format);
      refreshFiles();
    } else if (welcome && !Platform.isAndroid) {
      runtimePreparation =
          RuntimeAdapter.prepareBundledRuntime().catchError((Object e) {
        if (mounted) reportError('学习环境加载失败：$e');
      });
    } else if (!welcome) {
      loadBundledExample();
    }
    if (!Platform.isAndroid || !welcome) scheduleAnalysis();
    loadEditorPreferences();
    if (widget.aiEnabled &&
        widget.inlineModel == null &&
        inlineModel.available) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(inlineModel.warmUp());
        unawaited(inlineChecks.warmUp());
      });
    }
  }

  void bindEditorServices() {
    if (editorServicesReady) {
      editor.removeListener(onEditorChanged);
      finder.dispose();
      decorations.dispose();
    }
    completions = PythonPromptsBuilder(editor);
    finder = CodeFindController(editor);
    decorations = EditorDecorations(editor, editorFocus,
        onHover: showDiagnosticHover, onHoverExit: hideDiagnosticHover);
    decorations.modelMode = widget.aiEnabled && inlineModel.available;
    completionKeys = PythonCompletionActions(editor,
        finder: finder,
        popup: completionPopup,
        acceptInline: decorations.acceptInline,
        dismissInline: decorations.dismissInline);
    editor.addListener(onEditorChanged);
    editorServicesReady = true;
  }

  void onEditorChanged() {
    renameHint = null;
    updatePlatformEditState();
    scheduleSemantic();
    scheduleInline();
    if (!_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    if (editor.text == _lastText) {
      if (blueprintMode &&
          !_loading &&
          graphSelectedLine !=
              editor.index2lineIndex(editor.selection.extentIndex) + 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && blueprintMode) {
            setState(() => graphSelectedLine =
                editor.index2lineIndex(editor.selection.extentIndex) + 1);
          }
        });
      }
      return;
    }
    _lastText = editor.text;
    hideDiagnosticHover();
    if (!_loading) {
      scheduleAnalysis();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            if (blueprintMode) {
              graphSelectedLine =
                  editor.index2lineIndex(editor.selection.extentIndex) + 1;
            }
          });
        }
      });
    }
  }

  void activateDocument(EditorDocument document, {bool updateEntry = true}) {
    editorContextMenu.hide(context);
    renameHint = null;
    recentFiles.remove(document.path);
    recentFiles.insert(0, document.path);
    if (recentFiles.length > 40) recentFiles.removeLast();
    final previous = documents[currentFile];
    if (previous != null) {
      if (codeScroll.verticalScroller.hasClients) {
        previous.verticalOffset = codeScroll.verticalScroller.offset;
      }
      if (codeScroll.horizontalScroller.hasClients) {
        previous.horizontalOffset = codeScroll.horizontalScroller.offset;
      }
    }
    analysisTimer?.cancel();
    semanticTimer?.cancel();
    analysisGeneration++;
    semanticGeneration++;
    completionPopup.dismiss();
    hideDiagnosticHover();
    // Services bind to a document; every file retains its own controller/undo.
    final oldEditor = editor;
    if (!documents.values.any((d) => identical(d.controller, oldEditor))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        disposeDocumentController(oldEditor);
      });
    }
    oldEditor.removeListener(onEditorChanged);
    finder.dispose();
    decorations.dispose();
    editorServicesReady = false;
    editor = document.controller;
    _lastText = editor.text;
    currentFile = document.path;
    if (updateEntry) entry = currentFile;
    signatures = [];
    signatureSource = null;
    signatureSelection = null;
    diagnostics = [];
    allDiagnostics = [];
    checkedSource = null;
    analysisFailure = null;
    analyzedFile = null;
    graphSelectedLine = null;
    bindEditorServices();
    setState(() {});
    scheduleAnalysis();
    scheduleSemantic();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || currentFile != document.path) return;
      if (codeScroll.verticalScroller.hasClients) {
        codeScroll.verticalScroller.jumpTo(document.verticalOffset
            .clamp(0, codeScroll.verticalScroller.position.maxScrollExtent));
      }
      if (codeScroll.horizontalScroller.hasClients) {
        codeScroll.horizontalScroller.jumpTo(document.horizontalOffset
            .clamp(0, codeScroll.horizontalScroller.position.maxScrollExtent));
      }
    });
  }

  Future<bool> saveAllDocuments() async {
    if (!await save()) return false;
    for (final document in documents.values.toList()) {
      if (!document.dirty || document.readOnly) continue;
      if (!await save(document: document)) return false;
    }
    if (mounted) setState(() {});
    return true;
  }

  Future<bool> confirmWorkspaceClose() async {
    final changed = documents.values.where((d) => d.dirty).toList();
    if (changed.isEmpty) return await leaveFile();
    if (changed.length == 1 && changed.first.path == currentFile) {
      return await leaveFile();
    }
    final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('保存全部修改？'),
                content: Text(changed.map((d) => p.basename(d.path)).join('、')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, 'cancel'),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, 'discard'),
                      child: const Text('放弃修改')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, 'save'),
                      child: const Text('保存全部'))
                ]));
    return choice == 'discard' ||
        (choice == 'save' && await saveAllDocuments());
  }

  Future<void>? runtimePreparation;
  Future<void> loadBundledExample() async {
    await runtimePreparation;
    try {
      await RuntimeAdapter.prepareBundledRuntime();
      if (!mounted) return;
      await openFile(File(p.join(RuntimeAdapter.root, 'examples', '逐行运算.py')));
    } catch (e) {
      if (mounted) setState(() => status = '示例加载失败：$e');
    }
  }

  @override
  void dispose() {
    editorContextMenu.hide(context);
    if (Platform.isMacOS) {
      const MethodChannel('dev.pyvis/editor_commands')
          .setMethodCallHandler(null);
    }
    FocusManager.instance.removeListener(updatePlatformEditState);
    renameHintTimer?.cancel();
    lifecycle.dispose();
    stageScroll.dispose();
    analysisTimer?.cancel();
    for (final compilation in nodeCompilations.values) {
      compilation.dispose();
    }
    analysis.dispose();
    semantics.dispose();
    semanticTimer?.cancel();
    inlineTimer?.cancel();
    inlineModel.removeListener(updateInlineStatus);
    inlineModel.dispose();
    inlineChecks.dispose();
    completionPopup.dispose();
    renderedLines?.removeListener(updateHintGeometry);
    hintGeometry.dispose();
    hideDiagnosticHover();
    decorations.dispose();
    editorFocus.dispose();
    codeScroll.verticalScroller.dispose();
    codeScroll.horizontalScroller.dispose();
    codeScroll.dispose();
    timer?.cancel();
    runtime.stop();
    finder.dispose();
    for (final document in documents.values) {
      if (document.controller != editor) document.dispose();
    }
    disposeDocumentController(editor);
    input.dispose();
    super.dispose();
  }

  void receive(Map<String, dynamic> value) {
    if (!mounted) return;
    setState(() {
      if (value['kind'] == 'finished') {
        running = false;
        pendingDemoStep = false;
        if (!demo || playbackStops.isEmpty || cursor >= playbackStops.last) {
          playing = false;
          timer?.cancel();
        }
        sources = Map<String, dynamic>.from(value['sources'] ?? {});
        error = value['error'] == null
            ? null
            : Map<String, dynamic>.from(value['error']);
        if (!demo && error != null) {
          final problem = error!;
          console += '${problem['type']}：${problem['message']}\n';
        }
        status = error != null
            ? '执行中断 · ${error!['type']}'
            : blueprintMode
                ? '运行完成 · 可以拖动时间轴回看'
                : '运行完成 · 可在代码流程图回看';
        prompt = null;
      } else if (value.containsKey('seq')) {
        recording.add(value);
        if (running && demo) {
          // A Python return can produce several completed statements before the
          // next gate. Keep the first requested stop visible; later ones belong
          // to the replay buffer and must not replace it as they arrive.
          if (pendingDemoStep && isLearningStop(value)) {
            cursor = events.length - 1;
            inspectedTraceLine = null;
            pendingDemoStep = false;
            if (playing) schedulePlayback();
          } else if (playbackStops.isEmpty) {
            cursor = events.length - 1;
          }
        } else if (running && (isLearningStop(value) || !recording.hasStatement)) {
          cursor = events.length - 1;
          inspectedTraceLine = null;
        }
        if (value['kind'] == 'output') console += value['text'] as String;
        if (value['kind'] == 'input_request') {
          prompt = value['prompt'] as String;
          showConsole = true;
          playing = false;
          timer?.cancel();
        }
        if (value['kind'] == 'input') prompt = null;
      }
    });
    if (codeSyncScheduled) return;
    codeSyncScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      codeSyncScheduled = false;
      if (mounted) syncCodePosition();
    });
  }

  void syncCodePosition() {
    final current = selectedStep ?? event;
    final line = current?['line'];
    if (current?['file'] != currentFile ||
        line is! int ||
        line < 1 ||
        line > editor.text.split('\n').length ||
        dirty ||
        (sources[currentFile] != null && sources[currentFile] != editor.text)) {
      return;
    }
    editor.selection = CodeLineSelection.collapsed(
        index: revealSourceLine(editor, line - 1), offset: 0);
  }

  void scheduleSemantic() {
    semanticTimer?.cancel();
    final generation = ++semanticGeneration;
    if ((Platform.isAndroid && welcome && currentFile == null) ||
        !editorFocus.hasFocus ||
        running ||
        checkingRun ||
        editor.isComposing) {
      signatures = [];
      return;
    }
    semanticTimer = Timer(
        const Duration(milliseconds: 140), () => updateSemantic(generation));
  }

  Future<void> updateSemantic(int generation) async {
    if (semanticBusy) {
      semanticAgain = true;
      return;
    }
    semanticBusy = true;
    final source = editor.text;
    final selection = editor.selection;
    final file = currentFile ?? '<editor>.py';
    final line = editor.index2lineIndex(selection.extentIndex);
    final column = selection.extentOffset;
    try {
      final codePointColumn =
          source.split('\n')[line].substring(0, column).runes.length;
      final result = await semantics.complete(
          source, file, line + 1, codePointColumn, project);
      if (!mounted ||
          generation != semanticGeneration ||
          source != editor.text ||
          line != editor.index2lineIndex(editor.selection.extentIndex) ||
          column != editor.selection.extentOffset) {
        return;
      }
      setState(() {
        completions.semanticSource = source;
        completions.semanticLine = line;
        completions.semanticColumn = column;
        completions.semanticCompletions =
            (result['completions'] as List).cast<Map>();
        signatureSource = source;
        signatureSelection = selection;
        signatures = (result['signatures'] as List)
            .map((s) => Map<String, dynamic>.from(s))
            .toList();
      });
      if (result['context'] is Map) {
        decorations.setContext(result['context'] as Map, source);
      }
      completionPopup.refresh();
    } catch (_) {
      // Keep local syntax/AST suggestions when semantic analysis is unavailable.
      if (mounted && generation == semanticGeneration) {
        setState(() => signatures = []);
      }
    } finally {
      semanticBusy = false;
      if (semanticAgain && mounted) {
        semanticAgain = false;
        scheduleSemantic();
      }
    }
  }

  static const nativeEditIntents = <String, Intent>{
    'editUndo': UndoTextIntent(SelectionChangedCause.keyboard),
    'editRedo': RedoTextIntent(SelectionChangedCause.keyboard),
    'editCut': CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
    'editCopy': CopySelectionTextIntent.copy,
    'editPaste': PasteTextIntent(SelectionChangedCause.keyboard),
    'editSelectAll': SelectAllTextIntent(SelectionChangedCause.keyboard),
  };

  ({bool canRun, bool canStop, bool canOpen, bool canSave})? lastRunMenuState;

  void syncNativeRunMenu() {
    if (!Platform.isMacOS) return;
    final state = (
      canRun: !running && !checkingRun && entry != null,
      canStop: running,
      canOpen: !running && !checkingRun,
      canSave: events.isNotEmpty || console.isNotEmpty,
    );
    if (state == lastRunMenuState) return;
    lastRunMenuState = state;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || lastRunMenuState != state) return;
      unawaited(const MethodChannel('dev.pyvis/editor_commands')
          .invokeMethod<void>('runMenuState', {
        'run': state.canRun,
        'runDemo': state.canRun,
        'stopRun': state.canStop,
        'openTrace': state.canOpen,
        'saveTrace': state.canSave,
      }).catchError((Object _) {}));
    });
  }

  void updatePlatformEditState() {
    if (!Platform.isMacOS || !mounted || !editorServicesReady) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      scheduleMicrotask(updatePlatformEditState);
      return;
    }
    final code = editorFocus.hasFocus;
    final context = FocusManager.instance.primaryFocus?.context;
    bool enabled(String name) {
      if (code) {
        return switch (name) {
          'editUndo' => editorWritable && !editor.isComposing && editor.canUndo,
          'editRedo' => editorWritable && !editor.isComposing && editor.canRedo,
          'editCut' || 'editPaste' => editorWritable && !editor.isComposing,
          _ => true,
        };
      }
      if (name == 'editPaste' &&
          learningPanelKey.currentState?.questionHasFocus == true) {
        return true;
      }
      final intent = nativeEditIntents[name]!;
      return context != null &&
          (Actions.maybeFind(context, intent: intent)?.isEnabled(intent) ??
              false);
    }

    unawaited(const MethodChannel('dev.pyvis/editor_commands')
        .invokeMethod<void>('editState', {
      for (final name in nativeEditIntents.keys) name: enabled(name),
      for (final name in ['duplicateCode', 'startNewLine', 'completeStatement'])
        name: code && editorWritable && !editor.isComposing,
      'renameVariable': code && editorWritable && currentFile != null,
      'intentions': code && !editor.isComposing,
    }).catchError((Object _) {}));
  }

  Future<void> performNativeEdit(String name) async {
    final intent = nativeEditIntents[name];
    if (intent == null) return;
    if (editorFocus.hasFocus) {
      if (editor.isComposing) return;
      completionPopup.dismiss();
      decorations.dismissInline();
      switch (name) {
        case 'editUndo':
          if (editorWritable) editor.undo();
        case 'editRedo':
          if (editorWritable) editor.redo();
        case 'editCut':
          if (editorWritable) editor.cut();
        case 'editCopy':
          await editor.copy();
        case 'editPaste':
          if (editorWritable) editor.paste();
        case 'editSelectAll':
          editor.selectAll();
      }
    } else if (name == 'editPaste' &&
        learningPanelKey.currentState?.questionHasFocus == true) {
      await learningPanelKey.currentState?.pasteQuestion();
    } else {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context != null) Actions.maybeInvoke(context, intent);
    }
    updatePlatformEditState();
  }

  void updateInlineStatus() {
    if (mounted) setState(() {});
  }

  void scheduleInline() {
    if (!widget.aiEnabled) return;
    inlineTimer?.cancel();
    final generation = ++inlineGeneration;
    inlineModel.cancel();
    if (!inlineModel.available ||
        !editorFocus.hasFocus ||
        !editorWritable ||
        running ||
        editor.isComposing ||
        _loading ||
        !editor.selection.isCollapsed ||
        decorations.ghost != null) {
      return;
    }
    inlineTimer = Timer(const Duration(milliseconds: 100), () async {
      if (!mounted ||
          generation != inlineGeneration ||
          running ||
          !editorFocus.hasFocus ||
          editor.isComposing) {
        return;
      }
      final source = editor.text;
      final selection = editor.selection;
      final line = editor.index2lineIndex(selection.extentIndex);
      final column = selection.extentOffset;
      final rows = source.split('\n');
      final offset =
          rows.take(line).fold<int>(0, (n, row) => n + row.length + 1) + column;
      final prefix = source.substring(0, offset);
      if (prefix.trim().isEmpty || !pythonCodePosition(prefix)) return;
      final file = currentFile;
      final pythonColumn = rows[line].substring(0, column).runes.length;
      bool isCurrent() =>
          mounted &&
          generation == inlineGeneration &&
          currentFile == file &&
          editorFocus.hasFocus &&
          !editor.isComposing &&
          !running &&
          editorWritable &&
          !_loading &&
          source == editor.text;
      try {
        await for (final prediction
            in inlineModel.predictions(prefix, source.substring(offset))) {
          if (!isCurrent()) return;
          final reply = await inlineChecks.request({
            'action': 'validate_inline',
            'source': source,
            'line': line + 1,
            'column': pythonColumn,
            'prediction': prediction,
          });
          if (!isCurrent()) return;
          final validated = reply['prediction'];
          if (validated is String) {
            decorations.setModelPrediction(source, line, column, validated);
            return;
          }
        }
      } catch (_) {
        /* Optional inference must not interrupt editing or lookup. */
      }
    });
  }

  void hideDiagnosticHover() {
    diagnosticHover?.remove();
    diagnosticHover = null;
  }

  void showDiagnosticHover(Map<String, dynamic> issue, Rect anchor) {
    if (!mounted) return;
    hideDiagnosticHover();
    diagnosticHover = OverlayEntry(builder: (context) {
      final screen = MediaQuery.sizeOf(context);
      final width = (screen.width - 24).clamp(180, 440).toDouble();
      return Positioned(
          left: anchor.left
              .clamp(8, (screen.width - width - 8).clamp(8, screen.width)),
          top: (anchor.bottom + 6)
              .clamp(8, (screen.height - 150).clamp(8, screen.height)),
          width: width,
          child: IgnorePointer(
              child: Material(
                  elevation: 8,
                  color: PyvisColors.raised,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('${issue['message']}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color:
                                        InspectionStyle.forIssue(issue).color)),
                            const SizedBox(height: 6),
                            Text('${issue['hint']}',
                                style: const TextStyle(fontSize: 12)),
                            const SizedBox(height: 6),
                            Text(
                                '${p.basename(issue['file'])}:${issue['line']}:${issue['column']}',
                                style:
                                    const TextStyle(fontSize: 10, color: muted))
                          ])))));
    });
    Overlay.of(context).insert(diagnosticHover!);
  }

  void updateHintGeometry() {
    if (hintGeometryQueued) return;
    hintGeometryQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      hintGeometryQueued = false;
      if (mounted) hintGeometry.value++;
    });
  }

  Widget parameterHint() => Positioned.fill(child:
          IgnorePointer(child: LayoutBuilder(builder: (context, constraints) {
        return AnimatedBuilder(
            animation: Listenable.merge([
              editor,
              editorFocus,
              finder,
              completionPopup,
              hintGeometry,
            ]),
            builder: (context, _) {
              if (!editorFocus.hasFocus ||
                  signatures.isEmpty ||
                  running ||
                  checkingRun ||
                  editor.isComposing ||
                  finder.value != null ||
                  signatureSource != editor.text ||
                  signatureSelection != editor.selection) {
                return const SizedBox.shrink();
              }
              final paragraphs = renderedLines?.value?.paragraphs ?? [];
              final matches = paragraphs
                  .where((p) => p.index == editor.selection.extentIndex);
              if (matches.isEmpty) return const SizedBox.shrink();
              final paragraph = matches.first;
              final point = paragraph.getOffset(
                  TextPosition(offset: editor.selection.extentOffset));
              if (point == null) return const SizedBox.shrink();
              final gutter =
                  gutterKey.currentContext?.findRenderObject() as RenderBox?;
              final gutterWidth = gutter?.size.width ?? 65;
              final caret = Rect.fromLTWH(
                  gutterWidth + paragraph.offset.dx + point.dx,
                  paragraph.offset.dy + point.dy,
                  1,
                  paragraph.preferredLineHeight);
              final surface = context.findRenderObject() as RenderBox?;
              final origin = surface?.localToGlobal(Offset.zero) ?? Offset.zero;
              final avoid = completionPopup.bounds?.shift(-origin);
              final viewport = Rect.fromLTRB(
                  gutterWidth,
                  4,
                  constraints.maxWidth -
                      18 -
                      (miniMapVisible ? editorMiniMapWidth : 0),
                  constraints.maxHeight - 4);
              final width = viewport.width.clamp(0, 520).toDouble();
              final box = placeParameterHint(
                  caret, Size(width, ParameterHint.height), viewport,
                  avoid: avoid);
              if (box == null) return const SizedBox.shrink();
              return Stack(children: [
                Positioned.fromRect(
                    rect: box,
                    child: ParameterHint(signature: signatures.first))
              ]);
            });
      })));

  void scheduleAnalysis() {
    analysisTimer?.cancel();
    if (Platform.isAndroid && welcome && currentFile == null) return;
    final generation = ++analysisGeneration;
    if (analyzedFile != currentFile) {
      completions.analysis = {};
      completions.semanticSource = null;
      signatures = [];
      completionPopup.dismiss();
      decorations.clearForFile();
    }
    analyzedFile = currentFile;
    checkedSource = null;
    analysisFailure = null;
    diagnostics = [];
    allDiagnostics = [];
    analyzing = true;
    analysisTimer = Timer(
        const Duration(milliseconds: 350), () => analyzeBuffer(generation));
  }

  Future<void> analyzeBuffer(int generation) async {
    if (inspectionBusy) {
      inspectionAgain = true;
      return;
    }
    inspectionBusy = true;
    final source = editor.text;
    final file = currentFile ?? '<editor>';
    try {
      final result = await analysis.analyze(
          source,
          file,
          project,
          {for (final d in documents.values) d.path: d.controller.text},
          dictionaryWords.toList());
      if (!mounted ||
          generation != analysisGeneration ||
          source != editor.text ||
          file != (currentFile ?? '<editor>')) {
        return;
      }
      setState(() {
        completions.analysis = result;
        allDiagnostics = (result['diagnostics'] as List)
            .map((d) => Map<String, dynamic>.from(d))
            .toList();
        diagnostics = allDiagnostics
            .where((d) => enabledInspections.contains(inspectionGroup(d)))
            .toList();
        checkedSource = source;
        analyzing = false;
        final failures = result['inspection_failures'] as List? ?? [];
        analysisFailure = failures.isEmpty ? null : failures.join('；');
      });
      decorations.setAnalysis(
          result, source, diagnostics.where((d) => d['file'] == file).toList());
      completionPopup.refresh();
    } catch (e) {
      if (mounted && generation == analysisGeneration) {
        setState(() {
          analyzing = false;
          analysisFailure = '$e';
        });
      }
    } finally {
      inspectionBusy = false;
      if (inspectionAgain && mounted) {
        inspectionAgain = false;
        scheduleAnalysis();
      }
    }
  }

  void applyEditorPreferences(EditorPreferences preferences) {
    setState(() {
      editorFontSize = preferences.fontSize;
      softWrap = preferences.softWrap;
      showMiniMap = preferences.miniMap;
      showLineNumbers = preferences.lineNumbers;
      highlightCurrentLine = preferences.highlightCurrentLine;
      autoClosePairs = preferences.autoClosePairs;
      enabledInspections = preferences.inspections;
      dictionaryWords = preferences.dictionaryWords;
      diagnostics = allDiagnostics
          .where((d) => enabledInspections.contains(inspectionGroup(d)))
          .toList();
    });
    decorations.setAnalysis(completions.analysis, editor.text,
        diagnostics.where((d) => d['file'] == currentFile).toList());
  }

  Future<void> loadEditorPreferences() async {
    try {
      final preferences = await EditorPreferences.load();
      if (mounted && preferences != null) applyEditorPreferences(preferences);
    } catch (_) {/* Invalid old preferences keep the defaults. */}
  }

  EditorPreferences get editorPreferences => EditorPreferences(
      fontSize: editorFontSize,
      softWrap: softWrap,
      miniMap: showMiniMap,
      lineNumbers: showLineNumbers,
      highlightCurrentLine: highlightCurrentLine,
      autoClosePairs: autoClosePairs,
      inspections: enabledInspections,
      dictionaryWords: dictionaryWords);

  final aiConfigStore = AiConfigStore(cacheForSession: true);
  final learningMessages = <AiMessage>[];
  Map<String, dynamic>? learningDiagnostic;
  Map<String, String>? learningContext;
  bool showLearningAi = false;
  bool chatInEditor = true;
  bool chatTabSelected = true;
  bool get chatTabOpen => chatInEditor && showLearningAi;
  bool get editorTabActive => !(chatTabOpen && chatTabSelected);
  void toggleChatPlacement() => setState(() {
        learningContext ??= {};
        chatTabSelected = true;
        chatInEditor = !chatInEditor;
        showLearningAi = true;
      });
  final learningPanelKey = GlobalKey<LearningAiPanelState>();

  void hideLearningAi() => setState(() {
        showLearningAi = false;
        chatInEditor = false;
      });

  void showAiNotice() {
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(
          const SnackBar(content: Text('开发中'), duration: Duration(seconds: 2)));
  }

  void toggleLearningAi() {
    if (!widget.aiEnabled) return showAiNotice();
    if (chatTabOpen) {
      if (!chatTabSelected) {
        setState(() => chatTabSelected = true);
      } else {
        hideLearningAi();
      }
      return;
    }
    if (showLearningAi) {
      hideLearningAi();
    } else {
      openLearningAi();
    }
  }

  void openLearningAi({Map<String, dynamic>? diagnostic}) {
    if (!widget.aiEnabled) return showAiNotice();
    final selectedCode = editor.selectedText;
    final currentError = diagnostic ?? error;
    final step = selectedStep ?? event;
    final contextData = <String, String>{
      if (selectedCode.isNotEmpty) '选中的代码': selectedCode,
      if (currentError != null)
        '当前错误': const JsonEncoder.withIndent('  ').convert(currentError),
      if (step != null)
        '当前演示步骤': const JsonEncoder.withIndent('  ').convert(step),
    };
    setState(() {
      learningContext = contextData;
      showLearningAi = true;
      chatInEditor = true;
      chatTabSelected = true;
    });
  }

  String learningDisplayPath(String path, String? root) =>
      root != null && p.isWithin(root, path)
          ? p.relative(path, from: root)
          : p.basename(path);

  LearningReference fileLearningReference(String path) {
    final root = project;
    return (
      label: '文件 · ${learningDisplayPath(path, root)}',
      read: () => readLearningReference(path, root),
    );
  }

  LearningReference? selectedLearningReference() {
    final snippet = editor.selectedText;
    if (snippet.isEmpty) return null;
    final file = currentFile;
    final selection = editor.selection;
    final start = editor.index2lineIndex(selection.startIndex) + 1;
    final end = editor.index2lineIndex(selection.endIndex) + 1;
    final name = file == null ? '当前编辑器' : learningDisplayPath(file, project);
    return (label: '代码 · $name:L$start–$end', read: () async => snippet);
  }

  List<LearningReference> learningReferences() {
    final file = currentFile;
    final selected = selectedLearningReference();
    final candidates = {
      for (final file in files) file.path,
      if (file != null) file,
      ...documents.keys,
    }.toList()
      ..sort();
    return [
      if (selected != null) selected,
      for (final path in candidates) fileLearningReference(path),
    ];
  }

  Widget draggableLearningReference(
          LearningReference reference, Widget child) =>
      !widget.aiEnabled
          ? child
          : Draggable<LearningReference>(
              data: reference,
              maxSimultaneousDrags: 1,
              onDragStarted: () {
                if (!showLearningAi) openLearningAi();
              },
              feedback: Material(
                color: PyvisColors.selection,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Text(reference.label,
                      style: const TextStyle(fontSize: 12)),
                ),
              ),
              child: child,
            );

  Future<String> readLearningReference(String path, String? root) async {
    const maxBytes = 48 * 1024;
    final document = documents[path];
    if (document != null) {
      final text = document.controller.text;
      if (utf8.encode(text).length > maxBytes) {
        throw const AiFailure('文件超过 48 KB，请选中所需片段后引用。');
      }
      return text;
    }
    var file = File(path);
    if (root != null) {
      final resolvedRoot = await Directory(root).resolveSymbolicLinks();
      final resolvedPath = await file.resolveSymbolicLinks();
      if (!p.isWithin(resolvedRoot, resolvedPath)) {
        throw const AiFailure('只能引用项目内或已在编辑器中打开的文件。');
      }
      file = File(resolvedPath);
    }
    final info = await file.stat();
    if (info.type != FileSystemEntityType.file) {
      throw const AiFailure('只能引用普通文件。');
    }
    if (info.size > maxBytes) {
      throw const AiFailure('文件超过 48 KB，请选中所需片段后引用。');
    }
    return (await PythonSourceFile.read(file, analysis)).text;
  }

  Widget learningPanel() => Offstage(
      offstage: !showLearningAi,
      child: ExcludeFocus(
          excluding: !showLearningAi,
          child: SizedBox(
              width: chatInEditor
                  ? double.infinity
                  : (MediaQuery.sizeOf(context).width * .42).clamp(240, 360),
              child: LearningAiPanel(
                  key: learningPanelKey,
                  inEditor: chatInEditor,
                  onChatsChanged: () => setState(() {}),
                  onModelChanged: () => setState(() {}),
                  onTogglePlacement: toggleChatPlacement,
                  available: learningContext!,
                  messages: learningMessages,
                  store: aiConfigStore,
                  references: learningReferences,
                  onClose: hideLearningAi))));

  Future<void> openEditorSettings({int initialPage = 0}) async {
    if (initialPage == 4 && !widget.aiEnabled) return showAiNotice();
    Future<bool> savePreferences(EditorPreferences preferences) async {
      try {
        await preferences.save();
        if (mounted) applyEditorPreferences(preferences);
        return true;
      } catch (error) {
        if (mounted) reportError('无法保存编辑器设置：$error');
        return false;
      }
    }

    final preferences = await showDialog<EditorPreferences>(
        context: context,
        builder: (ctx) => EditorSettingsDialog(
            aiEnabled: widget.aiEnabled,
            mac: macKeys,
            aiStore: aiConfigStore,
            initialPage: initialPage,
            onApply: savePreferences,
            preferences: editorPreferences));
    if (!mounted || preferences == null) return;
    await savePreferences(preferences);
  }

  Map<EditorCommand, VoidCallback> get editorCommands => {
        EditorCommand.renameVariable: renameVariable,
        EditorCommand.duplicate: () {
          if (editorWritable) duplicateCode(editor);
        },
        EditorCommand.startNewLine: () {
          if (editorWritable) startNewCodeLine(editor);
        },
        EditorCommand.completeStatement: () {
          if (editorWritable) startNewCodeLine(editor, complete: true);
        },
        EditorCommand.format: () => formatBuffer(),
        EditorCommand.imports: () => formatBuffer(imports: true),
        EditorCommand.definition: () => showSymbol('definition'),
        EditorCommand.documentation: () => showSymbol('documentation'),
        EditorCommand.parameters: scheduleSemantic,
        EditorCommand.intentions: showIntentions,
        EditorCommand.nextIssue: () => navigateIssue(1),
        EditorCommand.previousIssue: () => navigateIssue(-1),
        EditorCommand.goToLine: goToLineDialog,
      };

  List<EditorMenuEntry> editorMenuEntries() => [
        EditorMenuEntry('cut', '剪切', () => editor.cut(),
            shortcut: macKeys ? '⌘X' : 'Ctrl+X', enabled: editorWritable),
        EditorMenuEntry('copy', '复制', () => editor.copy(),
            shortcut: macKeys ? '⌘C' : 'Ctrl+C'),
        EditorMenuEntry('paste', '粘贴', () => editor.paste(),
            shortcut: macKeys ? '⌘V' : 'Ctrl+V', enabled: editorWritable),
        for (final command in const [
          EditorCommand.duplicate,
          EditorCommand.definition,
          EditorCommand.documentation,
          EditorCommand.parameters,
          EditorCommand.renameVariable,
          EditorCommand.format,
          EditorCommand.imports,
          EditorCommand.intentions,
          EditorCommand.goToLine,
        ])
          EditorMenuEntry(command.name, editorCommandLabels[command]!, () {
            editorFocus.requestFocus();
            editorCommands[command]!();
          }, shortcut: keymap.label(command), enabled: editorWritable),
        EditorMenuEntry('inspect', '检查代码', checkCode),
      ];

  void goToSource(int sourceLine, int column) {
    final lines = editor.text.split('\n');
    final line = sourceLine.clamp(0, lines.length - 1);
    final index = revealSourceLine(editor, line);
    editor.selection = CodeLineSelection.collapsed(
        index: index, offset: column.clamp(0, lines[line].length));
    editorFocus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        codeScroll.makeCenterIfInvisible(CodeLinePosition(
            index: index, offset: editor.selection.extentOffset));
      }
    });
  }

  void navigateIssue(int direction) {
    final issues = diagnostics.where((d) => d['file'] == currentFile).toList()
      ..sort((a, b) {
        final byLine = (a['line'] as int).compareTo(b['line'] as int);
        return byLine != 0
            ? byLine
            : (a['column'] as int).compareTo(b['column'] as int);
      });
    if (issues.isEmpty) return;
    final highest = issues
        .map((d) => InspectionStyle.forIssue(d).priority)
        .reduce((a, b) => a > b ? a : b);
    issues.removeWhere((d) => InspectionStyle.forIssue(d).priority < highest);
    final line = editor.index2lineIndex(editor.selection.extentIndex) + 1;
    final column = editor.codeLines[editor.selection.extentIndex].text
            .substring(0, editor.selection.extentOffset)
            .runes
            .length +
        1;
    final matches = issues
        .where((d) => direction > 0
            ? d['line'] > line || d['line'] == line && d['column'] > column
            : d['line'] < line || d['line'] == line && d['column'] < column)
        .toList();
    locateDiagnostic(matches.isEmpty
        ? (direction > 0 ? issues.first : issues.last)
        : (direction > 0 ? matches.first : matches.last));
  }

  String get caretLocation {
    final caret = editor.selection;
    final line = editor.index2lineIndex(caret.extentIndex) + 1;
    final column =
        editor.extentLine.text.substring(0, caret.extentOffset).runes.length +
            1;
    return '$line:$column';
  }

  Future<void> goToLineDialog() async {
    if (currentFile == null || !editorTabActive) return;
    final document = editor;
    final location = caretLocation;
    final value = await showDialog<String>(
        context: context,
        builder: (_) => EditorGoToLineDialog(
            initial: location, lineCount: editor.text.split('\n').length));
    if (!mounted || value == null || !identical(editor, document)) return;
    final parts = value.split(':');
    final line = int.tryParse(parts.first.trim());
    if (line != null) {
      final lines = editor.text.split('\n');
      final row = (line - 1).clamp(0, lines.length - 1);
      final column = parts.length > 1 ? int.tryParse(parts[1].trim()) ?? 1 : 1;
      goToSource(row, pythonColumnOffset(lines[row], column));
    }
  }

  Future<void> renameVariable() async {
    final file = currentFile;
    if (file == null ||
        !editorTabActive ||
        !editorWritable ||
        editor.isComposing) {
      return;
    }
    if (renameHint != null) setState(() => renameHint = null);
    final document = editor;
    final source = document.text, selection = document.selection;
    final line = document.index2lineIndex(selection.startIndex);
    final column = source
        .split('\n')[line]
        .substring(0, selection.startOffset)
        .runes
        .length;
    bool stillCurrent() =>
        identical(document, editor) &&
        currentFile == file &&
        editorWritable &&
        editor.text == source;
    try {
      final info = await semantics.symbol(
          'rename', source, file, line + 1, column, project);
      if (!mounted || !stillCurrent()) return;
      final result = await showDialog<Map<String, dynamic>>(
          context: context,
          barrierColor: Colors.black38,
          builder: (ctx) => RenameVariableDialog(
              name: info['name'] as String,
              file: p.basename(file),
              count: info['count'] as int,
              submit: (name) => semantics.symbol(
                  'rename', source, file, line + 1, column, project,
                  candidate: name)));
      if (!mounted || result == null || !stillCurrent()) return;
      expandAllCode(editor);
      editor.selectAll();
      editor.replaceSelection(result['source'] as String);
      goToSource(line,
          selection.startOffset.clamp(0, editor.text.split('\n')[line].length));
      setState(() => status = '已重命名 ${result['count']} 处变量');
    } catch (e) {
      if (!mounted || !stillCurrent() || document.selection != selection) {
        return;
      }
      setState(() => renameHint = renameErrorMessage(e));
      renameHintTimer?.cancel();
      renameHintTimer = Timer(const Duration(seconds: 6), () {
        if (mounted && renameHint != null) setState(() => renameHint = null);
      });
    }
  }

  Future<void> formatBuffer({bool imports = false}) async {
    if (formatting ||
        checkingRun ||
        fileBusy ||
        editor.isComposing ||
        (documents[currentFile]?.readOnly ?? false)) {
      return;
    }
    final source = editor.text, file = currentFile ?? '<editor>.py';
    final selection = editor.selection;
    final line = editor.index2lineIndex(selection.extentIndex),
        column = selection.extentOffset;
    completionPopup.dismiss();
    decorations.dismissInline();
    setState(() => formatting = true);
    try {
      final selectionRange = selection.isCollapsed
          ? null
          : '${editor.index2lineIndex(selection.startIndex) + 1}:${source.split('\n')[editor.index2lineIndex(selection.startIndex)].substring(0, selection.startOffset).runes.length + 1}-${editor.index2lineIndex(selection.endIndex) + 1}:${source.split('\n')[editor.index2lineIndex(selection.endIndex)].substring(0, selection.endOffset).runes.length + 1}';
      final result = await semantics.format(source, file,
          imports: imports, selection: selectionRange);
      if (!mounted ||
          editor.text != source ||
          (currentFile ?? '<editor>.py') != file) {
        return;
      }
      final formatted = result['source'] as String;
      if (formatted != source) {
        expandAllCode(editor);
        editor.selectAll();
        editor.replaceSelection(formatted);
        goToSource(line, column);
      }
      setState(() => status = imports ? '已优化导入' : '已重新格式化代码');
    } catch (error) {
      if (mounted) reportError('无法格式化：$error');
    } finally {
      if (mounted) setState(() => formatting = false);
    }
  }

  Future<void> showSymbol(String action) async {
    if (editor.isComposing || fileBusy) return;
    final source = editor.text, file = currentFile ?? '<editor>.py';
    final selection = editor.selection;
    final line = editor.index2lineIndex(selection.extentIndex);
    final column = source
        .split('\n')[line]
        .substring(0, selection.extentOffset)
        .runes
        .length;
    try {
      final result = await semantics.symbol(
          action, source, file, line + 1, column, project,
          candidate: completionPopup.notifier?.value
              .prompts[completionPopup.notifier!.value.index].word);
      if (!mounted ||
          source != editor.text ||
          file != (currentFile ?? '<editor>.py')) {
        return;
      }
      if (action == 'definition') {
        final definitions = (result['definitions'] as List).cast<Map>();
        if (definitions.isEmpty) {
          reportError('未找到此位置的声明。');
          return;
        }
        final d = definitions.first;
        final definitionPath = d['file'] as String;
        if (definitionPath != currentFile) {
          await openFile(File(definitionPath),
              updateEntry: false, preserveProject: project != null);
        }
        if (!mounted || currentFile != File(definitionPath).absolute.path) return;
        if (project != null && !p.isWithin(project!, currentFile!)) {
          documents[currentFile]?.readOnly = true;
        }
        goToSource(
            (d['line'] as int) - 1,
            pythonColumnOffset(editor.text.split('\n')[(d['line'] as int) - 1],
                d['column'] as int));
      } else {
        final docs = (result['documentation'] as List).cast<Map>();
        if (docs.isEmpty) {
          reportError('未找到此位置的文档。');
          return;
        }
        await showDialog<void>(
            context: context,
            builder: (_) => QuickDocumentation(documents: docs));
      }
    } catch (error) {
      if (mounted) reportError('无法获取代码信息：$error');
    }
  }

  Future<void> showIntentions() async {
    completionPopup.dismiss();
    hideDiagnosticHover();
    final source = editor.text;
    final file = currentFile;
    final line = editor.index2lineIndex(editor.selection.extentIndex) + 1;
    final issues = diagnostics
        .where((d) =>
            d['file'] == currentFile &&
            d['line'] <= line &&
            (d['end_line'] ?? d['line']) >= line)
        .toList();
    final fixes = <Map>[];
    for (final issue in issues) {
      fixes.addAll((issue['fixes'] as List? ?? [])
          .cast<Map>()
          .where((f) => f['applicability'] == 'safe'));
    }
    final gutter = gutterKey.currentContext?.findRenderObject() as RenderBox?;
    final paragraphs = renderedLines?.value?.paragraphs ?? [];
    final current =
        paragraphs.where((p) => p.index == editor.selection.extentIndex);
    var anchor = const Offset(200, 140);
    if (gutter != null && current.isNotEmpty) {
      final p = current.first;
      final point =
          p.getOffset(TextPosition(offset: editor.selection.extentOffset));
      if (point != null) {
        anchor = gutter.localToGlobal(Offset(
            gutter.size.width + p.offset.dx + point.dx,
            p.offset.dy + point.dy + p.preferredLineHeight));
      }
    }
    final screen = MediaQuery.sizeOf(context);
    final chosen = await showMenu<int>(
        context: context,
        color: PyvisColors.raised,
        position: RelativeRect.fromLTRB(anchor.dx.clamp(0, screen.width - 40),
            anchor.dy.clamp(0, screen.height - 40), 0, 0),
        items: [
          for (var i = 0; i < fixes.length; i++)
            IdeMenuItem(
                value: i,
                height: 30,
                child: Text('${fixes[i]['title']}',
                    style: const TextStyle(fontSize: 12))),
          const IdeMenuItem(
              value: -1,
              height: 30,
              child: Text('显示问题详情', style: TextStyle(fontSize: 12))),
        ]);
    if (!mounted || chosen == null) return;
    if (chosen < 0) {
      setState(openProblems);
      return;
    }
    if (file != currentFile ||
        source != editor.text ||
        checkedSource != source) {
      reportError('代码已变化，请重新检查后再修复。');
      return;
    }
    if (fixes[chosen]['action'] == 'dictionary_add') {
      dictionaryWords.add('${fixes[chosen]['word']}'.toLowerCase());
      try {
        await editorPreferences.save();
      } catch (error) {
        if (mounted) reportError('无法保存词典：$error');
      }
      if (mounted) {
        scheduleAnalysis();
        editorFocus.requestFocus();
      }
      return;
    }
    final lines = source.split('\n');
    int offset(Map location) {
      final row = (location['row'] as int) - 1;
      return lines.take(row).fold<int>(0, (sum, s) => sum + s.length + 1) +
          pythonColumnOffset(lines[row], location['column'] as int);
    }

    final edits = (fixes[chosen]['edits'] as List)
        .cast<Map>()
        .map((e) => (
              start: offset(e['location']),
              end: offset(e['end_location']),
              text: '${e['content']}'
            ))
        .toList()
      ..sort((a, b) => b.start.compareTo(a.start));
    var updated = source;
    for (final edit in edits) {
      updated = updated.replaceRange(edit.start, edit.end, edit.text);
    }
    expandAllCode(editor);
    editor.selectAll();
    editor.replaceSelection(updated);
    goToSource(line - 1, 0);
  }

  Future<void> checkCode() async {
    if (checkingRun) return;
    analysisTimer?.cancel();
    final generation = ++analysisGeneration;
    setState(() => analyzing = true);
    await analyzeBuffer(generation);
    if (!mounted) return;
    setState(openProblems);
  }

  Future<void> locateDiagnostic(Map<String, dynamic> diagnostic) async {
    final file = diagnostic['file'] as String;
    if (file != currentFile) {
      final originalStatus = status;
      await openFile(File(file), updateEntry: false);
      if (!mounted) return;
      setState(() => status = originalStatus);
      if (file != currentFile) return;
    }
    final lines = editor.text.split('\n');
    final line =
        ((diagnostic['line'] as num).toInt() - 1).clamp(0, lines.length - 1);
    final column =
        pythonColumnOffset(lines[line], (diagnostic['column'] as num).toInt())
            .clamp(0, lines[line].length);
    final visible = revealSourceLine(editor, line);
    editor.selection =
        CodeLineSelection.collapsed(index: visible, offset: column);
    editorFocus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        codeScroll.makeCenterIfInvisible(
            CodeLinePosition(index: visible, offset: column));
      }
    });
  }

  Widget codeCheckBar() => InspectionBadge(
      diagnostics: diagnostics.where((d) => d['file'] == currentFile).toList(),
      busy: analyzing || checkingRun,
      failure: analysisFailure,
      onOpen: checkCode,
      onNext: () => navigateIssue(1),
      onPrevious: () => navigateIssue(-1));

  Widget problemsPane() => EditorProblemsPane(
      diagnostics: diagnostics,
      failure: analysisFailure,
      onSelect: (diagnostic) {
        setState(() => learningDiagnostic = diagnostic);
        locateDiagnostic(diagnostic);
      });

  void reportError(String message) {
    if (!mounted) return;
    setState(() => status = message);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> setSourceEncoding(
      EditorDocument document, String encoding) async {
    if (!editorWritable || editor.isComposing || currentFile != document.path) {
      return;
    }
    final before = document.controller.text;
    final previous = document.format;
    try {
      final converted =
          await PythonSourceFile.convert(before, encoding, semantics);
      if (!mounted ||
          documents[currentFile] != document ||
          document.controller.text != before ||
          document.format != previous ||
          !editorWritable) {
        return;
      }
      if (converted != before) {
        final selection = editor.selection;
        final line = editor.index2lineIndex(selection.extentIndex);
        final oldLines = before.split('\n'), newLines = converted.split('\n');
        final headerLine = oldLines.first.startsWith('#!') ? 1 : 0;
        expandAllCode(editor);
        editor.selectAll();
        editor.replaceSelection(converted);
        goToSource(
            line >= headerLine
                ? line + newLines.length - oldLines.length
                : line,
            selection.extentOffset);
      }
      setState(() => document.format =
          (lineEnding: previous.lineEnding, encoding: encoding));
    } catch (error) {
      if (mounted && documents[currentFile] == document) {
        reportError('无法转换文件编码：$error');
      }
    }
  }

  Widget pythonEnvironmentControl(Widget Function(String) label) => MenuAnchor(
          menuChildren: [
            Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                child: Text('Python 运行环境',
                    style: TextStyle(fontSize: 12, color: muted))),
            const Divider(height: 1),
            ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 390, minWidth: 240),
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: FutureBuilder(
                        future: pythonDetails,
                        builder: (_, snapshot) {
                          if (snapshot.connectionState !=
                              ConnectionState.done) {
                            return const Text('正在检测 Python…');
                          }
                          final details = snapshot.data;
                          if (details == null) {
                            return const Text('当前 Python 运行环境不可用。');
                          }
                          return Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  const Icon(Icons.check,
                                      size: 15, color: accent),
                                  const SizedBox(width: 8),
                                  Text('Python ${details.version}')
                                ]),
                                const SizedBox(height: 10),
                                const Text('可执行文件',
                                    style:
                                        TextStyle(fontSize: 12, color: muted)),
                                const SizedBox(height: 3),
                                SelectableText(details.executable,
                                    style: const TextStyle(fontSize: 12))
                              ]);
                        }))),
          ],
          builder: (_, controller, __) => Tooltip(
              message: '查看 Python 运行环境',
              child: TextButton(
                  onPressed: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                  style: TextButton.styleFrom(
                      padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
                  child: FutureBuilder(
                      future: pythonDetails,
                      builder: (_, snapshot) {
                        final version =
                            snapshot.data?.version.split('.').take(2).join('.');
                        return label(version != null
                            ? 'Python $version'
                            : snapshot.connectionState == ConnectionState.done
                                ? '解释器不可用'
                                : 'Python…');
                      }))));
  void hideToolWindows() => setState(() {
        showConsole = false;
        showLearningAi = false;
        if (blueprintMode) {
          if (showExecution) showVariableChanges = false;
        } else {
          showProblems = false;
        }
      });

  Widget statusBar() {
    final document = documents[currentFile];
    final format = document?.format ?? defaultSourceFormat;
    const labelStyle = TextStyle(fontSize: 13, color: muted);
    final canChangeFormat = document != null && editorWritable;
    final toolWindowsVisible = showLearningAi ||
        showConsole ||
        (blueprintMode ? showExecution && showVariableChanges : showProblems);
    Widget label(String text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7),
        child: Text(text, style: labelStyle));
    Widget item<T>(T value, String name, T selected) =>
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(value == selected ? Icons.check : null, size: 16),
          const SizedBox(width: 7),
          Text(name),
        ]);
    final controls = Row(mainAxisSize: MainAxisSize.min, children: [
      Tooltip(
          message: '转到行列',
          child: TextButton(
              onPressed: currentFile != null && editorTabActive
                  ? goToLineDialog
                  : null,
              style: TextButton.styleFrom(
                  padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
              child: label(caretLocation))),
      PopupMenuButton<TextLineBreak>(
          tooltip: '选择换行符',
          enabled: canChangeFormat,
          onSelected: (ending) {
            if (documents[currentFile] != document || !editorWritable) return;
            setState(() => document!.format =
                (lineEnding: ending, encoding: document.format.encoding));
          },
          itemBuilder: (_) => [
                for (final entry in const {
                  TextLineBreak.lf: 'LF（Unix / macOS）',
                  TextLineBreak.crlf: 'CRLF（Windows）',
                  TextLineBreak.cr: 'CR（旧版 Mac）'
                }.entries)
                  IdeMenuItem(
                      value: entry.key,
                      child: item(entry.key, entry.value, format.lineEnding)),
              ],
          child: label(format.lineEnding.name.toUpperCase())),
      PopupMenuButton<String>(
          tooltip: '选择文件编码',
          enabled: canChangeFormat,
          onSelected: (encoding) => setSourceEncoding(document!, encoding),
          itemBuilder: (_) => [
                for (final entry in sourceEncodings.entries)
                  IdeMenuItem(
                      value: entry.key,
                      child: item(entry.key, entry.value, format.encoding)),
              ],
          child: label(encodingLabel(format.encoding))),
      ib('save', dirty ? '保存当前文件（有未保存修改）' : '保存当前文件',
          editorWritable ? () => save() : null,
          size: 15, extent: 29, selected: dirty),
      PopupMenuButton<int>(
          tooltip: '设置缩进宽度',
          enabled: editorWritable,
          onSelected: (size) => editor.setIndentSize(size),
          itemBuilder: (_) => [
                for (final size in [2, 4, 8])
                  IdeMenuItem(
                      value: size,
                      child:
                          item(size, '$size 个空格', editor.options.indentSize)),
              ],
          child: label('${editor.options.indentSize} 个空格')),
      pythonEnvironmentControl(label),
      ib('hide', '隐藏工具窗口', toolWindowsVisible ? hideToolWindows : null,
          extent: 28),
    ]);
    return SizedBox(
        height: 30,
        child: LayoutBuilder(builder: (_, size) {
          if (size.maxWidth < (_usesWindowsChrome ? 960 : 600)) {
            return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: controls);
          }
          return Row(children: [
            const SizedBox(width: 12),
            ideIcon('module', size: 13),
            const SizedBox(width: 5),
            Text(project == null ? 'Python' : p.basename(project!),
                style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 7),
            ideIcon('chevronRight', size: 14),
            const SizedBox(width: 7),
            ideIcon('python'),
            const SizedBox(width: 6),
            Expanded(
                child: Text(
                    running ||
                            checkingRun ||
                            status.contains('检查') ||
                            status.contains('失败') ||
                            status.contains('停止')
                        ? status
                        : currentFile == null
                            ? ''
                            : p.basename(currentFile!),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: const TextStyle(fontSize: 13))),
            controls,
            const SizedBox(width: 9),
          ]);
        }));
  }

  Future<bool> save({bool saveAs = false, EditorDocument? document}) async {
    final previousPath = document?.path ?? currentFile;
    final original = document ?? documents[previousPath];
    final savingEditor = original?.controller ?? editor;
    while (_saveInFlight != null) {
      await _saveInFlight!;
    }
    if (!mounted || original != null && documents[previousPath] != original) {
      return false;
    }
    if (!saveAs && (original?.readOnly ?? false)) return true;
    if (!saveAs &&
        original != null &&
        !original.dirty &&
        File(original.path).existsSync()) {
      return true;
    }
    final completion = Completer<void>();
    _saveInFlight = completion.future;
    try {
      var path = saveAs ? null : previousPath;
      path ??= await FilePicker.platform.saveFile(
          dialogTitle: '保存 Python 文件',
          fileName:
              previousPath == null ? 'main.py' : p.basename(previousPath));
      if (path == null) return false;
      if (p.extension(path).toLowerCase() != '.py') path += '.py';
      final targetPath = File(path).absolute.path;
      if (targetPath != previousPath &&
          (documents[targetPath]?.dirty ?? false)) {
        reportError('目标文件已有未保存的修改，请先保存或关闭该标签页。');
        return false;
      }
      final text = savingEditor.text;
      final format = original?.format ?? defaultSourceFormat;
      final originalProject = project;
      await PythonSourceFile.write(File(targetPath), text, format, semantics);
      if (!mounted) return true;
      if (targetPath != previousPath) {
        final replacement = documents[targetPath];
        final saved = EditorDocument(targetPath, text,
            format: format, indentSize: savingEditor.options.indentSize);
        documents[targetPath] = saved;
        if (identical(editor, savingEditor) || currentFile == targetPath) {
          activateDocument(saved);
        } else if (replacement != null) {
          replacement.dispose();
        }
      } else if (original != null) {
        original.savedText = text;
        original.savedFormat = format;
      }
      if (identical(editor, savingEditor) || currentFile == targetPath) {
        setState(() {
          currentFile = targetPath;
          if (entry == null || entry == previousPath) entry = targetPath;
          if (project == null || !p.isWithin(project!, targetPath)) {
            project = p.dirname(targetPath);
          }
          status = '已保存 ${p.basename(targetPath)}';
        });
      }
      if (project != originalProject) {
        await refreshFiles();
      } else if (project != null &&
          p.isWithin(project!, targetPath) &&
          !p.split(p.relative(targetPath, from: project)).any(excludedProjectName) &&
          !files.any((file) => p.equals(file.absolute.path, targetPath))) {
        setState(() => files = [...files, File(targetPath)]
          ..sort((a, b) => a.path.compareTo(b.path)));
      }
      return true;
    } catch (e) {
      reportError('保存失败：$e');
      return false;
    } finally {
      _saveInFlight = null;
      completion.complete();
    }
  }

  Future<void> openPythonFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
          dialogTitle: '打开 Python 文件',
          // IDE UTType registrations can reject valid .py files on macOS.
          // Validate the extension after selection instead.
          type: Platform.isMacOS ? FileType.any : FileType.custom,
          allowedExtensions: Platform.isMacOS ? null : ['py']);
      if (result == null || result.files.single.path == null) return;
      final path = result.files.single.path!;
      if (p.extension(path).toLowerCase() != '.py') {
        reportError('请选择 Python 源码文件（.py）。');
        return;
      }
      await openFile(File(path));
      if (mounted && currentFile == File(path).absolute.path) {
        setState(() {
          welcome = false;
          rememberProject(project!);
        });
      }
    } catch (e) {
      reportError('打开失败：$e');
    }
  }

  Future<bool> leaveFile() async {
    if (!dirty) return true;
    final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('保存当前修改？'),
              content: const Text('切换文件前可以保存当前代码。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, 'cancel'),
                    child: const Text('取消')),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, 'discard'),
                    child: const Text('放弃修改')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, 'save'),
                    child: const Text('保存'))
              ],
            ));
    return action == 'discard' || (action == 'save' && await save());
  }

  Future<void> openFile(File file,
      {bool updateEntry = true, bool preserveProject = false}) async {
    if (!mounted) return;
    if (chatTabOpen) setState(() => chatTabSelected = false);
    final path = file.absolute.path;
    final token = ++fileLoadToken;
    final existing = documents[path];
    if (existing != null || currentFile == path) {
      if (fileBusy) setState(() => fileBusy = false);
      if (existing != null && currentFile != path) {
        activateDocument(existing, updateEntry: updateEntry);
      }
      return;
    }
    setState(() => fileBusy = true);
    try {
      final source = await PythonSourceFile.read(file, semantics);
      if (!mounted || token != fileLoadToken) return;
      final document = EditorDocument(path, source.text, format: source.format);
      documents[path] = document;
      if (!preserveProject && (project == null || !p.isWithin(project!, path))) {
        project = p.dirname(path);
      }
      activateDocument(document, updateEntry: updateEntry);
      await refreshFiles();
      if (!mounted || token != fileLoadToken) return;
      setState(() => status = '已打开 ${p.basename(path)}');
    } catch (error) {
      if (token == fileLoadToken) reportError('无法打开文件：$error');
    } finally {
      if (mounted && token == fileLoadToken) setState(() => fileBusy = false);
    }
  }

  bool excludedProjectName(String name) =>
      name.startsWith('.') ||
      const ['__pycache__', 'venv', 'node_modules'].contains(name);

  Future<void> refreshFiles() {
    final refresh = scanProjectFiles();
    fileRefreshTask = refresh;
    return refresh;
  }

  Future<void> scanProjectFiles() async {
    final root = project;
    if (root == null) return;
    final scan = ++projectScan;
    bool active() => mounted && scan == projectScan && project == root;
    final list = <File>[];
    final pending = [Directory(root)];
    try {
      while (pending.isNotEmpty && active()) {
        await for (final item in pending.removeLast().list(followLinks: false)) {
          if (!active()) return;
          final name = p.basename(item.path);
          if (excludedProjectName(name)) continue;
          if (item is Directory) pending.add(item);
          if (item is File && p.extension(name).toLowerCase() == '.py') {
            list.add(item);
          }
        }
      }
      list.sort((a, b) => a.path.compareTo(b.path));
      if (active()) setState(() => files = list);
    } on FileSystemException catch (error) {
      if (!active()) return;
      // A macOS file picker may grant the file without granting its parent.
      if (Platform.isMacOS && const [1, 13].contains(error.osError?.errorCode)) {
        setState(() => files = documents.keys
            .where((path) => p.isWithin(root, path))
            .map(File.new)
            .toList());
      } else {
        reportError('读取项目失败：$error');
      }
    } catch (error) {
      if (active()) reportError('读取项目失败：$error');
    }
  }

  Future<void> pickProject() async {
    if (!await confirmWorkspaceClose()) return;
    final folder =
        await FilePicker.platform.getDirectoryPath(dialogTitle: '打开学习项目');
    if (folder == null) return;
    await enterProject(folder);
  }

  Future<void> enterProject(String folder) async {
    if (!Directory(folder).existsSync()) {
      reportError('项目目录已不存在');
      return;
    }
    final oldDocuments = documents.values.toList();
    documents.clear();
    setState(() {
      welcome = false;
      rememberProject(folder);
      project = folder;
      entry = null;
      currentFile = null;
      files = [];
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final document in oldDocuments) {
        if (document.controller != editor) document.dispose();
      }
    });
    await refreshFiles();
    if (!mounted || project != folder || currentFile != null) return;
    if (files.isNotEmpty) {
      await openFile(files.firstWhere((f) => p.basename(f.path) == 'main.py',
          orElse: () => files.first));
    } else {
      _loading = true;
      editor.text = '';
      _loading = false;
    }
  }

  Future<void> run(bool visual) async {
    if (running || checkingRun) return;
    timer?.cancel();
    setState(() {
      checkingRun = true;
      playing = false;
      animationsPaused = true;
    });
    try {
      if (!await saveAllDocuments()) return;
      await fileRefreshTask;
      if (!mounted) return;
      if (entry == null || project == null) return;
      analysisTimer?.cancel();
      analysisGeneration++;
      setState(() {
        analyzing = false;
        status = '运行前检查中…';
      });
      final checkedEntry = entry!, checkedProject = project!;
      final checkedBuffer = editor.text;
      final snapshot = <String, String>{};
      final sourceErrors = <String, String>{};
      for (final path in {
        ...files.map((file) => file.absolute.path),
        checkedEntry
      }) {
        try {
          snapshot[path] =
              (await PythonSourceFile.read(File(path), semantics)).text;
        } catch (error) {
          sourceErrors[path] = '无法读取运行源码：$error';
        }
      }
      try {
        final result = await analysis.check(snapshot, checkedEntry, checkedProject,
            sourceErrors: sourceErrors);
        if (!mounted) return;
        if (entry != checkedEntry ||
            project != checkedProject ||
            editor.text != checkedBuffer) {
          setState(() => status = '代码或入口已改变，请重新运行以检查最新内容');
          return;
        }
        final found = (result['diagnostics'] as List)
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        setState(() {
          diagnostics = found;
          analysisFailure = null;
          checkedSource = editor.text;
        });
        final errors = found.where((d) => d['severity'] == 'error').toList();
        if (errors.isNotEmpty) {
          setState(() {
            openProblems();
            status = '运行前检查未通过 · ${errors.length} 个错误，尚未执行代码';
          });
          await locateDiagnostic(errors.first);
          if (mounted && entry == checkedEntry && project == checkedProject) {
            setState(() {
              allDiagnostics = found;
              diagnostics = found;
            });
          }
          return;
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            analysisFailure = '$e';
            status = '无法完成运行前检查：$e';
            openProblems();
          });
        }
        return;
      }
      timer?.cancel();
      runtime.stop();
      setState(() {
        events = [];
        sources = snapshot;
        runEntry = checkedEntry;
        error = null;
        console = '';
        cursor = 0;
        selectedFrame = -1;
        prompt = null;
        running = true;
        if (visual) {
          openFlowSession();
        } else {
          showExecution = true;
          inspectedTraceLine = null;
          if (!blueprintMode) showConsole = true;
        }
        playing = false;
        animationsPaused = false;
        demo = visual;
        pendingDemoStep = false;
        status = visual ? '演示运行 · 单步或播放以推进' : '正在记录真实执行过程…';
      });
      try {
        await runtime.start(entry!, project!, demo: visual);
      } catch (e) {
        setState(() {
          running = false;
          status = '启动失败';
          console = '$e';
          showConsole = true;
        });
      }
    } finally {
      if (mounted) setState(() => checkingRun = false);
    }
  }

  void stopRun() {
    runtime.stop();
    timer?.cancel();
    setState(() {
      running = false;
      playing = false;
      prompt = null;
      pendingDemoStep = false;
      status = '运行已停止 · 已记录步骤可回看';
    });
  }

  bool get canAdvanceDemo =>
      running &&
      demo &&
      !pendingDemoStep &&
      prompt == null &&
      events.isNotEmpty;

  void move(int direction) {
    if (!blueprintMode || !showExecution) return;
    final index = direction < 0
        ? recording.stopInsertionIndex(cursor - 1) - 1
        : recording.stopInsertionIndex(cursor);
    final target = index >= 0 && index < playbackStops.length
        ? playbackStops[index]
        : null;
    if (target != null) {
      seek(target, keepPlaying: playing);
    } else if (direction > 0 && canAdvanceDemo) {
      timer?.cancel();
      setState(() => pendingDemoStep = true);
      runtime.command('step');
    }
  }

  void seek(int sequence, {bool keepPlaying = false}) {
    timer?.cancel();
    setState(() {
      cursor = sequence;
      inspectedTraceLine = null;
      playing = keepPlaying;
      animationsPaused = false;
      selectedFrame = -1;
      syncCodePosition();
    });
    if (playing) schedulePlayback();
  }

  void togglePlay() {
    if (playing) {
      timer?.cancel();
      setState(() {
        playing = false;
        animationsPaused = true;
      });
      return;
    }
    final stops = playbackStops;
    if (!running && stops.isNotEmpty && cursor >= stops.last) {
      seek(stops.first, keepPlaying: stops.length > 1);
      return;
    }
    setState(() {
      playing = true;
      animationsPaused = false;
    });
    schedulePlayback();
  }

  void schedulePlayback() {
    timer?.cancel();
    timer = Timer(Duration(milliseconds: (1700 / speed).round()), () {
      if (!mounted || !playing) return;
      if (!running && (playbackStops.isEmpty || cursor >= playbackStops.last)) {
        setState(() => playing = false);
        return;
      }
      move(1);
    });
  }

  Future<void> exportTrace() async {
    try {
      final path = await FilePicker.platform
          .saveFile(dialogTitle: '保存执行记录', fileName: 'learning.trace.json');
      if (path == null) return;
      await File(path).writeAsString(jsonEncode({
        'version': 1,
        'sources': sources,
        'events': events,
        'error': error,
        'output': console
      }));
    } catch (e) {
      reportError('保存执行记录失败：$e');
    }
  }

  Future<void> importTrace() async {
    final pick = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['json']);
    if (pick == null) return;
    try {
      final archive =
          decodeTrace(await File(pick.files.single.path!).readAsString());
      runtime.stop();
      timer?.cancel();
      setState(() {
        recording = ExecutionRecording(
            (archive['events'] as List).cast<Map<String, dynamic>>());
        sources = Map<String, dynamic>.from(archive['sources'] ?? {});
        cursor = 0;
        error = archive['error'];
        final archivedOutput = archive['output'];
        console = archivedOutput is Map
            ? '${archivedOutput['stdout'] ?? ''}${archivedOutput['stderr'] ?? ''}'
            : '${archivedOutput ?? ''}';
        running = false;
        playing = false;
        status = '已打开历史执行记录';
        prompt = null;
        openFlowSession();
        selectedFrame = -1;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法打开记录：$e')));
      }
    }
  }

  Widget action(IconData icon, String label, VoidCallback? callback) =>
      TextButton.icon(
          onPressed: callback, icon: Icon(icon, size: 17), label: Text(label));

  Widget ib(String icon, String label, VoidCallback? callback,
          {double size = 16, double extent = 30, bool selected = false}) =>
      IdeButton(
          icon: icon,
          tooltip: label,
          onTap: callback,
          size: size,
          extent: extent,
          selected: selected);

  Widget rail(bool left) => SizedBox(
      width: 40,
      child: Column(children: [
        const SizedBox(height: 3),
        if (left) ...[
          ib('project', '项目', () => setState(() => showProject = !showProject),
              size: 20, extent: 32, selected: showProject),
          const SizedBox(height: 16),
        ],
        ib(left ? 'structure' : 'packages', left ? '结构' : '学习提问',
            left ? null : toggleLearningAi,
            size: 20, extent: 32, selected: !left && showLearningAi),
        const SizedBox(height: 10),
        ib('more', '更多工具窗口', null, size: 20, extent: 32),
        const Spacer(),
        if (left) ...[
          ib('terminal', '控制台', toggleConsole,
              size: 20, extent: 32, selected: showConsole),
          const SizedBox(height: 8),
          ib('problems', '问题', () => setState(openProblems),
              size: 20, extent: 32, selected: !blueprintMode && showProblems),
        ],
        const SizedBox(height: 10),
      ]));

  void returnToWelcome() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      welcome = true;
      chatTabSelected = false;
      if (!chatInEditor) showLearningAi = false;
      if (widget.aiEnabled) learningContext ??= {};
    });
  }

  Future<void> openRecentProject(String folder) async {
    if (folder == project) {
      if (welcome) setState(() => welcome = false);
      return;
    }
    if (await confirmWorkspaceClose() && mounted) await enterProject(folder);
  }

  Widget projectMenu() => PopupMenuButton<VoidCallback>(
      tooltip: '项目菜单',
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 380),
      onSelected: (action) => action(),
      itemBuilder: (_) => [
            IdeMenuItem(
                value: createProject,
                child: const IdeMenuLabel('新建项目…', icon: 'add')),
            const PopupMenuDivider(),
            IdeMenuItem<VoidCallback>(
                enabled: false,
                child: Text(recentProjects.isEmpty ? '暂无最近项目' : '最近项目')),
            for (final folder in recentProjects)
              IdeMenuItem<VoidCallback>(
                  value: () => openRecentProject(folder),
                  height: 50,
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        IdeMenuLabel(p.basename(folder),
                            icon: folder == project ? 'module' : 'folder'),
                        Padding(
                            padding: const EdgeInsets.only(left: 24, top: 3),
                            child: Text(folder,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 11, color: muted))),
                      ])),
          ],
      child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
                child: Text(project == null ? 'Python' : p.basename(project!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14))),
            const SizedBox(width: 6),
            ideIcon('chevronDown', size: 12),
          ])));

  Widget mainToolbar(bool narrow) => SizedBox(
      width: double.infinity,
      height: 42,
      child: Row(children: [
        SizedBox(width: macKeys ? 92 : 12),
        Expanded(child: toolbarWorkspace(!narrow)),
        toolbarActions(narrow),
      ]));

  Widget toolbarWorkspace(bool showModes, {bool inTitleBar = false}) => Row(
        mainAxisSize: inTitleBar ? MainAxisSize.min : MainAxisSize.max,
        children: [
          IconButton(
              tooltip: '返回欢迎页',
              onPressed: returnToWelcome,
              style: inTitleBar
                  ? IconButton.styleFrom(
                      minimumSize: const Size(32, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: EdgeInsets.zero,
                    )
                  : null,
              icon: const Icon(Icons.home_outlined, size: 21)),
          Flexible(child: projectMenu()),
          if (showModes) ...[
            SizedBox(width: inTitleBar ? 8 : 18),
            workspaceSelection(),
          ],
        ],
      );

  Future<void> selectRunEntry(String path) async {
    await openFile(File(path));
    if (mounted && currentFile == path) setState(() => entry = path);
  }

  List<Widget> runToolbarButtons() => [
        ib('run', '直接运行', running || checkingRun ? null : () => run(false),
            extent: 34, size: 20),
        ib('debug', '演示运行', running || checkingRun ? null : () => run(true),
            extent: 34, size: 20),
        if (running) ib('stop', '停止运行', stopRun, extent: 34),
      ];

  Widget toolbarActions(bool narrow, {bool inTitleBar = false}) {
    Widget menuButton(Widget button) =>
        inTitleBar ? SizedBox(width: 32, child: button) : button;

    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (!narrow)
        ConstrainedBox(
            constraints: BoxConstraints(maxWidth: inTitleBar ? 100 : 160),
            child: Text(
                entry == currentFile ? '当前文件' : p.basename(entry ?? '当前文件'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14))),
      menuButton(PopupMenuButton<String>(
          tooltip: '打开文件并设为运行入口',
          padding: EdgeInsets.zero,
          icon: ideIcon('chevronDown'),
          onSelected: selectRunEntry,
          itemBuilder: (_) => [
                for (final file in files)
                  IdeMenuItem(
                      value: file.path,
                      child: Text(p.relative(file.path, from: project))),
              ])),
      ...runToolbarButtons(),
      menuButton(PopupMenuButton<String>(
          tooltip: '更多操作',
          padding: EdgeInsets.zero,
          icon: ideIcon('more', size: 20),
          onSelected: (v) {
            if (v == 'welcome') returnToWelcome();
            if (v == 'save') save();
            if (v == 'saveAs') save(saveAs: true);
            if (v == 'new') createFile();
            if (v == 'open') openPythonFile();
            if (v == 'project') pickProject();
            if (v == 'export') exportTrace();
            if (v == 'import') importTrace();
            if (v == 'check') checkCode();
            if (v == 'settings') openEditorSettings();
            if (v == 'about') openAbout();
          },
          itemBuilder: (_) => [
                const IdeMenuItem(
                    value: 'welcome',
                    child: IdeMenuLabel('欢迎页', icon: 'module')),
                const IdeMenuItem(
                    value: 'new',
                    child: IdeMenuLabel('新建 Python 文件', icon: 'python')),
                const IdeMenuItem(
                    value: 'open',
                    child: IdeMenuLabel('打开 Python 文件…', icon: 'open')),
                const IdeMenuItem(
                    value: 'project',
                    child: IdeMenuLabel('打开项目…', icon: 'folder')),
                const PopupMenuDivider(height: 9),
                IdeMenuItem(
                    value: 'save',
                    child: IdeMenuLabel('保存',
                        icon: 'save', shortcut: macKeys ? '⌘S' : 'Ctrl+S')),
                const IdeMenuItem(value: 'saveAs', child: IdeMenuLabel('另存为…')),
                const PopupMenuDivider(height: 9),
                const IdeMenuItem(
                    value: 'check',
                    child: IdeMenuLabel('检查代码', icon: 'problems')),
                const IdeMenuItem(
                    value: 'export', child: IdeMenuLabel('保存执行记录')),
                const IdeMenuItem(
                    value: 'import', child: IdeMenuLabel('打开执行记录')),
                const PopupMenuDivider(height: 9),
                IdeMenuItem(
                    value: 'settings',
                    child: IdeMenuLabel('设置…',
                        icon: 'settings',
                        shortcut: macKeys ? '⌘,' : 'Ctrl+Alt+S')),
                const IdeMenuItem(
                    value: 'about', child: IdeMenuLabel('关于 Pyvis'))
              ])),
      if (!narrow) ...[
        SizedBox(width: inTitleBar ? 4 : 18),
        ib('open', '打开项目', pickProject, size: 20, extent: inTitleBar ? 32 : 40),
        ib('search', '查找', showSearch, size: 20, extent: inTitleBar ? 32 : 40),
        settingsMenu(),
        SizedBox(width: inTitleBar ? 4 : 10),
      ] else ...[
        ib('terminal', '控制台', toggleConsole,
            extent: 28, size: 18, selected: showConsole),
        ib('open', '打开项目', pickProject, extent: 28, size: 20),
      ],
    ]);
  }

  bool aboutOpen = false;
  Future<void> openAbout() async {
    if (aboutOpen) return;
    aboutOpen = true;
    try {
      await showDialog<void>(
          context: context,
          builder: (_) => PyvisAboutDialog(python: pythonDetails));
    } finally {
      aboutOpen = false;
    }
  }

  List<Widget> editorSettingsMenuItems() => [
        MenuItemButton(
            leadingIcon: const SizedBox(width: 16),
            onPressed: openLearningAi,
            child: const Text('学习提问…')),
        MenuItemButton(
            leadingIcon: const SizedBox(width: 16),
            onPressed: () => openEditorSettings(initialPage: 4),
            child: const Text('模型 API 配置…')),
        MenuItemButton(
            leadingIcon: const SizedBox(width: 16),
            onPressed: openEditorSettings,
            trailingIcon: Text(macKeys ? '⌘,' : 'Ctrl+Alt+S',
                style: const TextStyle(fontSize: 11, color: muted)),
            child: const Text('设置…')),
        const Divider(),
        SubmenuButton(
            leadingIcon: const SizedBox(width: 16),
            menuChildren: [
              MenuItemButton(
                  leadingIcon: const SizedBox(width: 16),
                  onPressed: () => openEditorSettings(initialPage: 0),
                  child: const Text('字体…')),
              SubmenuButton(
                  leadingIcon: const SizedBox(width: 16),
                  menuChildren: [
                    MenuItemButton(
                        leadingIcon: const SizedBox(width: 16),
                        onPressed: () => openEditorSettings(initialPage: 1),
                        child: const Text('软换行与代码缩略图…')),
                    MenuItemButton(
                        leadingIcon: const SizedBox(width: 16),
                        onPressed: () => openEditorSettings(initialPage: 2),
                        child: const Text('代码检查…')),
                  ],
                  child: const Text('常规')),
              MenuItemButton(
                  leadingIcon: const SizedBox(width: 16),
                  onPressed: () => openEditorSettings(initialPage: 3),
                  child: Text(Platform.isAndroid ? '触控操作…' : '键位…')),
            ],
            child: const Text('编辑器')),
        SubmenuButton(
            leadingIcon: const SizedBox(width: 16),
            menuChildren: [
              MenuItemButton(
                  onPressed: () => setState(() => showProject = !showProject),
                  leadingIcon: Icon(showProject ? Icons.check : null, size: 14),
                  child: const Text('项目')),
              MenuItemButton(
                  onPressed: toggleConsole,
                  leadingIcon: Icon(showConsole ? Icons.check : null, size: 14),
                  child: const Text('控制台')),
              MenuItemButton(
                  leadingIcon: const SizedBox(width: 16),
                  onPressed: () => setState(openProblems),
                  child: const Text('问题')),
            ],
            child: const Text('工具窗口')),
      ];

  Widget settingsMenu() => MenuAnchor(
        menuChildren: editorSettingsMenuItems(),
        builder: (context, controller, child) => ib('settings', '设置',
            () => controller.isOpen ? controller.close() : controller.open(),
            size: 20, extent: 40),
      );

  Future<void> createProject() async {
    var projectName = '';
    final form = GlobalKey<FormState>();
    final name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('新建项目'),
                content: Form(
                    key: form,
                    child: TextFormField(
                        onChanged: (value) => projectName = value,
                        autofocus: true,
                        decoration: const InputDecoration(labelText: '项目名称'),
                        validator: (value) {
                          final name = value?.trim() ?? '';
                          if (name.isEmpty) return '请输入项目名称';
                          if (name == '.' ||
                              name == '..' ||
                              RegExp(r'[<>:"/\\|?*]').hasMatch(name) ||
                              name.endsWith('.')) {
                            return '请输入有效的文件夹名称';
                          }
                          return null;
                        })),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () {
                        if (form.currentState!.validate()) {
                          Navigator.pop(context, projectName.trim());
                        }
                      },
                      child: const Text('选择保存位置')),
                ]));
    if (name == null || !mounted) return;
    final parent =
        await FilePicker.platform.getDirectoryPath(dialogTitle: '选择项目的保存位置');
    if (parent == null || !mounted || !await confirmWorkspaceClose()) return;
    final folder = Directory(p.join(parent, name));
    try {
      if (await FileSystemEntity.type(folder.path) !=
          FileSystemEntityType.notFound) {
        reportError('此位置已存在同名文件或文件夹，请使用其他项目名称');
        return;
      }
      await folder.create();
      await File(p.join(folder.path, 'main.py')).writeAsString('');
      if (mounted) await enterProject(folder.path);
    } catch (error) {
      reportError('新建项目失败：$error');
    }
  }

  Future<void> welcomeScript() async {
    try {
      await RuntimeAdapter.prepareBundledRuntime();
      if (!mounted) return;
      await createFile(folder: p.join(RuntimeAdapter.root, 'projects', '默认项目'));
    } catch (error) {
      reportError('新建脚本失败：$error');
    }
  }

  Future<void> welcomeExample() async {
    await loadBundledExample();
    if (mounted && p.basename(currentFile ?? '') == '逐行运算.py') {
      setState(() {
        welcome = false;
        if (project case final folder?) rememberProject(folder);
      });
    }
  }

  Widget welcomeBody(double width) {
    if (Platform.isAndroid) {
      return WelcomeLaunch(
          createProject: createProject,
          create: welcomeScript,
          open: openPythonFile,
          example: welcomeExample,
          about: openAbout,
          settings: openEditorSettings,
          learn: () => openLearningAi(),
          keymap: () => openEditorSettings(initialPage: 3));
    }
    final wide = width >= 1020;
    final sideChat = showLearningAi && !chatInEditor;
    Widget island(Widget child) =>
        ClipRRect(borderRadius: BorderRadius.circular(11), child: child);
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
          width: 40,
          child: Column(children: [
            ib(
                'project',
                '项目',
                width < 700
                    ? pickProject
                    : () => setState(() => showProject = !showProject),
                size: 20,
                selected: showProject),
          ])),
      if (showProject && (wide || width >= 700 && !sideChat)) ...[
        SizedBox(
            width: width * (wide ? 0.315 : 0.30),
            child: island(WelcomeProjects(
                projects: recentProjects,
                pick: pickProject,
                create: welcomeScript,
                open: openRecentProject))),
        const SizedBox(width: 5)
      ],
      if (wide || !sideChat || chatTabOpen)
        Expanded(
            child: island(editorWithChatTab(WelcomeLaunch(
                createProject: createProject,
                create: welcomeScript,
                open: openPythonFile,
                example: welcomeExample,
                about: openAbout,
                settings: openEditorSettings,
                learn: () => openLearningAi(),
                keymap: () => openEditorSettings(initialPage: 3))))),
      if (chatTabOpen && chatTabSelected && wide) chatSessionList(width * .25),
      if (widget.aiEnabled && !chatInEditor)
        Offstage(
            offstage: !showLearningAi,
            child: SizedBox(
                width: wide ? width * .25 : width - 80,
                child: island(LearningAiPanel(
                    key: learningPanelKey,
                    onModelChanged: () => setState(() {}),
                    onTogglePlacement: toggleChatPlacement,
                    available: learningContext ?? const {},
                    messages: learningMessages,
                    store: aiConfigStore,
                    references: learningReferences,
                    onClose: hideLearningAi)))),
      SizedBox(
          width: 40,
          child: Column(children: [
            ib('packages', '学习提问', toggleLearningAi,
                size: 20, selected: showLearningAi)
          ]))
    ]);
  }

  void showSearch() => finder.findMode();

  Widget windowsTitleBar() {
    Widget item(String label, VoidCallback? action, {String? shortcut}) =>
        MenuItemButton(
          onPressed: action,
          child: IdeMenuLabel(label, shortcut: shortcut),
        );
    final canEdit = !welcome && editorWritable && !editor.isComposing;
    final canRun = !welcome && !running && !checkingRun && entry != null;
    void changeHistory(VoidCallback action) {
      editorContextMenu.hide(context);
      completionPopup.dismiss();
      decorations.dismissInline();
      action();
    }

    return WindowsTitleBar(
      workspaceTitle: welcome ? 'Pyvis · 欢迎页' : 'Pyvis',
      workspace: welcome
          ? null
          : (showModes) => toolbarWorkspace(showModes, inTitleBar: true),
      actions: welcome
          ? null
          : (width) => switch (width) {
                >= 640 => toolbarActions(width < 900, inTitleBar: true),
                >= 400 => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: runToolbarButtons(),
                  ),
                _ => const SizedBox.shrink(),
              },
      menus: {
        '文件': [
          item('新建项目…', createProject),
          item('新建 Python 文件…', welcome ? welcomeScript : createFile),
          item('打开项目…', pickProject),
          item('打开 Python 文件…', openPythonFile, shortcut: 'Ctrl+O'),
          const Divider(),
          item('全部保存', welcome ? null : saveAllDocuments, shortcut: 'Ctrl+S'),
          item(
            '另存为…',
            welcome ? null : () => save(saveAs: true),
            shortcut: 'Ctrl+Shift+S',
          ),
        ],
        '编辑': [
          item(
            '撤回',
            canEdit && editor.canUndo ? () => changeHistory(editor.undo) : null,
          ),
          item(
            '恢复',
            canEdit && editor.canRedo ? () => changeHistory(editor.redo) : null,
          ),
          const Divider(),
          item('查找', welcome ? null : showSearch, shortcut: 'Ctrl+F'),
          item('替换', welcome ? null : finder.replaceMode, shortcut: 'Ctrl+R'),
        ],
        '视图': [
          item('返回欢迎页', welcome ? null : returnToWelcome),
          item(
            '编辑代码',
            welcome ? null : () => setState(() => switchWorkspace(false)),
          ),
          item(
            '代码流程图',
            welcome ? null : () => setState(() => switchWorkspace(true)),
          ),
          const Divider(),
          item(
            '项目面板',
            welcome ? null : () => setState(() => showProject = !showProject),
          ),
          item('控制台', welcome ? null : toggleConsole),
        ],
        '运行': [
          item(
            '直接运行',
            canRun ? () => run(false) : null,
            shortcut: 'Shift+F10',
          ),
          item('演示运行', canRun ? () => run(true) : null, shortcut: 'Shift+F9'),
          item('停止运行', running ? stopRun : null),
          if (!welcome && files.isNotEmpty)
            SubmenuButton(
              menuChildren: [
                for (final file in files)
                  item(p.relative(file.path, from: project),
                      () => selectRunEntry(file.path)),
              ],
              child: const Text('打开文件并设为运行入口'),
            ),
          item('检查代码', welcome ? null : checkCode, shortcut: 'Ctrl+F7'),
          const Divider(),
          item('打开执行记录', running || checkingRun ? null : importTrace),
          item(
            '保存执行记录',
            events.isNotEmpty || console.isNotEmpty ? exportTrace : null,
          ),
        ],
        '帮助': [
          item('设置…', openEditorSettings),
          SubmenuButton(
            menuChildren: editorSettingsMenuItems(),
            child: const Text('编辑器与工具设置'),
          ),
          item('键盘映射…', () => openEditorSettings(initialPage: 3)),
          item('关于 Pyvis', openAbout),
        ],
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    syncNativeRunMenu();
    final narrow = MediaQuery.sizeOf(context).width < 900;
    return CallbackShortcuts(
        bindings: {
          SingleActivator(LogicalKeyboardKey.keyF,
              meta: macKeys, control: !macKeys): finder.findMode,
          SingleActivator(LogicalKeyboardKey.keyR,
              meta: macKeys, control: !macKeys): finder.replaceMode,
          SingleActivator(LogicalKeyboardKey.keyS,
              meta: macKeys, control: !macKeys): () => saveAllDocuments(),
          SingleActivator(LogicalKeyboardKey.keyS,
              meta: macKeys,
              control: !macKeys,
              shift: true): () => save(saveAs: true),
          SingleActivator(LogicalKeyboardKey.keyO,
              meta: macKeys, control: !macKeys): openPythonFile,
          SingleActivator(LogicalKeyboardKey.keyN,
              meta: macKeys, control: !macKeys): createFile,
          SingleActivator(LogicalKeyboardKey.f7,
              meta: macKeys, control: !macKeys): checkCode,
          const SingleActivator(LogicalKeyboardKey.f10, shift: true): () =>
              run(false),
          const SingleActivator(LogicalKeyboardKey.f9, shift: true): () =>
              run(true),
          const SingleActivator(LogicalKeyboardKey.space, control: true):
              completionPopup.request,
          ...keymap
              .bindings(editorCommands)
              .map((key, action) => MapEntry(key, () {
                    if (editorFocus.hasFocus) action();
                  })),
          const SingleActivator(LogicalKeyboardKey.f8): () => move(1),
          const SingleActivator(LogicalKeyboardKey.f2, meta: true): stopRun,
        },
        child: Scaffold(
            backgroundColor: panel,
            body: Column(children: [
              if (_usesWindowsChrome) windowsTitleBar(),
              if (!welcome && !_usesWindowsChrome)
                mainToolbar(narrow)
              else if (welcome && !_usesWindowsChrome)
                SizedBox(
                    height: 42,
                    child: Row(children: [
                      SizedBox(width: macKeys ? 92 : 14),
                      Image.asset('assets/ide/pyvis.png',
                          width: 22, height: 22),
                      const SizedBox(width: 8),
                      const Text('欢迎页'),
                      const Spacer(),
                      ib('settings', '设置', openEditorSettings),
                      const SizedBox(width: 10)
                    ])),
              if (welcome)
                Expanded(child: welcomeBody(MediaQuery.sizeOf(context).width))
              else
                Expanded(
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                      Expanded(
                          child: narrow
                              ? Column(children: [
                                  if (!_usesWindowsChrome) workspaceSelection(),
                                  Expanded(child: workspace()),
                                ])
                              : Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                      rail(true),
                                      if (showProject) ...[
                                        SizedBox(
                                            width: projectWidth.clamp(
                                                200,
                                                MediaQuery.sizeOf(context)
                                                        .width *
                                                    .48),
                                            child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                child: projectPane())),
                                        MouseRegion(
                                            cursor: SystemMouseCursors
                                                .resizeLeftRight,
                                            child: GestureDetector(
                                                behavior:
                                                    HitTestBehavior.opaque,
                                                onHorizontalDragUpdate: (d) =>
                                                    setState(() =>
                                                        projectWidth =
                                                            (projectWidth +
                                                                    d.delta.dx)
                                                                .clamp(
                                                                    200, 650)),
                                                child:
                                                    const SizedBox(width: 5))),
                                      ],
                                      Expanded(
                                          child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              child: workspace())),
                                    ])),
                      if (widget.aiEnabled &&
                          learningContext != null &&
                          !(chatInEditor && showLearningAi))
                        learningPanel(),
                      if (chatTabOpen && chatTabSelected && !narrow)
                        chatSessionList(MediaQuery.sizeOf(context).width * .25),
                      if (!narrow) rail(false),
                    ])),
              if (welcome && !Platform.isAndroid)
                const SizedBox(
                    height: 26,
                    child: Row(children: [
                      SizedBox(width: 14),
                      Text('欢迎使用 Pyvis', style: TextStyle(color: muted))
                    ]))
              else if (!welcome)
                statusBar(),
            ])));
  }

  Widget workspaceSelection() => IdeModeTabs<bool>(
      items: const {false: '编辑代码', true: '代码流程图'},
      selected: blueprintMode,
      onSelected: (value) => setState(() => switchWorkspace(value)));

  void switchWorkspace(bool blueprint) {
    if (blueprint == blueprintMode) return;
    if (blueprint) {
      projectBeforeBlueprint = showProject;
      showProject = false;
    } else {
      showProject = projectBeforeBlueprint;
    }
    blueprintMode = blueprint;
  }

  void openFlowSession() {
    switchWorkspace(true);
    showExecution = true;
    inspectedTraceLine = null;
  }

  void openProblems() {
    switchWorkspace(false);
    showProblems = true;
  }

  void toggleConsole() => setState(() => showConsole = !showConsole);

  String get chatTitle =>
      learningMessages.where((m) => m.user).firstOrNull?.text ?? '新建聊天';

  Widget chatSessionList(double width) {
    final state = learningPanelKey.currentState;
    void activate(int? index, {bool switchSession = true}) {
      if (switchSession) state?.switchChat(index);
      setState(() => chatTabSelected = true);
    }

    return Container(
        width: width,
        margin: const EdgeInsets.only(left: 5),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(11)),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 6),
              child: Row(children: [
                const Expanded(
                    child: Text('AI 聊天',
                        style: TextStyle(fontWeight: FontWeight.w600))),
                IconButton(
                    tooltip: '新建会话',
                    onPressed:
                        state?.busy == true ? null : () => activate(null),
                    icon: const Icon(Icons.add, size: 17))
              ])),
          Expanded(
              child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  children: [
                for (final (index, title) in [
                  chatTitle,
                  ...?state?.chats.map((chat) => chat.title)
                ].indexed)
                  Material(
                      color:
                          index == 0 ? PyvisColors.hover : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                      child: InkWell(
                          onTap: index > 0 && state?.busy == true
                              ? null
                              : () =>
                                  activate(index - 1, switchSession: index > 0),
                          child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 7),
                              child: Row(children: [
                                const Icon(Icons.forum_outlined, size: 15),
                                const SizedBox(width: 7),
                                Expanded(
                                    child: Text(title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis))
                              ]))))
              ]))
        ]));
  }

  Widget editorWithChatTab(Widget original) {
    // Keep the editor subtree in a stable position so opening the chat tab
    // does not rebuild the code editor with the same controller.
    return Column(children: [
      Container(
          height: welcome || chatTabOpen ? 40 : 0,
          padding: welcome || chatTabOpen
              ? EdgeInsets.symmetric(horizontal: welcome ? 6 : 0)
              : EdgeInsets.zero,
          decoration: !welcome && !chatTabOpen
              ? null
              : BoxDecoration(
                  color: welcome ? bg : editorBg,
                  border: Border(
                      bottom: BorderSide(
                          color: welcome
                              ? PyvisColors.border
                              : const Color(0xff393b40)))),
          child: !welcome && !chatTabOpen
              ? null
              : welcome
                  ? Row(children: [
                      welcomeTabChip(),
                      if (chatTabOpen) chatTabChip(),
                    ])
                  : Row(children: [
                      Expanded(
                          child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(children: [
                                ...editorTabItems(),
                                chatTabChip(),
                              ]))),
                      editorTabsMenu(),
                    ])),
      Expanded(
          child: Stack(fit: StackFit.expand, children: [
        Offstage(offstage: chatTabOpen && chatTabSelected, child: original),
        if (chatTabOpen)
          Offstage(offstage: !chatTabSelected, child: learningPanel())
      ]))
    ]);
  }

  Widget workspace() =>
      editorWithChatTab(workspaceContent(showEditorTabs: !chatTabOpen));
  Widget workspaceContent({bool showEditorTabs = true}) => LayoutBuilder(
      builder: (_, size) =>
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
                child: blueprintMode
                    ? blueprintWorkspace()
                    : editorWorkspace(showTabs: showEditorTabs)),
            if (showConsole)
              SizedBox(
                  key: const ValueKey('independent-console'),
                  height: (size.maxHeight * .30).clamp(145.0, 235.0),
                  child: consolePane())
          ]));

  Map<String, dynamic>? get selectedStep => recording.stepAt(cursor);

  String? get replayFile =>
      ((selectedStep ?? event)?['file'] as String?) ??
      (running ? runEntry : null);

  Widget blueprintPanel({required bool showFilename}) {
    final active = showExecution ? selectedStep ?? event : null;
    final path = showExecution ? replayFile : null;
    final recorded = path == null ? null : sources[path] as String?;
    final filename = (recorded != null ? path : currentFile) ?? '未命名.py';
    final source = recorded ?? editor.text;
    final trace =
        recorded != null || path != null && path == currentFile && !dirty
            ? ReadingTrace.forEvent(active, events)
            : null;
    void selectLine(int line) {
      if (recorded != null) {
        setState(() => inspectedTraceLine = line);
      } else if (filename == (currentFile ?? '未命名.py') &&
          source == editor.text &&
          line > 0 &&
          line <= editor.text.split('\n').length) {
        editor.selection = CodeLineSelection.collapsed(
            index: revealSourceLine(editor, line - 1), offset: 0);
        editor.makePositionVisible(editor.selection.extent);
        setState(() => graphSelectedLine = line);
      }
    }

    ComfyBlueprintPanel overview([ValueChanged<int?>? openNodes]) =>
        ComfyBlueprintPanel(
            openNodes: openNodes,
            canvasBuilder: widget.graphCanvasBuilder,
            source: source,
            filename: filename,
            showFilename: showFilename,
            onReplay: !showExecution && events.isNotEmpty
                ? () => setState(openFlowSession)
                : null,
            trace: trace,
            activeLine: trace?.line ??
                graphSelectedLine ??
                editor.index2lineIndex(editor.selection.extentIndex) + 1,
            layoutPositions: graphLayouts.putIfAbsent(filename, () => {}),
            onLineSelected: selectLine);
    if (!Platform.isAndroid) return overview();
    final compilation = nodeCompilations.remove(filename) ?? NodeCompilation();
    nodeCompilations[filename] = compilation;
    if (nodeCompilations.length > 4) {
      final oldest = nodeCompilations.keys.first;
      nodeCompilations.remove(oldest)!.dispose();
    }
    return ListenableBuilder(
        listenable: compilation,
        builder: (_, child) => compilation.viewing
            ? AndroidNodeGraph(
                key: ValueKey(filename),
                compilation: compilation,
                source: documents[filename]?.controller.text ?? source,
                filename: filename,
                onLine: selectLine,
                positions: graphLayouts.putIfAbsent(filename, () => {}),
                canvasBuilder: widget.graphCanvasBuilder)
            : overview(compilation.open));
  }

  Widget flowInspector() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
            height: 38,
            child: Row(children: [
              const SizedBox(width: 14),
              const Text('变量变化',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (!running && !checkingRun)
                TextButton(
                    onPressed: () => setState(() => showExecution = false),
                    child:
                        const Text('查看代码结构', style: TextStyle(fontSize: 12))),
              IconButton(
                  tooltip: '关闭变量变化',
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => setState(() => showVariableChanges = false)),
            ])),
        Expanded(child: stage()),
      ]);

  Widget blueprintWorkspace() => Column(children: [
        Expanded(child: LayoutBuilder(builder: (context, size) {
          final showInspector = showExecution && showVariableChanges;
          final showSource = size.maxWidth >= (showInspector ? 930 : 650);
          final horizontal = size.maxWidth >= 670;
          final path = replayFile;
          final recorded = showExecution ? sources[path] as String? : null;
          final recordedLine = (selectedStep ?? event)?['line'] as int?;
          final graph = Flex(
              direction: horizontal ? Axis.horizontal : Axis.vertical,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                    flex: 60, child: blueprintPanel(showFilename: !showSource)),
                if (showInspector) ...[
                  const SizedBox(
                      height: 1,
                      width: 1,
                      child: ColoredBox(color: PyvisColors.border)),
                  Expanded(flex: 40, child: flowInspector()),
                ]
              ]);
          Widget flowPane(Widget child) => macKeys
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: ColoredBox(color: editorBg, child: child))
              : child;
          return Padding(
            padding:
                macKeys ? const EdgeInsets.only(bottom: 4) : EdgeInsets.zero,
            child:
                Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (showSource) ...[
                SizedBox(
                    width: (size.maxWidth * .29).clamp(245, 400),
                    child: flowPane(recorded == null
                        ? codePane(inFlow: true)
                        : _RecordedSource(
                            key: ValueKey(path),
                            file: path!.split(RegExp(r'[/\\]')).last,
                            source: recorded,
                            line: recordedLine,
                            inspectedLine: inspectedTraceLine))),
                if (macKeys)
                  const SizedBox(width: 5)
                else
                  const VerticalDivider(width: 1, color: PyvisColors.border),
              ],
              Expanded(
                  key: const ValueKey('flow-workspace-graph'),
                  child: flowPane(graph)),
            ]),
          );
        })),
        if (showExecution && !showVariableChanges)
          Align(
              alignment: Alignment.centerRight,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (!running && !checkingRun)
                  TextButton(
                      onPressed: () => setState(() => showExecution = false),
                      child: const Text('查看代码结构')),
                TextButton.icon(
                    onPressed: () => setState(() => showVariableChanges = true),
                    icon: const Icon(Icons.view_sidebar_outlined, size: 16),
                    label: const Text('显示变量变化')),
              ])),
        if (showExecution)
          TextButton.icon(
              onPressed: openLearningAi,
              icon: const Icon(Icons.chat_bubble_outline, size: 16),
              label: const Text('询问当前步骤')),
        if (showExecution) playback(),
      ]);

  Widget editorWorkspace({bool showTabs = true}) => Column(children: [
        Expanded(child: codePane(showTabs: showTabs)),
        if (showProblems) ...[
          SizedBox(
              height: 32,
              child: Row(children: [
                const SizedBox(width: 14),
                Text('问题（${diagnostics.length}）',
                    style: const TextStyle(fontSize: 12)),
                const Spacer(),
                TextButton(
                    onPressed: !widget.aiEnabled
                        ? showAiNotice
                        : diagnostics.isEmpty
                            ? null
                            : () => openLearningAi(
                                diagnostic:
                                    diagnostics.contains(learningDiagnostic)
                                        ? learningDiagnostic
                                        : diagnostics.first),
                    child: Text(diagnostics.contains(learningDiagnostic)
                        ? '询问 AI（选中问题）'
                        : '询问 AI（首个问题）')),
                ib('hide', '隐藏问题', () => setState(() => showProblems = false)),
              ])),
          Expanded(child: problemsPane()),
        ],
      ]);

  Widget stage() {
    final completed = selectedStep;
    if (stageSequence != completed?['seq']) {
      stageSequence = completed?['seq'] as int?;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && stageScroll.hasClients) stageScroll.jumpTo(0);
      });
    }
    return Material(
        color: bg,
        child: SingleChildScrollView(
            controller: stageScroll,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (completed != null)
                    LineTheater(
                        event: completed,
                        events: events,
                        speed: speed,
                        externalPaused: animationsPaused,
                        onInteraction: () {
                          timer?.cancel();
                          setState(() {
                            playing = false;
                            animationsPaused = false;
                          });
                        },
                        sources: sources,
                        finished: !running)
                  else
                    Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                            running && event != null
                                ? '点击「下一步」查看变量变化。'
                                : running
                                    ? '正在启动 Python…'
                                    : '运行后可查看每一步的变量变化。',
                            style:
                                const TextStyle(color: muted, fontSize: 13))),
                  if (error != null &&
                      (completed == null ||
                          completed['outcome'] == 'exception' &&
                              completed['line'] == error!['line'] &&
                              completed['file'] == error!['file']))
                    Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                            '${error!['type']} · 第 ${error!['line']} 行\n${error!['message']}\n${explain(error!['type'])}',
                            style: const TextStyle(
                                color: Color(0xffe9a2a2), fontSize: 13))),
                  if (error != null)
                    TextButton(
                        onPressed: () => openLearningAi(
                            diagnostic: Map<String, dynamic>.from(error!)),
                        child: const Text('询问当前错误')),
                  if (completed != null && frame.isNotEmpty)
                    ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title:
                            const Text('全部变量', style: TextStyle(fontSize: 13)),
                        children: [SizedBox(height: 340, child: statePane())]),
                ])));
  }

  Widget projectPane() => Material(
      color: bg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
            height: 40,
            child: Row(children: [
              const SizedBox(width: 12),
              const Text('项目',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ib('chevronDown', '项目视图', null, extent: 22),
              const Spacer(),
              ib('add', '新建 Python 文件', createFile),
              ib('locate', '定位当前文件', () => syncCodePosition()),
              ib('expandAll', '展开全部',
                  () => setState(() => collapsedDirs.clear())),
              ib('collapseAll', '折叠全部',
                  () => setState(() => collapsedDirs.add('多文件'))),
              ib('more', '设置运行入口', () => setState(() => entry = currentFile)),
              ib('hide', '隐藏项目', () => setState(() => showProject = false)),
              const SizedBox(width: 6)
            ])),
        SizedBox(
            height: 28,
            child: Row(children: [
              const SizedBox(width: 12),
              ideIcon('chevronDown'),
              const SizedBox(width: 4),
              ideIcon('module'),
              const SizedBox(width: 4),
              Flexible(
                  child: Text(project == null ? 'Python' : p.basename(project!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600))),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(
                      project == null
                          ? ''
                          : project!.replaceFirst(
                              Platform.environment['HOME'] ?? '', '~'),
                      overflow: TextOverflow.clip,
                      maxLines: 1,
                      style: const TextStyle(fontSize: 12, color: muted)))
            ])),
        Expanded(
            child: ListView(padding: EdgeInsets.zero, children: [
          ...projectRows(),
          InkWell(
              child: SizedBox(
                  height: 24,
                  child: Row(children: [
                    const SizedBox(width: 12),
                    ideIcon('chevronRight'),
                    const SizedBox(width: 4),
                    ideIcon('library'),
                    const SizedBox(width: 4),
                    const Text('外部库', style: TextStyle(fontSize: 14))
                  ])))
        ])),
        if (currentFile != entry)
          TextButton(
              onPressed: () => setState(() => entry = currentFile),
              child: const Text('当前文件为入口', style: TextStyle(fontSize: 12))),
      ]));

  Future<void> createFile({String? folder}) async {
    if (folder == null && project == null) {
      await welcomeScript();
      return;
    }
    final targetFolder = folder ?? project!;
    var draftName = '';
    if (!mounted) return;
    final filename = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('新建 Python 文件'),
                content: TextField(
                    onChanged: (value) => draftName = value,
                    autofocus: true,
                    decoration: const InputDecoration(hintText: '文件名'),
                    onSubmitted: (v) => Navigator.pop(ctx, v)),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, draftName),
                      child: const Text('创建'))
                ]));
    if (filename == null || filename.trim().isEmpty) return;
    var base = p.basename(filename.trim());
    if (!base.endsWith('.py')) base += '.py';
    final file = File(p.join(targetFolder, base));
    try {
      if (await file.exists()) {
        reportError('此项目已有同名文件，请使用其他文件名');
        return;
      }
      await file.parent.create(recursive: true);
      await file.writeAsString('');
    } catch (e) {
      reportError('新建文件失败：$e');
      return;
    }
    await openFile(file);
    if (mounted && currentFile == file.absolute.path) {
      setState(() {
        entry = currentFile;
        welcome = false;
        rememberProject(project!);
      });
    }
  }

  List<Widget> projectRows() {
    final rows = <Widget>[];
    final seen = <String>{};
    final sorted = [...files]..sort((a, b) {
        final ap = p.split(p.relative(a.path, from: project));
        final bp = p.split(p.relative(b.path, from: project));
        if ((ap.length > 1) != (bp.length > 1)) return ap.length > 1 ? -1 : 1;
        return a.path.compareTo(b.path);
      });
    for (final file in sorted) {
      final parts = p.split(p.relative(file.path, from: project));
      bool hidden = false;
      for (var depth = 0; depth < parts.length - 1; depth++) {
        final key = p.joinAll(parts.take(depth + 1));
        if (seen.add(key)) {
          rows.add(InkWell(
              onTap: () => setState(() {
                    if (!collapsedDirs.add(key)) collapsedDirs.remove(key);
                  }),
              child: SizedBox(
                  height: 24,
                  child: Row(children: [
                    SizedBox(
                        width: (30 + depth * 18)
                            .clamp(0, (projectWidth - 100).clamp(0, 2000))
                            .toDouble()),
                    ideIcon(collapsedDirs.contains(key)
                        ? 'chevronRight'
                        : 'chevronDown'),
                    const SizedBox(width: 4),
                    ideIcon('folder'),
                    const SizedBox(width: 4),
                    Expanded(
                        child: Text(parts[depth],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14)))
                  ]))));
        }
        if (collapsedDirs.contains(key)) {
          hidden = true;
          break;
        }
      }
      if (hidden) continue;
      rows.add(draggableLearningReference(
          fileLearningReference(file.path),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Material(
                  color: file.path == currentFile
                      ? const Color(0xff34353a)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                  child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => openFile(file),
                      onLongPress: () => setState(() => entry = file.path),
                      child: SizedBox(
                          height: 24,
                          child: Row(children: [
                            SizedBox(
                                width: (38 + (parts.length - 1) * 18)
                                    .clamp(
                                        0, (projectWidth - 100).clamp(0, 2000))
                                    .toDouble()),
                            ideIcon('python'),
                            const SizedBox(width: 4),
                            Expanded(
                                child: Text(parts.last,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 14)))
                          ])))))));
    }
    return rows;
  }

  Widget documentTab(EditorDocument document) {
    final selected = document.path == currentFile && editorTabActive;
    final name = p.basename(document.path);
    return draggableLearningReference(
        fileLearningReference(document.path),
        Semantics(
            selected: selected,
            child: Tooltip(
                message: document.path,
                child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Material(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                            side: BorderSide(
                                color: selected
                                    ? const Color(0xff45474e)
                                    : Colors.transparent)),
                        clipBehavior: Clip.antiAlias,
                        color:
                            selected ? PyvisColors.surface : Colors.transparent,
                        child: InkWell(
                            onTap: () => openFile(File(document.path)),
                            child: Container(
                                constraints:
                                    const BoxConstraints(maxWidth: 220),
                                height: 28,
                                padding:
                                    const EdgeInsets.only(left: 13, right: 6),
                                child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ideIcon('python', size: 15),
                                      const SizedBox(width: 7),
                                      Flexible(
                                          child: Text(name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  fontSize: 13,
                                                  color: selected
                                                      ? const Color(0xffdadce1)
                                                      : muted))),
                                      if (document.dirty)
                                        const Padding(
                                            padding: EdgeInsets.only(left: 5),
                                            child: Icon(Icons.circle,
                                                size: 5, color: accent)),
                                      if (document.readOnly)
                                        const Padding(
                                            padding: EdgeInsets.only(left: 5),
                                            child: Icon(Icons.lock_outline,
                                                size: 12, color: muted)),
                                      const SizedBox(width: 5),
                                      SizedBox(
                                          width: 22,
                                          height: 24,
                                          child: IconButton(
                                              padding: EdgeInsets.zero,
                                              tooltip:
                                                  document.path == currentFile
                                                      ? '关闭文件'
                                                      : '关闭 $name',
                                              onPressed: () => closeFile(
                                                  path: document.path),
                                              icon: const Icon(Icons.close,
                                                  size: 12, color: muted)))
                                    ]))))))));
  }

  List<Widget> editorTabItems() => [
        if (documents.isEmpty)
          const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('未命名.py', style: TextStyle(fontSize: 13))),
        for (final document in documents.values) documentTab(document),
      ];

  Widget welcomeTabChip() => Tooltip(
      message: '欢迎使用 Pyvis',
      child: Material(
          color: Colors.transparent,
          child: InkWell(
              onTap: () => setState(() => chatTabSelected = false),
              child: Container(
                  key: const ValueKey('welcome-editor-tab'),
                  constraints: const BoxConstraints(maxWidth: 220),
                  height: 28,
                  margin: const EdgeInsets.symmetric(horizontal: 5),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: (!chatTabOpen || !chatTabSelected)
                        ? PyvisColors.surface
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: (!chatTabOpen || !chatTabSelected)
                            ? PyvisColors.border
                            : Colors.transparent),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Image.asset('assets/ide/pyvis.png', width: 16, height: 16),
                    const SizedBox(width: 7),
                    const Flexible(
                        child: Text('欢迎使用 Pyvis',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13))),
                    const SizedBox(width: 4),
                    ib('close', '关闭欢迎页', () => setState(() => welcome = false),
                        size: 12, extent: 20),
                  ])))));

  Widget chatTabChip() => Tooltip(
      message: chatTitle,
      child: Material(
          color: Colors.transparent,
          child: InkWell(
              onTap: () => setState(() => chatTabSelected = true),
              child: Container(
                  key: const ValueKey('chat-editor-tab'),
                  constraints: const BoxConstraints(maxWidth: 220),
                  height: 28,
                  margin: const EdgeInsets.symmetric(horizontal: 5),
                  padding: const EdgeInsets.only(left: 10, right: 2),
                  decoration: BoxDecoration(
                    color: chatTabSelected
                        ? PyvisColors.surface
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: chatTabSelected
                            ? PyvisColors.border
                            : Colors.transparent),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    ProviderLogo(
                        learningPanelKey.currentState?.selectedProvider ??
                            'custom',
                        size: 16),
                    const SizedBox(width: 7),
                    Flexible(
                        child: Text(chatTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13))),
                    SizedBox(
                        width: 20,
                        height: 24,
                        child: IconButton(
                            padding: EdgeInsets.zero,
                            tooltip: '关闭聊天标签',
                            onPressed: hideLearningAi,
                            icon: const Icon(Icons.close,
                                size: 13, color: muted))),
                  ])))));

  Widget editorTabsMenu() => PopupMenuButton<EditorCommand>(
      tooltip: '编辑器操作',
      icon: const Icon(Icons.more_vert, size: 18),
      onSelected: (command) => editorCommands[command]!(),
      itemBuilder: (ctx) => [
            for (final command in [
              if (Platform.isAndroid) ...[
                EditorCommand.duplicate,
                EditorCommand.nextIssue,
                EditorCommand.previousIssue,
              ],
              EditorCommand.renameVariable,
              EditorCommand.format,
              EditorCommand.imports,
              EditorCommand.parameters,
              EditorCommand.documentation,
              EditorCommand.goToLine,
              EditorCommand.intentions,
            ])
              IdeMenuItem(
                  value: command,
                  height: Platform.isAndroid ? 48 : 28,
                  child: IdeMenuLabel(editorCommandLabels[command]!,
                      shortcut: keymap.label(command))),
          ]);

  Widget editorTabs({bool collapsed = false}) => Container(
      height: collapsed ? 0 : 40,
      decoration: collapsed
          ? null
          : const BoxDecoration(
              color: editorBg,
              border: Border(bottom: BorderSide(color: Color(0xff393b40)))),
      child: collapsed
          ? null
          : Row(children: [
              Expanded(
                  child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: editorTabItems()))),
              editorTabsMenu(),
            ]));

  Future<void> emptyEditorAction(EmptyEditorAction action) async {
    final root = project;
    final paths = action == EmptyEditorAction.recent
        ? recentFiles
        : files.map((f) => f.path).toList();
    String label(String path) => root != null && p.isWithin(root, path)
        ? p.relative(path, from: root)
        : path;
    final entries = <({String label, VoidCallback run})>[
      if (action == EmptyEditorAction.search ||
          action == EmptyEditorAction.navigate) ...[
        (label: '打开项目…', run: pickProject),
        (label: '打开文件…', run: openPythonFile),
        (label: '新建 Python 文件…', run: createFile),
      ],
      for (final path in paths)
        (label: label(path), run: () => openFile(File(path))),
    ];
    var query = '';
    await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(builder: (ctx, refresh) {
              void choose(int index) {
                Navigator.pop(ctx);
                entries[index].run();
              }

              final matches = entries.indexed
                  .where((e) =>
                      e.$2.label.toLowerCase().contains(query.toLowerCase()))
                  .toList();
              return AlertDialog(
                  title: Text(action.label),
                  content: SizedBox(
                      width: 460,
                      height: 290,
                      child: Column(children: [
                        TextField(
                            autofocus: true,
                            decoration:
                                const InputDecoration(hintText: '输入名称筛选'),
                            onChanged: (v) => refresh(() => query = v),
                            onSubmitted: (_) {
                              if (matches.isNotEmpty) choose(matches.first.$1);
                            }),
                        Expanded(
                            child: matches.isEmpty
                                ? const Center(child: Text('没有匹配项'))
                                : ListView.builder(
                                    itemCount: matches.length,
                                    itemBuilder: (_, i) => ListTile(
                                        dense: true,
                                        title: Text(matches[i].$2.label,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis),
                                        onTap: () => choose(matches[i].$1))))
                      ])));
            }));
  }

  Future<void> openDroppedFiles(List<String> paths) async {
    final pythonFiles = paths.where((path) =>
        p.extension(path).toLowerCase() == '.py' && File(path).existsSync());
    if (pythonFiles.isEmpty) {
      reportError('请拖入 Python 文件（.py）');
      return;
    }
    for (final path in pythonFiles) {
      if (!mounted) return;
      await openFile(File(path));
    }
  }

  Widget codePane({bool inFlow = false, bool showTabs = true}) {
    if (!inFlow &&
        currentFile == null &&
        documents.isEmpty &&
        editor.text.isEmpty) {
      return EmptyEditor(
          mac: macKeys,
          active: !welcome && editorTabActive,
          onAction: emptyEditorAction,
          onDrop: openDroppedFiles);
    }
    final reference = selectedLearningReference();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (inFlow)
        _FlowSourceHeader(file: p.basename(currentFile ?? '未命名.py'))
      else
        editorTabs(collapsed: !showTabs),
      Expanded(
          child: Stack(fit: StackFit.expand, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
              child: editorContextMenu.wrap(CodeAutocomplete(
                  controller: completionPopup,
                  promptsBuilder: completions,
                  viewBuilder: (context, notifier, onSelected) {
                    completionKeys.attach(notifier, onSelected);
                    return PythonCompletionPopup(
                        notifier: notifier,
                        onSelected: onSelected,
                        onClosed: () => completionKeys.detach(notifier),
                        width: (MediaQuery.sizeOf(context).width - 24)
                            .clamp(200, 360)
                            .toDouble());
                  },
                  child: CodeEditor(
                      controller: editor,
                      selectionDragBuilder:
                          !widget.aiEnabled || reference == null
                              ? null
                              : (child) =>
                                  draggableLearningReference(reference, child),
                      wordWrap: softWrap,
                      verticalScrollbarWidth: 0,
                      scrollbarBuilder: (context, child, details) =>
                          axisDirectionToAxis(details.direction) ==
                                  Axis.vertical
                              ? child
                              : Scrollbar(
                                  controller: details.controller,
                                  scrollbarOrientation:
                                      ScrollbarOrientation.bottom,
                                  child: child),
                      toolbarController: editorContextMenu,
                      shortcutsActivatorsBuilder: keymap,
                      chunkAnalyzer: const PythonChunkAnalyzer(),
                      commentFormatter:
                          DefaultCodeCommentFormatter(singleLinePrefix: '#'),
                      paragraphDecorator: decorations,
                      focusNode: editorFocus,
                      shortcutOverrideActions:
                          !editorWritable ? {} : completionKeys.actions,
                      scrollController: codeScroll,
                      autocompleteSymbols: autoClosePairs,
                      readOnly: fileBusy ||
                          checkingRun ||
                          formatting ||
                          (documents[currentFile]?.readOnly ?? false),
                      findController: finder,
                      findBuilder: (context, controller, readOnly) =>
                          EditorFindPanel(controller: controller),
                      style: CodeEditorStyle(
                          fontFamily: 'JetBrains Mono',
                          fontHeight: 1.57,
                          textColor: PyvisColors.text,
                          backgroundColor: editorBg,
                          cursorColor: accent,
                          cursorLineColor: highlightCurrentLine
                              ? const Color(0xff26282e)
                              : Colors.transparent,
                          fontSize: editorFontSize,
                          codeTheme: CodeHighlightTheme(languages: {
                            'python': CodeHighlightThemeMode(mode: langPython)
                          }, theme: pythonTokenTheme)),
                      indicatorBuilder: (context, editing, chunk, notifier) {
                        if (!identical(renderedLines, notifier)) {
                          renderedLines?.removeListener(updateHintGeometry);
                          renderedLines = notifier;
                          notifier.addListener(updateHintGeometry);
                        }
                        final marker = inFlow ? graphSelectedLine : null;
                        return Row(key: gutterKey, children: [
                          const SizedBox(width: 12),
                          if (showLineNumbers || inFlow)
                            DefaultCodeLineNumber(
                                key: ValueKey(
                                    '$marker-$analysisGeneration-${diagnostics.hashCode}'),
                                textStyle: const TextStyle(
                                    color: muted,
                                    fontFamily: 'JetBrains Mono',
                                    fontSize: 13),
                                customLineIndex2Text: (i) =>
                                    marker == i + 1 ? '▶ ${i + 1}' : '${i + 1}',
                                controller: editing,
                                notifier: notifier),
                          DefaultCodeChunkIndicator(
                              controller: chunk,
                              notifier: notifier,
                              painter: DefaultCodeChunkIndicatorPainter(
                                  color: muted),
                              width: 18),
                          const SizedBox(width: 4),
                          const VerticalDivider(
                              width: 1, thickness: 1, color: Color(0xff34353a)),
                        ]);
                      })))),
          if (miniMapVisible)
            SizedBox(
                width: editorMiniMapWidth,
                child: EditorMiniMap(
                    editor: editor,
                    geometry: hintGeometry,
                    paragraphs: () => renderedLines,
                    onSelectLine: (line) => goToSource(line, 0))),
          InspectionStripe(
              scrollController: codeScroll.verticalScroller,
              geometry: hintGeometry,
              diagnostics:
                  diagnostics.where((d) => d['file'] == currentFile).toList(),
              lineCount: editor.text.split('\n').length,
              onSelect: locateDiagnostic),
        ]),
        parameterHint(),
        if (renameHint != null)
          Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: Material(
                      color: PyvisColors.raised,
                      elevation: 4,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                          side: const BorderSide(color: PyvisColors.border)),
                      child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.info_outline,
                                size: 16, color: PyvisColors.accent),
                            const SizedBox(width: 8),
                            Flexible(
                                child: Semantics(
                                    liveRegion: true,
                                    child: Text(renameHint!))),
                            IconButton(
                                tooltip: '关闭提示',
                                iconSize: 14,
                                onPressed: () =>
                                    setState(() => renameHint = null),
                                icon: const Icon(Icons.close))
                          ]))))),
        Positioned(
            top: 4,
            right: 16,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (widget.aiEnabled && inlineModel.available)
                Semantics(
                    label: inlineModel.status,
                    child: Tooltip(
                        message: inlineModel.status,
                        child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Icon(Icons.auto_awesome_outlined,
                                size: 13,
                                color: inlineModel.status.contains('不可用')
                                    ? muted
                                    : accent)))),
              codeCheckBar(),
            ])),
      ])),
      if (defaultTargetPlatform == TargetPlatform.android) androidTabKey(),
    ]);
  }

  Widget androidTabKey() => ListenableBuilder(
      listenable: Listenable.merge([editorFocus, editor]),
      builder: (context, _) {
        if (!editorFocus.hasFocus) return const SizedBox.shrink();
        final canEdit = editorWritable && !editor.isComposing;
        void changeHistory(VoidCallback change) {
          editorContextMenu.hide(context);
          completionPopup.dismiss();
          decorations.dismissInline();
          change();
        }

        return CodeEditorTapRegion(
            child: TapRegion(
                groupId: completionPopup,
                child: ExcludeFocus(
                    child: Material(
                        color: panel,
                        child: SizedBox(
                            height: 48,
                            child: Row(children: [
                              IconButton(
                                  key: const ValueKey('android-virtual-undo'),
                                  tooltip: '撤回',
                                  onPressed: canEdit && editor.canUndo
                                      ? () => changeHistory(editor.undo)
                                      : null,
                                  icon: const Icon(Icons.undo, size: 20)),
                              IconButton(
                                  key: const ValueKey('android-virtual-redo'),
                                  tooltip: '恢复',
                                  onPressed: canEdit && editor.canRedo
                                      ? () => changeHistory(editor.redo)
                                      : null,
                                  icon: const Icon(Icons.redo, size: 20)),
                              const Spacer(),
                              TextButton.icon(
                                  key: const ValueKey('android-virtual-tab'),
                                  style: TextButton.styleFrom(
                                      minimumSize: const Size(76, 48)),
                                  onPressed: canEdit
                                      ? () {
                                          editorContextMenu.hide(context);
                                          completionKeys.handleTab();
                                        }
                                      : null,
                                  icon: const Icon(Icons.keyboard_tab, size: 16),
                                  label: const Text('Tab')),
                            ]))))));
      });

  Future<void> closeFile({String? path}) async {
    final closing = path ?? currentFile;
    if (closing == null) return;
    final document = documents[closing];
    if (document == null) return;
    if (closing != currentFile && document.dirty) {
      activateDocument(document);
    }
    if (closing == currentFile && !await leaveFile()) return;
    documents.remove(closing);
    if (currentFile == closing) {
      if (documents.isNotEmpty) {
        activateDocument(documents.values.last);
      } else {
        editor.removeListener(onEditorChanged);
        finder.dispose();
        decorations.dispose();
        editorServicesReady = false;
        editor = CodeLineEditingController(
            options: const CodeLineOptions(indentSize: 4));
        _lastText = '';
        currentFile = null;
        entry = null;
        diagnostics = [];
        allDiagnostics = [];
        signatures = [];
        bindEditorServices();
        setState(() {});
        scheduleAnalysis();
      }
    } else {
      setState(() {});
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      document.dispose();
    });
  }

  Widget consolePane() => DecoratedBox(
      decoration: const BoxDecoration(
          color: PyvisColors.background,
          border: Border(top: BorderSide(color: PyvisColors.border))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
            height: 32,
            child: Row(children: [
              const SizedBox(width: 12),
              const Text('控制台',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              if (prompt != null)
                const Padding(
                    padding: EdgeInsets.only(left: 10),
                    child: Text('等待输入',
                        style: TextStyle(color: accent, fontSize: 11))),
              const Spacer(),
              ib('hide', '隐藏控制台', toggleConsole),
              const SizedBox(width: 6)
            ])),
        Expanded(
            child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: SelectableText(console.isEmpty ? '暂无输出' : console,
                    style: const TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        fontFamily: 'JetBrains Mono')))),
        if (prompt != null)
          Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 6, 4),
              child: Row(children: [
                Flexible(
                    flex: 2,
                    child: Text(prompt!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13))),
                const SizedBox(width: 8),
                Expanded(
                    flex: 3,
                    child: TextField(
                        controller: input,
                        autofocus: true,
                        onSubmitted: sendInput,
                        decoration: const InputDecoration(
                            isDense: true, hintText: '输入后回车'))),
                IconButton(
                    onPressed: () => sendInput(input.text),
                    tooltip: '提交输入',
                    icon: const Icon(Icons.send, size: 16))
              ]))
      ]));

  void sendInput(String value) {
    runtime.command('input', value);
    input.clear();
  }

  Widget statePane() {
    final scope = frame['locals'] as Map? ?? {};
    final heap = (selectedStep ?? event)?['heap'] as Map? ?? {};
    final references = <String, List<String>>{};
    for (final binding in scope.entries) {
      final ref = binding.value is Map ? binding.value['ref'] as String? : null;
      if (ref != null) {
        references.putIfAbsent(ref, () => []).add('${binding.key}');
      }
    }
    return ListView(padding: EdgeInsets.zero, children: [
      if (frames.length > 1)
        Wrap(spacing: 4, runSpacing: 4, children: [
          for (var i = 0; i < frames.length; i++)
            ChoiceChip(
                label: Text(frames[i]['name'] == '<module>'
                    ? '主程序'
                    : '${frames[i]['name']} #${frames[i]['id']}'),
                selected: i ==
                    (selectedFrame < 0 ? frames.length - 1 : selectedFrame),
                onSelected: (_) => setState(() => selectedFrame = i))
        ]),
      if (scope.isEmpty)
        const Text('当前作用域尚未绑定变量', style: TextStyle(fontSize: 12, color: muted)),
      for (final binding in scope.entries)
        Builder(builder: (context) {
          final value = binding.value;
          final label = '${binding.key}';
          final sceneValue = SceneValue(label, value, heap);
          final summary = valueSummary(value, heap);
          final ref = value is Map ? value['ref'] as String? : null;
          final aliases = references[ref] ?? [];
          final openable =
              valueEntries(value, heap).isNotEmpty || summary.length > 72;
          final row = Padding(
              padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 3),
              child: Row(children: [
                Expanded(
                    flex: 2,
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: accent))),
                Expanded(
                    flex: 3,
                    child: Text(summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, fontFamily: 'JetBrains Mono'))),
                if (aliases.length > 1)
                  Tooltip(
                      message: '${aliases.join('、')} 引用同一对象',
                      child: const Icon(Icons.link, size: 15, color: muted)),
                if (openable)
                  const Icon(Icons.chevron_right, size: 16, color: muted)
              ]));
          return Column(children: [
            if (openable)
              InkWell(
                  onTap: () =>
                      RuntimeValueView(value: sceneValue).inspect(context),
                  child: row)
            else
              row,
            const Divider(height: 1),
          ]);
        })
    ]);
  }

  Widget playback() {
    final stops = playbackStops;
    final index = recording.stopInsertionIndex(cursor) - 1;
    final canStep = (stops.isNotEmpty && stops.last > cursor) || canAdvanceDemo;
    final count = index < 0 ? '尚未执行' : '${index + 1} / ${stops.length} 步';
    final timeline = Row(children: [
      Expanded(
          child: Slider(
              value: index.clamp(0, stops.length).toDouble(),
              max: (stops.length - 1).clamp(1, 1 << 30).toDouble(),
              onChanged: stops.length < 2 || (running && !demo)
                  ? null
                  : (value) =>
                      seek(stops[value.round().clamp(0, stops.length - 1)]))),
      Text(count, style: const TextStyle(color: muted, fontSize: 11))
    ]);
    final controls = Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
          tooltip: '上一步',
          onPressed: index > 0 && (!running || demo) ? () => move(-1) : null,
          icon: const Icon(Icons.skip_previous, size: 20)),
      IconButton(
          tooltip: playing ? '暂停' : '播放',
          onPressed: playing || canStep || (!running && stops.isNotEmpty)
              ? togglePlay
              : null,
          icon:
              Icon(playing ? Icons.pause_circle : Icons.play_circle, size: 26)),
      Tooltip(
          message: '下一步',
          child: TextButton.icon(
              onPressed: canStep ? () => move(1) : null,
              icon: const Icon(Icons.skip_next, size: 18),
              label: const Text('下一步'))),
      DropdownButton<double>(
          value: speed,
          underline: const SizedBox(),
          items: [.25, .5, 1.0, 2.0, 4.0]
              .map((v) => DropdownMenuItem(
                  value: v,
                  child: Text('${v.toStringAsFixed(v == .25 ? 2 : 1)}×',
                      style: const TextStyle(fontSize: 11))))
              .toList(),
          onChanged: (v) {
            if (v == null) return;
            setState(() => speed = v);
            if (playing) schedulePlayback();
          })
    ]);
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        decoration: const BoxDecoration(
            color: panel,
            border: Border(top: BorderSide(color: PyvisColors.border))),
        child: LayoutBuilder(
            builder: (_, size) => size.maxWidth >= 540
                ? Row(children: [
                    controls,
                    const SizedBox(width: 12),
                    Expanded(child: timeline)
                  ])
                : Column(children: [timeline, controls])));
  }

  String explain(dynamic type) => switch (type) {
        'IndexError' => '访问的位置超出了容器范围。回看出错前的列表长度，并检查索引是否从 0 开始。',
        'NameError' => '当前作用域找不到这个名称。检查拼写、赋值顺序，以及变量是否定义在另一个函数里。',
        'TypeError' => '这次操作接收到的类型不符合要求。查看参与运算的实际值及类型。',
        'ZeroDivisionError' => '除数为 0。回看除数的来源，检查计算或输入。',
        'KeyError' => '字典中没有这个键。查看出错步骤的字典内容和键的类型。',
        'SyntaxError' ||
        'IndentationError' =>
          'Python 无法解析这段代码。检查标记位置及上一行的冒号、括号和缩进。',
        'RecursionError' => '函数调用层数过深。检查递归是否能到达结束条件。',
        'RecordingLimit' => '已保留达到上限前的执行记录。缩短循环或分段运行后再观察。',
        _ => '结合调用栈和出错前的实际值检查这次操作。原始异常信息显示在上方。'
      };
}

class _FlowSourceHeader extends StatelessWidget {
  final String file;
  final bool snapshot;
  const _FlowSourceHeader({required this.file, this.snapshot = false});

  @override
  Widget build(BuildContext context) => Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: const BoxDecoration(
          color: Color(0xff23262c),
          border: Border(bottom: BorderSide(color: PyvisColors.border))),
      child: Row(children: [
        const Icon(Icons.code, size: 16, color: Color(0xffa5c7ff)),
        const SizedBox(width: 7),
        Expanded(
            child: Text(file,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600))),
        if (snapshot)
          const Text('运行时源码',
              style: TextStyle(fontSize: 11, color: Color(0xffa9b1bf)))
      ]));
}

class _RecordedSource extends StatefulWidget {
  final String file, source;
  final int? line, inspectedLine;

  const _RecordedSource(
      {super.key,
      required this.file,
      required this.source,
      required this.line,
      this.inspectedLine});

  @override
  State<_RecordedSource> createState() => _RecordedSourceState();
}

class _RecordedSourceState extends State<_RecordedSource> {
  static const extent = 22.0;
  final vertical = ScrollController(keepScrollOffset: false);
  final horizontal = ScrollController(keepScrollOffset: false);
  late List<String> lines;
  late double lineWidth;

  @override
  void initState() {
    super.initState();
    load();
    reveal();
  }

  @override
  void didUpdateWidget(covariant _RecordedSource oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) load();
    if (oldWidget.source != widget.source ||
        oldWidget.line != widget.line ||
        oldWidget.inspectedLine != widget.inspectedLine) {
      reveal();
    }
  }

  void load() {
    lines = widget.source.split('\n');
    lineWidth = lines
            .fold(0, (longest, line) {
              final estimated = line.runes.length * 13;
              return estimated > longest ? estimated : longest;
            })
            .clamp(0, 12000)
            .toDouble() +
        58;
  }

  void reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !vertical.hasClients) return;
      final line = widget.inspectedLine ?? widget.line;
      if (line == null) return;
      final top = (line - 1) * extent;
      final position = vertical.position;
      if (top < position.pixels + extent ||
          top + extent >
              position.pixels + position.viewportDimension - extent) {
        vertical
            .jumpTo((top - extent * 3).clamp(0.0, position.maxScrollExtent));
      }
    });
  }

  @override
  void dispose() {
    vertical.dispose();
    horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
      color: const Color(0xff1c1e22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _FlowSourceHeader(file: widget.file, snapshot: true),
        Expanded(
            child: LayoutBuilder(
                builder: (_, size) => Scrollbar(
                    controller: horizontal,
                    notificationPredicate: (notice) =>
                        notice.metrics.axis == Axis.horizontal,
                    child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        controller: horizontal,
                        child: SizedBox(
                            width:
                                lineWidth.clamp(size.maxWidth, double.infinity),
                            height: size.maxHeight,
                            child: ListView.builder(
                                controller: vertical,
                                itemExtent: extent,
                                itemCount: lines.length,
                                itemBuilder: (_, index) {
                                  final active = widget.line == index + 1;
                                  final inspected =
                                      widget.inspectedLine == index + 1;
                                  return Container(
                                      color: active
                                          ? const Color(0xff244238)
                                          : inspected
                                              ? const Color(0xff26354d)
                                              : null,
                                      alignment: Alignment.centerLeft,
                                      child: Row(children: [
                                        SizedBox(
                                            width: 49,
                                            child: Text('${index + 1}',
                                                textAlign: TextAlign.right,
                                                style: TextStyle(
                                                    color: active
                                                        ? const Color(
                                                            0xff83dfbb)
                                                        : const Color(
                                                            0xffa1a8b4),
                                                    fontSize: 12,
                                                    fontFamily:
                                                        'JetBrains Mono'))),
                                        const SizedBox(width: 8),
                                        const VerticalDivider(
                                            width: 1,
                                            color: PyvisColors.border),
                                        const SizedBox(width: 9),
                                        Expanded(
                                            child: Text(lines[index],
                                                maxLines: 1,
                                                softWrap: false,
                                                style: const TextStyle(
                                                    fontSize: 12,
                                                    fontFamily:
                                                        'JetBrains Mono')))
                                      ]));
                                })))))),
      ]));
}
