import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/api/api_keys_client.dart';
import 'package:omi/api/facetime_client.dart';
import 'package:omi/api/worker_http.dart';
import 'package:omi/auth/auth.dart';

WorkerHttpClient _client(
  Future<http.Response> Function(http.Request request) respond,
) => WorkerHttpClient(
  baseUri: Uri.parse('https://api.example.test'),
  sessionProvider: () async => AuthSession(
    uid: 'user-1',
    idToken: 'firebase-token',
    expiresAt: DateTime.now().add(const Duration(minutes: 5)),
  ),
  client: MockClient(respond),
);

void main() {
  test(
    'creating a key posts the scopes and returns the plaintext once',
    () async {
      http.Request? seen;
      final client = _client((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'key': 'omi_sk_1f3c9ab2_secret',
            'apiKey': {
              'id': 'b3f1',
              'name': 'laptop-mcp',
              'prefix': 'omi_sk_1f3c9ab2',
              'scopes': ['memory:read', 'unknown:scope'],
              'createdAt': 1761177600000,
              'lastUsedAt': null,
              'expiresAt': null,
              'revokedAt': null,
            },
          }),
          201,
        );
      });

      final minted = await WorkerApiKeysClient(client).createKey(
        name: '  laptop-mcp ',
        scopes: const [ApiKeyScope.memoryRead, ApiKeyScope.currentsWrite],
      );

      expect(seen!.method, 'POST');
      expect(seen!.url.path, '/v1/api-keys');
      expect(jsonDecode(seen!.body), {
        'name': 'laptop-mcp',
        'scopes': ['memory:read', 'currents:write'],
      });
      expect(minted.plaintext, 'omi_sk_1f3c9ab2_secret');
      expect(minted.summary.prefix, 'omi_sk_1f3c9ab2');
      // Unknown scopes from a newer worker are dropped, never guessed at.
      expect(minted.summary.scopes, [ApiKeyScope.memoryRead]);
      client.close();
    },
  );

  test('a rejected key request keeps the worker message', () async {
    final client = _client(
      (_) async => http.Response('{"error":"API key limit reached"}', 409),
    );

    await expectLater(
      WorkerApiKeysClient(
        client,
      ).createKey(name: 'x', scopes: const [ApiKeyScope.memoryRead]),
      throwsA(
        isA<WorkerResponseException>().having(
          (error) => error.message,
          'message',
          'API key limit reached',
        ),
      ),
    );
    client.close();
  });

  test('revoking a key deletes it by id and surfaces a miss', () async {
    http.Request? seen;
    final ok = _client((request) async {
      seen = request;
      return http.Response('', 204);
    });
    await WorkerApiKeysClient(ok).revokeKey('b3f1');
    expect(seen!.method, 'DELETE');
    expect(seen!.url.path, '/v1/api-keys/b3f1');
    ok.close();

    final missing = _client(
      (_) async => http.Response('{"error":"API key not found"}', 404),
    );
    await expectLater(
      WorkerApiKeysClient(missing).revokeKey('gone'),
      throwsA(isA<WorkerResponseException>()),
    );
    missing.close();
  });

  test('the FaceTime provider switch is its own state, not an error', () async {
    final client = _client(
      (_) async => http.Response(
        '{"error":"FaceTime calling is not yet available from Blooio",'
        '"code":"facetime_unavailable"}',
        503,
      ),
    );

    await expectLater(
      WorkerFaceTimeClient(client).placeCall(handle: '+15551234567'),
      throwsA(isA<FaceTimeUnavailableException>()),
    );
    client.close();
  });

  test('a FaceTime provider fault stays an error', () async {
    final client = _client(
      (_) async =>
          http.Response('{"error":"FaceTime calling unavailable"}', 502),
    );

    await expectLater(
      WorkerFaceTimeClient(client).placeCall(handle: '+15551234567'),
      throwsA(isA<WorkerResponseException>()),
    );
    client.close();
  });

  test('a placed call decodes its link and rejects an unsafe one', () async {
    http.Request? seen;
    final ok = _client((request) async {
      seen = request;
      return http.Response(
        '{"call":{"handle":"+15551234567",'
        '"link":"https://facetime.apple.com/join#v=1"}}',
        201,
      );
    });
    final call = await WorkerFaceTimeClient(
      ok,
    ).placeCall(handle: '+15551234567', idempotencyKey: 'omi:call:001');
    expect(seen!.url.path, '/api/v1/facetime/calls');
    expect(jsonDecode(seen!.body), {
      'handle': '+15551234567',
      'idempotencyKey': 'omi:call:001',
    });
    expect(call.link, 'https://facetime.apple.com/join#v=1');
    ok.close();

    final unsafe = _client(
      (_) async => http.Response(
        '{"call":{"handle":"+1","link":"javascript:alert(1)"}}',
        201,
      ),
    );
    await expectLater(
      WorkerFaceTimeClient(unsafe).placeCall(handle: '+15551234567'),
      throwsA(isA<WorkerResponseException>()),
    );
    unsafe.close();
  });
}
