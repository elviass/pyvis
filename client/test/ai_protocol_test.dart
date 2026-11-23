import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyvis_editor/learning_ai.dart';

void main() {
  for (final protocol in AiProtocol.values) {
    test(
        '${protocol.name} authenticates, sends only supplied context and extracts text',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) async {
        expect(r.uri.queryParameters.containsKey('key'), false);
        if (protocol == AiProtocol.anthropic) {
          expect(r.headers.value('x-api-key'), 'test-secret');
          expect(r.headers.value('anthropic-version'), '2023-06-01');
          expect(r.headers.value('authorization'), isNull);
        } else if (protocol == AiProtocol.gemini) {
          expect(r.headers.value('x-goog-api-key'), 'test-secret');
          expect(r.headers.value('authorization'), isNull);
        } else {
          expect(r.headers.value('authorization'), 'Bearer test-secret');
        }
        final body = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
        expect(body.containsKey('tools'), false);
        expect(body.containsKey('previous_response_id'), false);
        dynamic user;
        Object response;
        switch (protocol) {
          case AiProtocol.chat:
            expect(r.uri.path, '/v1/chat/completions');
            expect(body['messages'].length, 2);
            user = body['messages'][1]['content'];
            response = {
              'choices': [
                {
                  'message': {'content': '回答 test-secret'}
                }
              ]
            };
          case AiProtocol.responses:
            expect(r.uri.path, '/v1/responses');
            expect(body['store'], false);
            user = body['input'];
            response = {
              'status': 'completed',
              'output': [
                {
                  'type': 'reasoning',
                  'content': [
                    {'type': 'output_text', 'text': 'hidden'}
                  ]
                },
                {
                  'type': 'message',
                  'content': [
                    {'type': 'output_text', 'text': '回答 test-secret'}
                  ]
                }
              ]
            };
          case AiProtocol.anthropic:
            expect(r.uri.path, '/v1/messages');
            expect(body['max_tokens'], 4096);
            expect(body['messages'].length, 1);
            user = body['messages'][0]['content'];
            response = {
              'content': [
                {'type': 'thinking', 'thinking': 'hidden'},
                {'type': 'text', 'text': '回答 test-secret'}
              ]
            };
          case AiProtocol.gemini:
            expect(r.uri.path, '/v1/models/gemini-test:generateContent');
            expect(body['contents'].length, 1);
            user = body['contents'][0]['parts'][0]['text'];
            response = {
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'thought': true, 'text': 'hidden'},
                      {'text': '回答 test-secret'}
                    ]
                  }
                }
              ]
            };
        }
        expect(jsonDecode(user)['主动附带的上下文'], {'代码': 'x=1'});
        r.response.write(jsonEncode(response));
        await r.response.close();
      });
      final config = AiConfig(
          'http://127.0.0.1:${server.port}/v1', 'gemini-test', 'test-secret',
          protocol: protocol);
      expect(await AiRequest().send(config, '解释', {'代码': 'x=1'}), '回答 [凭据已隐藏]');
      final restored = AiProfile.fromJson(
          AiProfile('id', 'name', 'custom', config).toJson());
      expect(restored.config.protocol, protocol);
    });
  }
  for (final protocol in [AiProtocol.anthropic, AiProtocol.gemini]) {
    test('${protocol.name} model pagination and Gemini capability filter',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var pages = 0;
      server.listen((r) async {
        pages++;
        expect(r.uri.path, '/v1/models');
        final first = pages == 1;
        final Object response;
        if (protocol == AiProtocol.gemini) {
          expect(r.headers.value('x-goog-api-key'), 'test-secret');
          if (!first) expect(r.uri.queryParameters['pageToken'], 'next');
          response = {
            'models': [
              {
                'name': first ? 'models/a' : 'models/b',
                'supportedGenerationMethods': ['generateContent']
              },
              {
                'name': 'models/embedding',
                'supportedGenerationMethods': ['embedContent']
              }
            ],
            if (first) 'nextPageToken': 'next'
          };
        } else {
          expect(r.headers.value('x-api-key'), 'test-secret');
          if (!first) expect(r.uri.queryParameters['after_id'], 'a');
          response = {
            'data': [
              {'id': first ? 'a' : 'b'}
            ],
            'has_more': first,
            'last_id': first ? 'a' : 'b'
          };
        }
        r.response.write(jsonEncode(response));
        await r.response.close();
      });
      final result = await AiRequest().listModels(AiConfig(
          'http://127.0.0.1:${server.port}/v1', '', 'test-secret',
          protocol: protocol));
      expect(
          result,
          protocol == AiProtocol.gemini
              ? ['models/a', 'models/b']
              : ['a', 'b']);
      expect(pages, 2);
    });
  }
  test('Gemini model cannot change request path', () {
    expect(
        () => const AiConfig('https://example.com/v1beta', '../../evil', 'key',
                protocol: AiProtocol.gemini)
            .validate(),
        throwsA(isA<AiFailure>()));
  });
}
