import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

abstract class InlineCompletionModel extends ChangeNotifier {
  bool get available;
  String get status;
  Future<String?> complete(String prefix, String suffix);
  Stream<String> predictions(String prefix, String suffix) async* {
    final result = await complete(prefix, suffix);
    if (result != null) yield result;
  }

  Future<void> warmUp() async {}
  void cancel();
  Future<void> stop() async {
    cancel();
  }
}

/// Managed, offline FIM inference. Only loopback is used, with a per-process key.
class LocalCompletionModel extends InlineCompletionModel {
  static const modelFilename = 'qwen2.5-coder-0.5b-q5_k_m.gguf';
  final String executable, model;
  Process? _process;
  Future<void>? _starting;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  HttpClient? _inference;
  int _port = 0, _generation = 0, _launchGeneration = 0;
  bool _disposed = false;
  String _status = '本地续写待机';
  final _key = List.generate(32, (_) => Random.secure().nextInt(256))
      .map((v) => v.toRadixString(16).padLeft(2, '0'))
      .join();

  LocalCompletionModel({String? executable, String? model})
      : executable = executable ??
            p.join(
                p.dirname(Platform.resolvedExecutable),
                '..',
                'Helpers',
                'local-completion',
                Platform.isWindows ? 'llama-server.exe' : 'llama-server'),
        model = model ??
            p.join(p.dirname(Platform.resolvedExecutable), '..', 'Resources',
                'Models', modelFilename);

  String get _readyStatus =>
      '本地续写就绪 · ${p.basename(model) == modelFilename ? 'Qwen2.5-Coder 0.5B' : p.basenameWithoutExtension(model)}';

  @override
  bool get available =>
      File(executable).existsSync() && File(model).existsSync();
  @override
  String get status => available ? _status : '本地续写模型未安装';
  void _setStatus(String value) {
    if (_disposed || _status == value) return;
    _status = value;
    notifyListeners();
  }

  Future<void> _start() {
    if (_disposed) return Future.error(StateError('本地续写已关闭'));
    if (_starting != null) return _starting!;
    if (_process != null) return Future.value();
    return _starting = _launch(_launchGeneration).whenComplete(() {
      _starting = null;
    });
  }

  Future<void> _launch(int generation) async {
    bool active() => !_disposed && generation == _launchGeneration;
    try {
      if (!available) throw StateError('本地续写模型未安装');
      _setStatus('本地续写加载中');
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _port = socket.port;
      await socket.close();
      if (!active()) throw StateError('本地续写已关闭');
      final process = await Process.start(
          executable,
          [
            '-m',
            model,
            '--host',
            '127.0.0.1',
            '--port',
            '$_port',
            '-c',
            '3072',
            '-np',
            '1',
            '-t',
            '4',
            '--cache-reuse',
            '32',
            '--cache-ram',
            '128',
            '--no-webui',
            '--no-slots',
            '--offline',
            '--api-key',
            _key,
          ],
          workingDirectory: p.dirname(executable));
      if (!active()) {
        process.kill();
        throw StateError('本地续写已关闭');
      }
      _process = process;
      // Consume output without storing learner code or model prompts in logs.
      process.stdout.drain<void>();
      process.stderr.drain<void>();
      process.exitCode.then((_) {
        if (identical(_process, process)) {
          _process = null;
          _setStatus('本地续写不可用');
        }
      });
      final deadline = DateTime.now().add(const Duration(seconds: 35));
      while (active() && DateTime.now().isBefore(deadline)) {
        if (_process == null) throw StateError('本地续写启动失败');
        try {
          final request =
              await _http.getUrl(Uri.http('127.0.0.1:$_port', '/health'));
          final response =
              await request.close().timeout(const Duration(seconds: 1));
          await response.drain<void>();
          if (active() && response.statusCode == 200) {
            _setStatus(_readyStatus);
            return;
          }
        } on Exception {
          /* A loading model returns 503 or refuses connections. */
        }
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      throw TimeoutException('本地续写加载超时');
    } catch (_) {
      if (active()) {
        _process?.kill();
        _process = null;
        _setStatus('本地续写不可用');
      }
      rethrow;
    }
  }

  @override
  Future<void> warmUp() async {
    if (!available) return;
    try {
      await _start();
    } catch (_) {
      // Starting again on the next edit is safe after a transient failure.
    }
  }

  @override
  Future<String?> complete(String prefix, String suffix) async {
    String? latest;
    await for (final prediction in predictions(prefix, suffix)) {
      latest = prediction;
    }
    return latest;
  }

  @override
  Stream<String> predictions(String prefix, String suffix) async* {
    cancel();
    final generation = _generation;
    bool active() => !_disposed && generation == _generation;
    HttpClient? connection;
    try {
      await _start();
      if (!active()) return;
      // Each prediction owns its connection so cancelling also closes a
      // response already in progress and releases the model's only slot.
      connection = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      _inference = connection;
      final request =
          await connection.postUrl(Uri.http('127.0.0.1:$_port', '/infill'));
      if (!active()) return;
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_key');
      request.write(jsonEncode({
        'input_prefix': _nearbyPrefix(prefix),
        'input_suffix': _nearbySuffix(suffix),
        'n_predict': 48,
        'stream': true,
        'temperature': 0,
        'seed': 42,
        'cache_prompt': true,
        'stop': [
          '<|endoftext|>',
          '<|fim_prefix|>',
          '<|fim_suffix|>',
          '<|fim_middle|>',
          '<|file_sep|>',
          '\n\n',
        ],
      }));
      final response =
          await request.close().timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) throw StateError('本地续写请求失败');
      var text = '';
      String? lastPreview;
      final packets = response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 5));
      await for (final packet in packets) {
        if (!active()) return;
        if (!packet.startsWith('data:')) continue;
        final data = packet.substring(5).trimLeft();
        if (data == '[DONE]') break;
        final update = jsonDecode(data) as Map;
        if (update['error'] != null) throw StateError('本地续写请求失败');
        final chunk = update['content'];
        if (chunk is String && chunk.isNotEmpty) {
          text += chunk;
          if (chunk.contains('\n')) {
            final preview = cleanInlinePrediction(
                text.substring(0, text.lastIndexOf('\n')));
            if (preview != null && preview != lastPreview) {
              lastPreview = preview;
              yield preview;
            }
            if ('\n'.allMatches(text).length >= 4) break;
          }
        }
        if (update['stop'] == true) break;
      }
      if (!active()) return;
      _setStatus(_readyStatus);
      final preview = cleanInlinePrediction(text);
      if (preview != null && preview != lastPreview) yield preview;
    } catch (_) {
      if (active()) _setStatus('本地续写暂不可用');
    } finally {
      if (identical(_inference, connection)) _inference = null;
      connection?.close(force: true);
    }
  }

  @override
  void cancel() {
    _generation++;
    _inference?.close(force: true);
    _inference = null;
  }

  @override
  Future<void> stop() async {
    cancel();
    _launchGeneration++;
    final process = _process;
    _process = null;
    if (process != null) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(
            Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigkill);
      }
    }
    try {
      await _starting;
    } catch (_) {
      // A launch cancelled during shutdown may report an incomplete start.
    }
    _setStatus('本地续写待机');
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    _http.close(force: true);
    super.dispose();
  }
}

String _nearbyPrefix(String prefix) {
  const budget = 1000;
  if (prefix.length <= budget) return prefix;
  final start = prefix.length - budget;
  final newline = prefix.indexOf('\n', start);
  if (newline >= start && newline < start + 200) {
    return prefix.substring(newline + 1);
  }
  final leading = prefix.codeUnitAt(start);
  return prefix
      .substring(leading >= 0xdc00 && leading <= 0xdfff ? start + 1 : start);
}

String _nearbySuffix(String suffix) {
  const budget = 400;
  if (suffix.length <= budget) return suffix;
  final last = suffix.codeUnitAt(budget - 1);
  return suffix.substring(
      0, last >= 0xd800 && last <= 0xdbff ? budget - 1 : budget);
}

String? cleanInlinePrediction(String value) {
  if (value.contains('```') ||
      value.contains('<|') ||
      value.contains('\u0000')) {
    return null;
  }
  value = value.replaceAll('\r\n', '\n');
  if (value.trim().isEmpty) return null;
  // The validator chooses a complete, valid prefix from at most four lines.
  return value.split('\n').take(4).join('\n').trimRight();
}
