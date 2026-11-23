import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show compute;
import 'runtime_adapter.dart';

Map<String, dynamic> _decodeGraph(String line) =>
    jsonDecode(line) as Map<String, dynamic>;

/// A separate parser process. It imports only our AST module, never user code.
class BlueprintService {
  Process? _process;
  Future<void>? _starting;
  bool _disposed = false;
  int _id = 0;
  final _pending = <int, Completer<Map<String, dynamic>>>{};

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
        'pyvis_runtime.blueprint'
      ], environment: {
        ...RuntimeAdapter.environment,
      });
      if (_disposed) {
        process.kill();
        throw StateError('代码图已关闭');
      }
      _process = process;
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) async {
        if (_process != process) return;
        try {
          final response = Platform.isAndroid && line.length >= 65536
              ? await compute(_decodeGraph, line)
              : _decodeGraph(line);
          if (_process != process) return;
          final pending = _pending.remove(response['id']);
          pending?.complete(response);
        } catch (error) {
          _fail('读取代码图失败：$error');
        }
      }, onError: (Object error) => _fail('读取代码图失败：$error'));
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

  Future<Map<String, dynamic>> parse(String source,
      {String mode = 'full'}) async {
    if (_disposed) throw StateError('代码图已关闭');
    await _start();
    if (_disposed) throw StateError('代码图已关闭');
    final id = ++_id;
    final reply = Completer<Map<String, dynamic>>();
    _pending[id] = reply;
    _process!.stdin
        .writeln(jsonEncode({'id': id, 'source': source, 'mode': mode}));
    try {
      return await reply.future
          .timeout(Duration(seconds: mode == 'nodes' ? 30 : 6));
    } on TimeoutException {
      _pending.remove(id);
      final process = _process;
      _process = null;
      process?.kill();
      _fail('代码图解析超时');
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
    _fail('代码图已关闭');
  }
}
