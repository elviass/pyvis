import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ffi' show Abi;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Process transport shared by desktop and Android CPython workers.
class RuntimeAdapter {
  static String? _preparedRoot;
  static String? _androidHome;
  static String? _androidNative;
  static Future<void>? _preparation;
  static Future<void> prepareBundledRuntime(
      {AssetBundle? bundle, Directory? workspace}) async {
    if (_preparedRoot != null) return;
    try {
      await (_preparation ??= _prepare(bundle, workspace));
    } finally {
      _preparation = null;
    }
  }

  static Future<void> _prepare(
      AssetBundle? bundle, Directory? workspace) async {
    if (Platform.isAndroid && bundle == null && workspace == null) {
      final paths = await const MethodChannel('dev.pyvis/workspace')
          .invokeMapMethod<String, String>('prepareExamples');
      if (paths == null) throw StateError('无法定位安卓学习工作区');
      _androidHome = paths['home']!;
      _androidNative = paths['native']!;
      _preparedRoot = paths['root']!;
      return;
    }
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null) throw StateError('无法定位本机学习工作区');
    final support = Platform.isMacOS
        ? p.join(home, 'Library', 'Application Support')
        : (Platform.environment['APPDATA'] ?? p.join(home, '.local', 'share'));
    final folder =
        workspace ?? Directory(p.join(support, 'Pyvis', 'learning-workspace'));
    final assets = bundle ?? rootBundle;
    await folder.create(recursive: true);
    if (Platform.isWindows && bundle == null && _windowsRuntime.existsSync()) {
      final examples = Directory(p.join(_executableDir, 'data', 'examples'));
      await for (final source in examples.list(recursive: true)) {
        if (source is! File || !source.path.endsWith('.py')) continue;
        final dest = File(p.join(folder.path, 'examples',
            p.relative(source.path, from: examples.path)));
        if (await dest.exists()) continue;
        await dest.parent.create(recursive: true);
        await source.copy(dest.path);
      }
      _preparedRoot = folder.path;
      return;
    }
    final manifest = await AssetManifest.loadFromAssetBundle(assets);
    for (final key in manifest.listAssets()) {
      if (!key.startsWith('../runtime/') && !key.startsWith('../examples/')) {
        continue;
      }
      final relative = key.substring(3);
      if (relative
              .split('/')
              .any((part) => part.startsWith('.') || part == '__pycache__') ||
          relative.endsWith('.pyc')) {
        continue;
      }
      if (key.startsWith('../examples/') && !key.endsWith('.py')) continue;
      final file = File(p.join(folder.path, relative));
      if (key.startsWith('../examples/') && await file.exists()) continue;
      await file.parent.create(recursive: true);
      final data = await assets.load(key);
      await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    }
    _preparedRoot = folder.path;
  }

  Process? _process;
  int _generation = 0;
  final void Function(Map<String, dynamic>) onEvent;
  final void Function(String) onFailure;
  RuntimeAdapter({required this.onEvent, required this.onFailure});

  static String get root {
    final prepared = _preparedRoot;
    if (prepared != null) return prepared;
    final candidates = [
      Platform.environment['PYVIS_ROOT'],
      p.dirname(Platform.resolvedExecutable),
      Directory.current.path,
      p.dirname(Directory.current.path)
    ];
    return candidates.whereType<String>().firstWhere(
        (path) => Directory(p.join(path, 'runtime')).existsSync(),
        orElse: () => p.dirname(Directory.current.path));
  }

  static String get _executableDir => p.dirname(Platform.resolvedExecutable);
  static Directory get _windowsRuntime =>
      Directory(p.join(_executableDir, 'data', 'runtime'));

  static String get pythonExecutable {
    if (Platform.isAndroid) return p.join(_androidNative!, 'libpyvis_cli.so');
    if (Platform.isMacOS && _executableDir.endsWith('.app/Contents/MacOS')) {
      final arch = Abi.current() == Abi.macosArm64 ? 'arm64' : 'x86_64';
      return p.join(p.dirname(_executableDir), 'Resources', 'cpython', arch,
          'python', 'bin', 'python3');
    }
    if (Platform.isWindows && _windowsRuntime.existsSync()) {
      return p.join(_executableDir, 'python', 'python.exe');
    }
    const configured = String.fromEnvironment('PYVIS_PYTHON');
    return Platform.environment['PYVIS_PYTHON'] ??
        (configured.isNotEmpty
            ? configured
            : Platform.isWindows
                ? 'python'
                : 'python3');
  }

  static String get runtimePath => Platform.isAndroid
      ? p.join(_androidHome!, 'runtime')
      : Platform.isWindows && _windowsRuntime.existsSync()
          ? _windowsRuntime.path
          : Platform.environment['PYVIS_RUNTIME'] ?? p.join(root, 'runtime');

  static Map<String, String> get environment => {
        'PYTHONPATH': runtimePath,
        'PYTHONIOENCODING': 'utf-8',
        if (Platform.isAndroid) ...{
          'PYTHONHOME': _androidHome!,
          'LD_LIBRARY_PATH': _androidNative!,
          'HOME': root,
          'TMPDIR': Directory.systemTemp.path,
          'PYTHONDONTWRITEBYTECODE': '1',
        },
      };

  static Future<({String version, String executable})?> describePython() async {
    try {
      if (Platform.isAndroid) await prepareBundledRuntime();
      final result = await Process.run(
              pythonExecutable,
              [
                if (!Platform.isAndroid) '-I',
                '-c',
                'import sys, json; print(json.dumps([sys.version.split()[0], sys.executable]))',
              ],
              environment: environment)
          .timeout(const Duration(seconds: 4));
      if (result.exitCode != 0) return null;
      final info = jsonDecode(result.stdout as String) as List;
      return (version: info[0] as String, executable: info[1] as String);
    } catch (_) {
      return null;
    }
  }

  Future<void> start(String entry, String project, {bool demo = false}) async {
    stop();
    final generation = _generation;
    if (Platform.isAndroid) await prepareBundledRuntime();
    if (!Platform.isAndroid &&
        !Platform.isWindows &&
        !Platform.isMacOS &&
        !Platform.isLinux) {
      throw UnsupportedError('移动端嵌入式运行桥尚未实现');
    }
    final python = pythonExecutable;
    final process = await Process.start(
        python,
        [
          '-X',
          'utf8',
          '-u',
          '-m',
          'pyvis_runtime',
          entry,
          '--project',
          project,
          '--worker',
          '--mode',
          demo ? 'demo' : 'direct',
        ],
        environment: environment);
    if (generation != _generation) {
      process.kill();
      return;
    }
    _process = process;
    var finished = false;
    final stdoutDone = Completer<void>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
            (line) {
              if (_process != process) return;
              try {
                final event = jsonDecode(line) as Map<String, dynamic>;
                if (event['kind'] == 'finished') finished = true;
                onEvent(event);
              } catch (e) {
                onFailure('执行记录解析失败：$e');
              }
            },
            onDone: () => stdoutDone.complete(),
            onError: (Object error) {
              if (!stdoutDone.isCompleted) stdoutDone.complete();
              if (_process == process) onFailure('读取执行记录失败：$error');
            });
    process.stderr.transform(utf8.decoder).listen((text) {
      if (_process == process) onFailure(text);
    });
    process.exitCode.then((code) async {
      await stdoutDone.future;
      if (_process == process && !finished) {
        onFailure('运行进程意外退出（$code），已保留此前的执行记录');
      }
    });
  }

  void command(String action, [String? text]) {
    _process?.stdin.writeln(
        jsonEncode({'action': action, if (text != null) 'text': text}));
  }

  void stop() {
    _generation++;
    final process = _process;
    _process = null;
    process?.kill();
  }
}
