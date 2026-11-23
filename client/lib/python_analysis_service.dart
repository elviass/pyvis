import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'runtime_adapter.dart';

/// Local CPython analysis; source is parsed and compiled, never executed.
class PythonAnalysisService {
  Process? _process;
  Future<void>? _starting;
  bool _disposed = false;
  int _id = 0;
  final _pending = <int, Completer<Map<String, dynamic>>>{};

  Future<void> warmUp() async {
    try {
      await _start();
    } catch (_) {
      // A real analysis request retries startup and reports any failure.
    }
  }

  Future<void> _start() async {
    if (_process != null) return;
    if (_starting != null) return _starting!;
    final ready = Completer<void>();
    _starting = ready.future;
    try {
      if (Platform.isAndroid) await RuntimeAdapter.prepareBundledRuntime();
      if (!Platform.isAndroid &&
          !Platform.isMacOS &&
          !Platform.isWindows &&
          !Platform.isLinux) {
        throw UnsupportedError('此平台的 Python 解析桥尚未提供');
      }
      final process = await Process.start(RuntimeAdapter.pythonExecutable, [
        '-X',
        'utf8',
        '-u',
        '-m',
        'pyvis_runtime.code_intelligence'
      ], environment: {
        ...RuntimeAdapter.environment,
        if (Platform.isMacOS &&
            Platform.resolvedExecutable.contains('.app/Contents/MacOS/'))
          'PYVIS_EDITOR_TOOLS':
              '${File(Platform.resolvedExecutable).parent.parent.path}/Helpers',
      });
      if (_disposed) {
        process.kill();
        throw StateError('代码检查已关闭');
      }
      _process = process;
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (_process != process) return;
        try {
          final response = jsonDecode(line) as Map<String, dynamic>;
          final pending = _pending.remove(response['id']);
          pending?.complete(response);
        } catch (error) {
          _fail('读取代码检查失败：$error');
        }
      }, onError: (Object error) => _fail('读取代码检查失败：$error'));
      var stderr = '';
      process.stderr
          .transform(utf8.decoder)
          .listen((text) => stderr = '$stderr$text');
      process.exitCode.then((code) {
        if (_process == process) {
          _process = null;
          _fail('Python 解析进程退出（$code）${stderr.isEmpty ? '' : '：$stderr'}');
        }
      });
      ready.complete();
    } catch (error, stack) {
      ready.completeError(error, stack);
    } finally {
      _starting = null;
    }
    return ready.future;
  }

  Future<Map<String, dynamic>> analyze(String source, String filename,
          [String? project,
          Map<String, String>? buffers,
          List<String>? dictionary]) =>
      request({
        'source': source,
        'filename': filename,
        'project': project,
        'buffers': buffers,
        'dictionary': dictionary ?? [],
      });

  Future<Map<String, dynamic>> format(String source, String filename,
          {bool imports = false, String? selection}) =>
      request({
        'action': 'format',
        'source': source,
        'filename': filename,
        'imports': imports,
        'selection': selection
      });

  Future<Map<String, dynamic>> symbol(String action, String source,
          String filename, int line, int column, String? project,
          {String? candidate}) =>
      request({
        'action': action,
        'candidate': candidate,
        'source': source,
        'filename': filename,
        'line': line,
        'column': column,
        'project': project
      });

  Future<Map<String, dynamic>> complete(String source, String filename,
          int line, int column, String? project) =>
      request({
        'action': 'complete',
        'source': source,
        'filename': filename,
        'line': line,
        'column': column,
        'project': project
      });

  Future<Map<String, dynamic>> check(
          Map<String, String> sources, String entry, String project) =>
      request({
        'action': 'check',
        'sources': sources,
        'entry': entry,
        'project': project
      });

  Future<Map<String, dynamic>> request(Map<String, dynamic> payload) async {
    if (_disposed) throw StateError('代码检查已关闭');
    await _start();
    if (_disposed) throw StateError('代码检查已关闭');
    final id = ++_id;
    final reply = Completer<Map<String, dynamic>>();
    _pending[id] = reply;
    _process!.stdin.writeln(jsonEncode({...payload, 'id': id}));
    try {
      final response = await reply.future.timeout(const Duration(seconds: 8));
      if (response['error'] != null) throw StateError('${response['error']}');
      return response;
    } on TimeoutException {
      _pending.remove(id);
      final process = _process;
      _process = null;
      process?.kill();
      _fail('代码检查解析超时');
      rethrow;
    }
  }

  void _fail(String message) {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final reply in pending) {
      if (!reply.isCompleted) reply.completeError(StateError(message));
    }
  }

  void dispose() {
    _disposed = true;
    final process = _process;
    _process = null;
    process?.kill();
    _fail('代码检查已关闭');
  }
}
