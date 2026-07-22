import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/api/worker_http.dart';
import 'package:omi/auth/auth.dart';

WorkerHttpClient _client(http.Response Function() respond) => WorkerHttpClient(
  baseUri: Uri.parse('https://api.example.test'),
  sessionProvider: () async => AuthSession(
    uid: 'user-1',
    idToken: 'firebase-token',
    expiresAt: DateTime.now().add(const Duration(minutes: 5)),
  ),
  client: MockClient((_) async => respond()),
);

void main() {
  test('voice client decodes a valid Gemini live token grant', () async {
    http.Request? seen;
    final client = WorkerHttpClient(
      baseUri: Uri.parse('https://api.example.test'),
      sessionProvider: () async => AuthSession(
        uid: 'user-1',
        idToken: 'firebase-token',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      ),
      client: MockClient((request) async {
        seen = request;
        return http.Response(
          '{"token":"auth_tokens/abc123","model":"gemini-live",'
          '"expireTime":"2030-01-01T00:30:00Z",'
          '"newSessionExpireTime":"2030-01-01T00:01:00Z"}',
          200,
        );
      }),
    );

    final grant = await WorkerVoiceClient(client).createGeminiToken();

    expect(seen!.method, 'POST');
    expect(seen!.url.path, '/v1/voice/gemini/token');
    expect(grant.token, 'auth_tokens/abc123');
    expect(grant.model, 'gemini-live');
    expect(grant.expireTime, DateTime.utc(2030, 1, 1, 0, 30));
    expect(grant.newSessionExpireTime, DateTime.utc(2030, 1, 1, 0, 1));
    client.close();
  });

  test('voice client rejects malformed or unsafe token grants', () async {
    final bodies = [
      '{"error":"Live voice unavailable"}',
      '{"token":"","model":"gemini-live","expireTime":"2030-01-01T00:30:00Z",'
          '"newSessionExpireTime":"2030-01-01T00:01:00Z"}',
      '{"token":"auth_tokens/a b","model":"gemini-live",'
          '"expireTime":"2030-01-01T00:30:00Z",'
          '"newSessionExpireTime":"2030-01-01T00:01:00Z"}',
      '{"token":"auth_tokens/abc","model":"gemini-live",'
          '"expireTime":"not-a-date",'
          '"newSessionExpireTime":"2030-01-01T00:01:00Z"}',
      '{"token":"auth_tokens/abc","model":"gemini-live",'
          '"expireTime":"2030-01-01T00:30:00Z",'
          '"newSessionExpireTime":"2030-01-01T00:01:00Z","extra":true}',
    ];
    for (final (index, body) in bodies.indexed) {
      final client = _client(() => http.Response(body, index == 0 ? 503 : 200));
      await expectLater(
        WorkerVoiceClient(client).createGeminiToken(),
        throwsA(isA<WorkerResponseException>()),
      );
      client.close();
    }
  });

  test('voice client surfaces the worker error message', () async {
    final client = _client(
      () => http.Response('{"error":"Live voice unavailable"}', 503),
    );
    await expectLater(
      WorkerVoiceClient(client).createGeminiToken(),
      throwsA(
        isA<WorkerResponseException>().having(
          (error) => error.message,
          'message',
          'Live voice unavailable',
        ),
      ),
    );
    client.close();
  });
}
