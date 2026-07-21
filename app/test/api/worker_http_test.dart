import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/api/worker_http.dart';
import 'package:omi/auth/auth.dart';

void main() {
  test(
    'billing decodes entitlement and accepts only safe session URLs',
    () async {
      var request = 0;
      final client = WorkerHttpClient(
        baseUri: Uri.parse('https://api.example.test'),
        sessionProvider: () async => AuthSession(
          uid: 'user-1',
          idToken: 'firebase-token',
          expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        ),
        client: MockClient((_) async {
          request += 1;
          return request == 1
              ? http.Response('{"plan":"pro","active":true}', 200)
              : http.Response(
                  '{"id":"session-1","url":"https://checkout.stripe.com/session-1"}',
                  201,
                );
        }),
      );
      final billing = WorkerBillingClient(client);

      final entitlement = await billing.getEntitlement();
      final portal = await billing.createPortal();

      expect(entitlement.plan, OmiPlan.pro);
      expect(entitlement.active, isTrue);
      expect(portal.host, 'checkout.stripe.com');
      client.close();
    },
  );

  test('billing rejects an unsafe session URL', () async {
    final client = WorkerHttpClient(
      baseUri: Uri.parse('https://api.example.test'),
      sessionProvider: () async => AuthSession(
        uid: 'user-1',
        idToken: 'firebase-token',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      ),
      client: MockClient(
        (_) async => http.Response(
          '{"id":"session-1","url":"javascript:alert(1)"}',
          201,
        ),
      ),
    );

    await expectLater(
      WorkerBillingClient(client).createCheckout(),
      throwsA(isA<WorkerResponseException>()),
    );
    client.close();
  });

  test('sends the AuthSession token and JSON to the Worker', () async {
    late http.BaseRequest captured;
    final client = WorkerHttpClient(
      baseUri: Uri.parse('https://api.example.test'),
      sessionProvider: () async => AuthSession(
        uid: 'user-1',
        idToken: 'firebase-token',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      ),
      client: MockClient.streaming((request, bodyStream) async {
        captured = request;
        final body = await bodyStream.bytesToString();
        expect(jsonDecode(body), {'enabled': true});
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"ok":true}')),
          200,
        );
      }),
    );

    final response = await client.send(
      method: 'PUT',
      path: '/v1/settings',
      query: const {'scope': 'task'},
      body: const {'enabled': true},
    );

    expect(captured.headers['authorization'], 'Bearer firebase-token');
    expect(
      captured.url.toString(),
      'https://api.example.test/v1/settings?scope=task',
    );
    expect(response.body, {'ok': true});
    client.close();
  });

  test('does not send a request without an AuthSession', () async {
    final client = WorkerHttpClient(
      baseUri: Uri.parse('https://api.example.test'),
      sessionProvider: () async => null,
      client: MockClient((_) async => http.Response('{}', 200)),
    );

    await expectLater(
      client.send(method: 'GET', path: '/v1/me'),
      throwsA(isA<WorkerAuthenticationException>()),
    );
    client.close();
  });

  test('does not send a Worker request after consent revocation', () async {
    var consentGranted = true;
    var requests = 0;
    final client = WorkerHttpClient(
      baseUri: Uri.parse('https://api.example.test'),
      sessionProvider: () async => consentGranted
          ? AuthSession(
              uid: 'user-1',
              idToken: 'firebase-token',
              expiresAt: DateTime.now().add(const Duration(minutes: 5)),
            )
          : null,
      client: MockClient((_) async {
        requests += 1;
        return http.Response('{}', 200);
      }),
    );
    consentGranted = false;

    await expectLater(
      client.send(method: 'GET', path: '/v1/me'),
      throwsA(isA<WorkerAuthenticationException>()),
    );
    expect(requests, 0);
    client.close();
  });

  test('rejects cleartext remote origins before a token can be sent', () {
    expect(
      () => WorkerHttpClient(
        baseUri: Uri.parse('http://api.example.test'),
        sessionProvider: () async => null,
      ),
      throwsArgumentError,
    );
  });

  test('allows cleartext loopback origins for local development', () {
    final client = WorkerHttpClient(
      baseUri: Uri.parse('http://127.0.0.1:8787'),
      sessionProvider: () async => null,
    );
    client.close();
  });

  test(
    'managed STT creates a strictly decoded session with the exact Firebase token',
    () async {
      late Map<String, Object?> capturedBody;
      final sessionId = List.filled(64, 'a').join();
      final idempotencyKey = List.filled(64, 'b').join();
      final deviceId = List.filled(64, 'c').join();
      final session = AuthSession(
        uid: 'user-1',
        idToken: 'current-firebase-token',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      );
      final client = WorkerHttpClient(
        baseUri: Uri.parse('https://api.example.test'),
        sessionProvider: () async => session,
        client: MockClient((request) async {
          capturedBody = (jsonDecode(request.body) as Map)
              .cast<String, Object?>();
          expect(
            request.headers['authorization'],
            'Bearer current-firebase-token',
          );
          return http.Response(
            jsonEncode({
              'sessionId': sessionId,
              'websocketUrl':
                  'wss://api.example.test/v1/stt/sessions/$sessionId/stream',
              'maxSessionSeconds': 900,
              'state': 'ready',
            }),
            201,
          );
        }),
      );

      final created = await WorkerManagedSttClient(client).createSession(
        idempotencyKey: idempotencyKey,
        deviceId: deviceId,
        language: 'multi',
        encoding: ManagedSttEncoding.linear16,
        sampleRate: 16000,
        channels: 1,
      );

      expect(created.session, same(session));
      expect(
        WorkerManagedSttClient(client).trustedWorkerOrigin,
        Uri.parse('https://api.example.test/'),
      );
      expect(
        created.websocketUrl,
        'wss://api.example.test/v1/stt/sessions/$sessionId/stream',
      );
      expect(capturedBody, {
        'idempotencyKey': idempotencyKey,
        'model': 'nova-3',
        'language': 'multi',
        'encoding': 'linear16',
        'sampleRate': 16000,
        'channels': 1,
        'diarize': true,
        'interimResults': true,
        'deviceId': deviceId,
        'sourceId': 'omi-device',
      });
      client.close();
    },
  );

  test('managed STT rejects malformed or expanded Worker responses', () async {
    final sessionId = List.filled(64, 'a').join();
    final client = WorkerHttpClient(
      baseUri: Uri.parse('https://api.example.test'),
      sessionProvider: () async => AuthSession(
        uid: 'user-1',
        idToken: 'firebase-token',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      ),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'sessionId': sessionId,
            'websocketUrl':
                'wss://evil.example/v1/stt/sessions/$sessionId/stream?token=leak',
            'maxSessionSeconds': 900,
            'state': 'ready',
            'accessToken': 'must-not-be-accepted',
          }),
          201,
        ),
      ),
    );

    await expectLater(
      WorkerManagedSttClient(client).createSession(
        idempotencyKey: List.filled(64, 'b').join(),
        deviceId: List.filled(64, 'c').join(),
        language: 'multi',
        encoding: ManagedSttEncoding.opus,
        sampleRate: 16000,
        channels: 1,
      ),
      throwsA(isA<WorkerResponseException>()),
    );
    client.close();
  });
}
