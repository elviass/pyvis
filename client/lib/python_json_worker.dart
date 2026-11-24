import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;

import 'runtime_adapter.dart';

Map<String, dynamic> _decode(String line) =>
    jsonDecode(line) as Map<String, dynamic>;

/// Request/response transport for a dedicated Python JSON-lines process.
class PythonJsonWorker {
  final String module;
  final String label;
  final Map<String, String> environment;
  final bool decodeLargeResponsesOffThread;

  PythonJsonWorker({
    required this.module,
    required this.label,
    this.environment = const {},
    this.decodeLargeResponsesOffThread = false,
  });

  Process? _process;
  Future<void>? _starting;
  bool _disposed = false;
  int _id = 0;
  final _pending = <int, Completer<Map<String, dynamic>>>{};

  Future<void> warmUp() async {
    try {
      await _start();
    } catch (_) {
      // A real request retries startup and reports any failure.
    }
  }

  Future<void> _start() {
    if (_disposed) return Future.error(StateError('$label已关闭'));
    if (_process != null) return Future.value();
    return _starting ??= _launch().whenComplete(() {
      _starting = null;
    });
  }

  Future<void> _launch() async {
    if (Platform.isAndroid) await RuntimeAdapter.prepareBundledRuntime();
    if (!Platform.isAndroid &&
        !Platform.isMacOS &&
        !Platform.isWindows &&
        !Platform.isLinux) {
      throw UnsupportedError('此平台的 Python 解析桥尚未提供');
    }
    final process = await Process.start(
      RuntimeAdapter.pythonExecutable,
      ['-X', 'utf8', '-u', '-m', module],
      environment: {...RuntimeAdapter.environment, ...environment},
    );
    if (_disposed) {
      process.kill();
      throw StateError('$label已关闭');
    }
    _process = process;
    final stderr = StringBuffer();
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(stderr.write);
    final stdout = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asyncMap((line) async => decodeLargeResponsesOffThread &&
                Platform.isAndroid &&
                line.length >= 65536
            ? await compute(_decode, line)
            : _decode(line));
    final drained = stdout.forEach((response) {
      if (_process == process) {
        _pending.remove(response['id'])?.complete(response);
      }
    }).catchError((Object error) {
      if (_process == process) {
        _stopProcess('读取$label失败：$error');
      }
    });
    unawaited(process.exitCode.then((code) async {
      await drained;
      if (_process == process) {
        _stopProcess('Python 解析进程退出（$code）'
            '${stderr.isEmpty ? '' : '：$stderr'}');
      }
    }));
  }

  Future<Map<String, dynamic>> request(
      Map<String, dynamic> payload, Duration timeout) async {
    await _start();
    final process = _process;
    if (process == null) throw StateError('$label不可用');
    final id = ++_id;
    final reply = Completer<Map<String, dynamic>>();
    final command = jsonEncode({...payload, 'id': id});
    _pending[id] = reply;
    try {
      process.stdin.writeln(command);
      return await reply.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      if (_process == process) _stopProcess('$label解析超时');
      rethrow;
    } finally {
      _pending.remove(id);
    }
  }

  void _stopProcess(String message) {
    final process = _process;
    _process = null;
    process?.kill();
    final pending = _pending.values.toList();
    _pending.clear();
    for (final reply in pending) {
      reply.completeError(StateError(message));
    }
  }

  void dispose() {
    _disposed = true;
    _stopProcess('$label已关闭');
  }
}
