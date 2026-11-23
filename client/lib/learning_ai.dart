import 'dart:async';
import 'ai_protocol.dart';
export 'ai_protocol.dart' show AiProtocol;
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

class AiFailure implements Exception {
  final String message;
  const AiFailure(this.message);
  @override
  String toString() => message;
}

class AiConfig {
  final String endpoint, model, key;
  final AiProtocol protocol;
  const AiConfig(this.endpoint, this.model, this.key,
      {this.protocol = AiProtocol.chat});
  AiConfig withModel(String id) =>
      AiConfig(endpoint, id, key, protocol: protocol);

  Uri get baseUri {
    final u = Uri.tryParse(endpoint.trim());
    if (u == null ||
        u.host.isEmpty ||
        u.userInfo.isNotEmpty ||
        u.hasQuery ||
        u.hasFragment ||
        !(u.scheme == 'https' ||
            (u.scheme == 'http' &&
                ['localhost', '127.0.0.1', '::1'].contains(u.host)))) {
      throw const AiFailure('请输入 HTTPS 服务地址（本机模拟服务可用 HTTP），不要在地址中放入凭据。');
    }
    final path = u.path
        .replaceAll(RegExp(r'/+$'), '')
        .replaceFirst(RegExp(r'/(chat/completions|responses|messages)$'), '');
    return u.replace(path: path);
  }

  Uri get uri {
    final base = baseUri;
    final suffix = switch (protocol) {
      AiProtocol.chat => '/chat/completions',
      AiProtocol.responses => '/responses',
      AiProtocol.anthropic => '/messages',
      AiProtocol.gemini =>
        '/models/${model.trim().replaceFirst(RegExp(r'^models/'), '')}:generateContent',
    };
    return base.replace(path: '${base.path}$suffix');
  }

  Uri get modelsUri => baseUri.replace(path: '${baseUri.path}/models');

  void validate({bool requireModel = true}) {
    baseUri;
    if (protocol == AiProtocol.gemini &&
        requireModel &&
        !RegExp(r'^(models/)?[a-zA-Z0-9._-]+$').hasMatch(model.trim())) {
      throw const AiFailure('请输入有效的 Gemini 模型 ID。');
    }
    if ((requireModel && model.trim().isEmpty) || key.trim().isEmpty) {
      throw const AiFailure('请填写模型名和 API Key。');
    }
    if (key.contains('\n') || key.contains('\r')) {
      throw const AiFailure('API Key 格式不正确。');
    }
  }

  Map<String, String> toJson() => {
        'endpoint': endpoint,
        'model': model,
        'key': key,
        'protocol': protocol.name
      };
}

class AiProviderPreset {
  final String id, label, endpoint;
  final AiProtocol protocol;
  const AiProviderPreset(this.id, this.label, this.endpoint,
      {this.protocol = AiProtocol.chat});
  static const all = [
    AiProviderPreset('openai', '官方 · OpenAI', 'https://api.openai.com/v1'),
    AiProviderPreset(
        'deepseek', '官方 · DeepSeek', 'https://api.deepseek.com/v1'),
    AiProviderPreset(
        'openrouter', '第三方 · OpenRouter', 'https://openrouter.ai/api/v1'),
    AiProviderPreset(
        'siliconflow', '第三方 · 硅基流动', 'https://api.siliconflow.cn/v1'),
    AiProviderPreset(
        'anthropic', '官方 · Anthropic Claude', 'https://api.anthropic.com/v1',
        protocol: AiProtocol.anthropic),
    AiProviderPreset('gemini', '官方 · Google Gemini',
        'https://generativelanguage.googleapis.com/v1beta',
        protocol: AiProtocol.gemini),
    AiProviderPreset('qwen', '官方 · 阿里云百炼 / Qwen',
        'https://dashscope.aliyuncs.com/compatible-mode/v1'),
    AiProviderPreset(
        'ark', '官方 · 火山方舟 / 豆包', 'https://ark.cn-beijing.volces.com/api/v3'),
    AiProviderPreset(
        'kimi', '官方 · Moonshot / Kimi', 'https://api.moonshot.cn/v1'),
    AiProviderPreset(
        'glm', '官方 · 智谱 / GLM', 'https://open.bigmodel.cn/api/paas/v4'),
    AiProviderPreset('mistral', '官方 · Mistral', 'https://api.mistral.ai/v1'),
    AiProviderPreset('groq', '第三方 · Groq', 'https://api.groq.com/openai/v1'),
    AiProviderPreset('xai', '官方 · xAI / Grok', 'https://api.x.ai/v1',
        protocol: AiProtocol.responses),
    AiProviderPreset('custom', '自定义 · OpenAI 兼容', ''),
  ];
}

class AiProfile {
  final String id, name, provider, customId;
  final AiConfig config;
  final List<String> _modelIds;
  const AiProfile(this.id, this.name, this.provider, this.config,
      {this.customId = '', List<String> modelIds = const []})
      : _modelIds = modelIds;

  List<String> get modelIds => {
        ..._modelIds,
        if (config.model.isNotEmpty) config.model,
      }.where((id) => id.isNotEmpty).toList();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'provider': provider,
        'customId': customId,
        'modelIds': modelIds,
        ...config.toJson()
      };
  factory AiProfile.fromJson(Map data) => AiProfile(
      data['id'] as String,
      data['name'] as String,
      data['provider'] as String,
      AiConfig(data['endpoint'] as String, data['model'] as String,
          data['key'] as String,
          protocol:
              AiProtocol.values.byName(data['protocol'] as String? ?? 'chat')),
      customId: data['customId'] as String? ?? '',
      modelIds: (data['modelIds'] as List? ?? []).whereType<String>().toList());
}

class AiProfiles {
  final List<AiProfile> profiles;
  final String? activeId;
  const AiProfiles(this.profiles, this.activeId);
  AiProfile? get active => profiles.where((p) => p.id == activeId).firstOrNull;
  Map<String, dynamic> toJson() => {
        'version': 2,
        'activeId': activeId,
        'profiles': profiles.map((p) => p.toJson()).toList()
      };
}

class AiKeychainLocked extends AiFailure {
  const AiKeychainLocked() : super('迁移旧版模型配置需要钥匙串授权。');
}

class AiConfigStore {
  static const channel = MethodChannel('dev.pyvis.ai.credentials');
  final bool cacheForSession;
  Future<AiProfiles>? _sessionProfiles;
  AiConfigStore({this.cacheForSession = false});

  static File? get publicConfigFile {
    if (Platform.environment['FLUTTER_TEST'] == 'true') return null;
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null) return null;
    final support = Platform.isMacOS
        ? '$home/Library/Application Support'
        : Platform.environment['APPDATA'] ?? '$home/.local/share';
    return File('$support/Pyvis/model-settings.json');
  }

  Future<AiProfiles?> loadModelCatalog() async {
    final file = publicConfigFile;
    if (file == null) return null;
    try {
      final data = jsonDecode(await file.readAsString()) as Map;
      if (data['version'] != 1) return null;
      final profiles = [
        for (final entry in data['profiles'] as List)
          AiProfile(
              entry['id'] as String,
              entry['name'] as String,
              entry['provider'] as String,
              AiConfig('', entry['defaultModelId'] as String, ''),
              modelIds:
                  (entry['modelIds'] as List).whereType<String>().toList()),
      ];
      if (profiles.map((p) => p.id).toSet().length != profiles.length) {
        return null;
      }
      final result = AiProfiles(profiles, data['activeProfileId'] as String?);
      return profiles.isEmpty || result.active != null ? result : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _refreshModelCatalog(AiProfiles settings) async {
    final file = publicConfigFile;
    if (file == null) return;
    try {
      await writePublicConfig(file, settings);
    } on FileSystemException {
      // The secure configuration remains usable when the snapshot cannot be written.
    }
  }

  Future<AiProfiles> _readAndRefresh(bool allowInteraction) async {
    final settings = await _readProfiles(allowInteraction);
    await _refreshModelCatalog(settings);
    return settings;
  }

  Future<AiProfiles> loadProfiles({bool allowInteraction = true}) async {
    if (!cacheForSession) return _readAndRefresh(allowInteraction);
    final read = _sessionProfiles ??= _readAndRefresh(allowInteraction);
    try {
      return await read;
    } catch (_) {
      if (identical(read, _sessionProfiles)) _sessionProfiles = null;
      rethrow;
    }
  }

  Future<AiProfiles> _readProfiles(bool allowInteraction) async {
    try {
      final raw = await channel.invokeMethod<String>('load', allowInteraction);
      if (raw == null) return const AiProfiles([], null);
      final data = jsonDecode(raw) as Map;
      if (data['version'] == 2) {
        final profiles = (data['profiles'] as List)
            .map((p) => AiProfile.fromJson(p as Map))
            .toList();
        return AiProfiles(profiles, data['activeId'] as String?);
      }
      // Migrate the original single configuration without losing its key.
      return AiProfiles([
        AiProfile(
            'legacy',
            '原有配置',
            'custom',
            AiConfig(data['endpoint'] as String, data['model'] as String,
                data['key'] as String))
      ], 'legacy');
    } on PlatformException catch (error) {
      if (error.code == 'keychain_locked') throw const AiKeychainLocked();
      throw const AiFailure('无法读取本机模型凭据，请检查应用数据目录权限。');
    } catch (_) {
      throw const AiFailure('无法读取本机模型凭据，请检查应用数据目录权限。');
    }
  }

  /// Writes a readable snapshot. The secure store remains the canonical source.
  Future<String> writePublicConfig(File file, AiProfiles settings) async {
    final data = {
      'version': 1,
      'activeProfileId': settings.activeId,
      'profiles': [
        for (final profile in settings.profiles)
          {
            'id': profile.id,
            'name': profile.name,
            'provider': profile.provider,
            if (profile.customId.isNotEmpty) 'customId': profile.customId,
            'endpoint': profile.config.endpoint,
            'protocol': profile.config.protocol.name,
            'defaultModelId': profile.config.model,
            'modelIds': profile.modelIds,
          },
      ],
    };
    final contents = '${const JsonEncoder.withIndent('  ').convert(data)}\n';
    final temp = await file.parent
        .create(recursive: true)
        .then((directory) => directory.createTemp('.ai-config-'));
    try {
      final draft = File('${temp.path}/model-settings.json');
      await draft.writeAsString(contents, flush: true);
      await draft.rename(file.path);
    } finally {
      await temp.delete(recursive: true);
    }
    return contents;
  }

  Future<AiConfig?> load() async => (await loadProfiles()).active?.config;
  Future<void> saveProfiles(AiProfiles settings) async {
    for (final p in settings.profiles) {
      p.config.validate();
    }
    if (settings.profiles.isNotEmpty && settings.active == null) {
      throw const AiFailure('请选择当前使用的服务商。');
    }
    try {
      await channel.invokeMethod('save', jsonEncode(settings.toJson()));
      if (cacheForSession) _sessionProfiles = Future.value(settings);
    } catch (_) {
      throw const AiFailure('无法保存本机模型凭据，请检查应用数据目录权限。');
    }
    await _refreshModelCatalog(settings);
  }

  Future<void> save(AiConfig config) async {
    final settings = await loadProfiles();
    final current =
        settings.active ?? AiProfile('default', '自定义服务', 'custom', config);
    await saveProfiles(AiProfiles([
      for (final p in settings.profiles)
        if (p.id != current.id) p,
      AiProfile(current.id, current.name, current.provider, config,
          customId: current.customId, modelIds: current.modelIds),
    ], current.id));
  }
}

class AiRequest {
  final Duration timeout;
  HttpClient? _client;
  final _cancel = Completer<Never>();
  AiRequest({this.timeout = const Duration(seconds: 45)});
  void cancel() {
    if (!_cancel.isCompleted) {
      _cancel.completeError(const AiFailure('已取消，可以重新提问。'));
    }
    _client?.close(force: true);
  }

  Future<List<String>> listModels(AiConfig config) async {
    config.validate(requireModel: false);
    try {
      return await Future.any<List<String>>(
          [_listModels(config), _cancel.future]).timeout(timeout);
    } on AiFailure {
      rethrow;
    } on TimeoutException {
      throw const AiFailure('获取模型列表超时，可重试或手动填写模型名。');
    } catch (_) {
      throw const AiFailure('无法获取模型列表，请检查服务地址；也可以手动填写模型名。');
    } finally {
      _client?.close(force: true);
    }
  }

  void authenticate(HttpClientRequest request, AiConfig config) {
    request.followRedirects = false;
    switch (config.protocol) {
      case AiProtocol.anthropic:
        request.headers.set('x-api-key', config.key);
        request.headers.set('anthropic-version', '2023-06-01');
      case AiProtocol.gemini:
        request.headers.set('x-goog-api-key', config.key);
      case AiProtocol.chat:
      case AiProtocol.responses:
        request.headers
            .set(HttpHeaders.authorizationHeader, 'Bearer ${config.key}');
    }
  }

  Future<List<String>> _listModels(AiConfig config) async {
    final client = _client = HttpClient();
    final models = <String>{};
    final cursors = <String>{};
    String? cursor;
    for (var page = 0; page < 100; page++) {
      final query = <String, String>{
        if (config.protocol == AiProtocol.anthropic) 'limit': '100',
        if (config.protocol == AiProtocol.gemini) 'pageSize': '1000',
        if (cursor != null)
          config.protocol == AiProtocol.gemini ? 'pageToken' : 'after_id':
              cursor,
      };
      final request = await client.getUrl(config.modelsUri
          .replace(queryParameters: query.isEmpty ? null : query));
      authenticate(request, config);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw AiFailure(switch (response.statusCode) {
          401 || 403 => '验证失败，请检查 API Key 和模型列表访问权限。',
          429 => '获取模型列表受到限流，请稍后重试。',
          _ => '服务未提供可用的模型列表，可重试或手动填写模型名。',
        });
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > 4 * 1024 * 1024) {
          throw const AiFailure('模型列表过大，请手动填写模型名。');
        }
      }
      final json = jsonDecode(utf8.decode(bytes)) as Map;
      final data =
          json[config.protocol == AiProtocol.gemini ? 'models' : 'data'];
      if (data is! List) {
        throw const AiFailure('模型列表格式不兼容，请手动填写模型名。');
      }
      for (final item in data.whereType<Map>()) {
        if (config.protocol == AiProtocol.gemini &&
            !(item['supportedGenerationMethods'] as List? ?? [])
                .contains('generateContent')) {
          continue;
        }
        final id = item[config.protocol == AiProtocol.gemini ? 'name' : 'id'];
        if (id is String && id.trim().isNotEmpty && !id.contains(config.key)) {
          models.add(id);
        }
      }
      cursor = config.protocol == AiProtocol.gemini
          ? json['nextPageToken'] as String?
          : config.protocol == AiProtocol.anthropic && json['has_more'] == true
              ? json['last_id'] as String?
              : null;
      if (config.protocol == AiProtocol.anthropic &&
          json['has_more'] == true &&
          (cursor == null || cursor.isEmpty)) {
        throw const AiFailure('模型分页信息不完整，请重试或手动填写。');
      }
      if (cursor == null || cursor.isEmpty) {
        if (models.isEmpty) throw const AiFailure('服务未返回可用模型，可手动填写模型名。');
        return models.toList()..sort();
      }
      if (!cursors.add(cursor)) throw const AiFailure('服务返回重复分页，请手动填写模型名。');
    }
    throw const AiFailure('模型列表页数过多，请手动填写模型名。');
  }

  Future<String> send(
      AiConfig config, String question, Map<String, String> attachments,
      {void Function(String)? onText}) async {
    config.validate();
    try {
      return await Future.any([
        _send(config, question, attachments, onText: onText),
        _cancel.future
      ]);
    } on AiFailure {
      rethrow;
    } on TimeoutException {
      throw const AiFailure('请求超时，请稍后重试。');
    } catch (_) {
      throw const AiFailure('连接失败或响应格式无效，请检查服务地址和网络。');
    } finally {
      _client?.close(force: true);
    }
  }

  Future<String> _send(
      AiConfig config, String question, Map<String, String> attachments,
      {void Function(String)? onText}) async {
    final client = _client = HttpClient();
    final stream = onText != null;
    final uri = stream && config.protocol == AiProtocol.gemini
        ? config.uri.replace(
            path: config.uri.path.replaceFirst(
                RegExp(r':generateContent$'), ':streamGenerateContent'),
            queryParameters: {'alt': 'sse'})
        : config.uri;
    final request = await client.postUrl(uri).timeout(timeout);
    if (stream) {
      request.headers.set('Accept', 'text/event-stream, application/json');
    }
    authenticate(request, config);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(aiPayload(config.protocol, config.model.trim(),
        jsonEncode({'问题': question, '主动附带的上下文': attachments}),
        stream: stream)));
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200) {
      throw AiFailure(switch (response.statusCode) {
        401 || 403 => '验证失败，请检查 API Key 和访问权限。',
        404 => '模型或接口不可用，请检查服务地址和模型名。',
        429 => '请求受到限流或额度不足，请稍后重试或检查服务额度。',
        >= 500 => '模型服务暂时不可用，请稍后重试。',
        _ => '服务拒绝请求，请检查模型配置。',
      });
    }
    var size = 0;
    final body = response.timeout(timeout).map((chunk) {
      size += chunk.length;
      if (size > 2 * 1024 * 1024) throw const AiFailure('回复过长，请缩小问题范围后重试。');
      return chunk;
    });
    if (onText != null &&
        response.headers.contentType?.mimeType == 'text/event-stream') {
      return _streamAnswer(body, config, onText);
    }
    final bytes = await body.expand((chunk) => chunk).toList();
    final data = jsonDecode(utf8.decode(bytes));
    final answer = aiAnswer(config.protocol, data as Map);
    if (answer.trim().isEmpty) {
      throw const AiFailure('模型未返回文字，请检查模型是否支持问答。');
    }
    return answer.replaceAll(config.key, '[凭据已隐藏]');
  }

  Future<String> _streamAnswer(Stream<List<int>> body, AiConfig config,
      void Function(String) onText) async {
    final fields = <String>[];
    final answer = StringBuffer();
    var pending = '';
    var finished = false;
    void publish(String delta, {bool flush = false}) {
      pending = (pending + delta).replaceAll(config.key, '[凭据已隐藏]');
      var end = pending.length;
      if (!flush) {
        // Hold a possible credential prefix across network events.
        for (var i = pending.length < config.key.length
                ? 0
                : pending.length - config.key.length + 1;
            i < pending.length;
            i++) {
          if (config.key.startsWith(pending.substring(i))) {
            end = i;
            break;
          }
        }
      }
      if (end > 0) {
        final safe = pending.substring(0, end);
        answer.write(safe);
        if (!_cancel.isCompleted) onText(safe);
        pending = pending.substring(end);
      }
    }

    await for (final line
        in body.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.startsWith('data:')) {
        fields.add(line.substring(5).trimLeft());
        continue;
      }
      if (line.isNotEmpty || fields.isEmpty) continue;
      final payload = fields.join('\n');
      fields.clear();
      if (payload == '[DONE]') {
        finished = true;
        break;
      }
      final event = jsonDecode(payload) as Map;
      final type = event['type'];
      if (event['error'] != null ||
          type == 'error' ||
          type == 'response.failed' ||
          type == 'response.incomplete') {
        throw const AiFailure('模型服务中断了回复，可重新提问。');
      }
      String? delta;
      switch (config.protocol) {
        case AiProtocol.chat:
          final choice = (event['choices'] as List?)?.firstOrNull;
          delta = choice?['delta']?['content'] as String?;
          finished |= choice?['finish_reason'] != null;
        case AiProtocol.responses:
          if (type == 'response.output_text.delta') {
            delta = event['delta'] as String?;
          }
          finished = type == 'response.completed';
        case AiProtocol.anthropic:
          if (type == 'content_block_delta' &&
              event['delta']?['type'] == 'text_delta') {
            delta = event['delta']['text'] as String?;
          }
          finished = type == 'message_stop';
        case AiProtocol.gemini:
          delta = aiAnswer(config.protocol, event);
          finished =
              (event['candidates'] as List?)?.firstOrNull?['finishReason'] !=
                  null;
      }
      if (delta != null && delta.isNotEmpty) publish(delta);
      if (finished) break;
    }
    if (!finished) throw const AiFailure('连接提前结束，已保留收到的回复。');
    publish('', flush: true);
    if (answer.toString().trim().isEmpty) {
      throw const AiFailure('模型未返回文字，请检查模型是否支持问答。');
    }
    return answer.toString();
  }
}

class AiMessage {
  final bool user;
  final String text;
  final Map<String, String> attachments;
  AiMessage(this.user, this.text, [this.attachments = const {}]);
}
