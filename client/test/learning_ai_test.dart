import 'dart:async';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyvis_editor/learning_ai.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('secure configuration round trip', () async {
    String? saved;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AiConfigStore.channel, (call) async {
      if (call.method == 'save') {
        saved = call.arguments as String;
        return null;
      }
      return saved;
    });
    final store = AiConfigStore();
    expect(await store.load(), isNull);
    await store
        .save(const AiConfig('https://example.com/v1', 'mock', 'test-secret'));
    expect((await store.load())!.key, 'test-secret');
    final directory =
        await Directory.systemTemp.createTemp('pyvis-model-settings-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/model-settings.json');
    await store.writePublicConfig(file, await store.loadProfiles());
    final contents = await file.readAsString();
    final config = jsonDecode(contents) as Map;
    expect(config['activeProfileId'], 'default');
    expect(config['profiles'][0]['modelIds'], ['mock']);
    expect(config['profiles'][0]['endpoint'], 'https://example.com/v1');
    expect(config['profiles'][0].containsKey('key'), isFalse);
    expect(contents, isNot(contains('test-secret')));
    await store.save(
        const AiConfig('https://example.com/v1', 'new-model', 'test-secret'));
    await store.writePublicConfig(file, await store.loadProfiles());
    expect(await file.readAsString(), contains('new-model'));
  });
  test('session reuses authorized reads and retries a denied read', () async {
    var reads = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AiConfigStore.channel, (call) async {
      if (call.method == 'save') return null;
      reads++;
      if (reads == 1) throw PlatformException(code: 'denied');
      return jsonEncode(
          const AiConfig('https://example.com/v1', 'before', 'test-key')
              .toJson());
    });
    final store = AiConfigStore(cacheForSession: true);
    await expectLater(store.loadProfiles(), throwsA(isA<AiFailure>()));
    await Future.wait([store.loadProfiles(), store.loadProfiles()]);
    expect(reads, 2);
    final snapshot = await store.loadProfiles();
    final directory =
        await Directory.systemTemp.createTemp('pyvis-config-preview-');
    addTearDown(() => directory.delete(recursive: true));
    await store.writePublicConfig(
        File('${directory.path}/model-settings.json'), snapshot);
    expect(reads, 2);
    await store
        .save(const AiConfig('https://example.com/v1', 'after', 'test-key'));
    expect((await store.load())!.model, 'after');
    expect(reads, 2);
  });
  test(
      'migrates legacy and preserves independent provider keys and active selection',
      () async {
    String? raw = jsonEncode(
        const AiConfig('https://old.example/v1', 'old', 'old-key').toJson());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AiConfigStore.channel, (call) async {
      if (call.method == 'save') {
        raw = call.arguments as String;
        return null;
      }
      return raw;
    });
    final store = AiConfigStore();
    final legacy = await store.loadProfiles();
    expect(legacy.active!.config.key, 'old-key');
    final second = AiProfile(
        'second',
        '官方测试',
        'openai',
        const AiConfig(
            'https://api.openai.com/v1', 'second-model', 'second-key'));
    await store
        .saveProfiles(AiProfiles([...legacy.profiles, second], 'second'));
    expect((await store.load())!.key, 'second-key');
    final all = await store.loadProfiles();
    await store.saveProfiles(AiProfiles(all.profiles, 'legacy'));
    expect((await store.load())!.model, 'old');
    expect((await store.loadProfiles()).profiles.last.config.key, 'second-key');
  });
  test('fetches model list without model name, handles errors and cancellation',
      () async {
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var code = 200;
    var delay = false;
    Object body = {
      'data': [
        {'id': 'z'},
        {'id': 'a'},
        {'id': 'a'}
      ]
    };
    server.listen((r) async {
      expect(r.method, 'GET');
      expect(r.uri.path, '/v1/models');
      expect(r.headers.value('authorization'), 'Bearer list-key');
      expect(await utf8.decoder.bind(r).join(), isEmpty);
      if (delay) return;
      r.response.statusCode = code;
      r.response.write(jsonEncode(body));
      await r.response.close();
    });
    final config = AiConfig(
        'http://127.0.0.1:${server.port}/v1/chat/completions', '', 'list-key');
    expect(await AiRequest().listModels(config), ['a', 'z']);
    for (final status in [401, 404, 429, 500, 302]) {
      code = status;
      await expectLater(
          AiRequest().listModels(config), throwsA(isA<AiFailure>()));
    }
    code = 200;
    for (final invalid in [
      {'data': []},
      {'wrong': []}
    ]) {
      body = invalid;
      await expectLater(
          AiRequest().listModels(config), throwsA(isA<AiFailure>()));
    }
    delay = true;
    await expectLater(
        AiRequest(timeout: const Duration(milliseconds: 50)).listModels(config),
        throwsA(isA<AiFailure>()));
    final request = AiRequest();
    final check = expectLater(
        request.listModels(config),
        throwsA(isA<AiFailure>()
            .having((e) => e.message, 'cancel', contains('取消'))));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    request.cancel();
    await check;
    delay = false;
    body = {
      'data': [
        {'id': 'recovered'}
      ]
    };
    expect(await AiRequest().listModels(config), ['recovered']);
  });
  for (final protocol in AiProtocol.values) {
    test(
        'streams ${protocol.name} before completion and masks split credentials',
        () async {
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final release = Completer<void>();
      final first = Completer<String>();
      server.listen((r) async {
        final payload = jsonDecode(await utf8.decoder.bind(r).join());
        if (protocol == AiProtocol.gemini) {
          expect(r.uri.path, endsWith(':streamGenerateContent'));
          expect(r.uri.queryParameters['alt'], 'sse');
        } else {
          expect(payload['stream'], true);
        }
        final out = r.response;
        out.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        out.bufferOutput = false;
        void emit(String value) {
          final event = switch (protocol) {
            AiProtocol.chat => {
                'choices': [
                  {
                    'delta': {'content': value}
                  }
                ]
              },
            AiProtocol.responses => {
                'type': 'response.output_text.delta',
                'delta': value
              },
            AiProtocol.anthropic => {
                'type': 'content_block_delta',
                'delta': {'type': 'text_delta', 'text': value}
              },
            AiProtocol.gemini => {
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': value}
                      ]
                    }
                  }
                ]
              },
          };
          out.write('data: ${jsonEncode(event)}\r\n\r\n');
        }

        emit('第一段abc');
        await out.flush();
        await release.future;
        emit('123第二段');
        final end = switch (protocol) {
          AiProtocol.chat => '[DONE]',
          AiProtocol.responses => '{"type":"response.completed"}',
          AiProtocol.anthropic => '{"type":"message_stop"}',
          AiProtocol.gemini => '{"candidates":[{"finishReason":"STOP"}]}',
        };
        out.write('data: $end\n\n');
        await out.close();
      });
      final config = AiConfig(
          'http://127.0.0.1:${server.port}/v1', 'mock', 'abc123',
          protocol: protocol);
      final chunks = <String>[];
      final response = AiRequest().send(config, '解释', {}, onText: (value) {
        chunks.add(value);
        if (!first.isCompleted) first.complete(value);
      });
      try {
        expect(await first.future.timeout(const Duration(seconds: 3)), '第一段');
      } finally {
        release.complete();
      }
      expect(await response, '第一段[凭据已隐藏]第二段');
      expect(chunks.join(), '第一段[凭据已隐藏]第二段');
    });
  }
  test('reject unsafe addresses', () {
    for (final url in [
      'http://example.com',
      'https://key@example.com',
      'https://example.com?key=x'
    ]) {
      expect(() => AiConfig(url, 'model', 'key').validate(),
          throwsA(isA<AiFailure>()));
    }
  });
  test('local requests, response, errors, timeout, cancellation and recovery',
      () async {
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = <Map>[];
    var status = 200;
    var delay = false;
    server.listen((r) async {
      expect(r.uri.path, '/v1/chat/completions');
      expect(r.headers.value('authorization'), 'Bearer test-secret');
      received.add(jsonDecode(await utf8.decoder.bind(r).join()) as Map);
      if (delay) return;
      r.response.statusCode = status;
      r.response.write(jsonEncode(status == 200
          ? {
              'choices': [
                {
                  'message': {'content': '解释 test-secret'}
                }
              ]
            }
          : {'error': 'test-secret'}));
      await r.response.close();
    });
    final config =
        AiConfig('http://127.0.0.1:${server.port}/v1', 'mock', 'test-secret');
    expect(
        await AiRequest()
            .send(config.withModel('alternate'), '为什么', {'选中代码': 'x = 1'}),
        '解释 [凭据已隐藏]');
    expect(received.single['model'], 'alternate');
    expect(received.single.containsKey('tools'), false);
    expect(received.single['stream'], false);
    expect((received.single['messages'] as List).length, 2);
    expect(jsonDecode(received.single['messages'][1]['content'])['主动附带的上下文'],
        {'选中代码': 'x = 1'});
    for (final code in [401, 403, 404, 429, 500, 302]) {
      status = code;
      await expectLater(
          AiRequest().send(config, '问题', {}),
          throwsA(isA<AiFailure>().having(
              (e) => e.message.contains('test-secret'), 'no key', false)));
    }
    delay = true;
    await expectLater(
        AiRequest(timeout: const Duration(milliseconds: 80))
            .send(config, '超时', {}),
        throwsA(isA<AiFailure>()
            .having((e) => e.message, 'timeout', contains('超时'))));
    final request = AiRequest();
    final future = request.send(config, '取消', {});
    final check = expectLater(
        future,
        throwsA(isA<AiFailure>()
            .having((e) => e.message, 'cancel', contains('取消'))));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    request.cancel();
    await check;
    delay = false;
    status = 200;
    expect(await AiRequest().send(config, '恢复', {}), contains('解释'));
    expect(jsonDecode(received.last['messages'][1]['content'])['主动附带的上下文'],
        isEmpty);
  });
}
