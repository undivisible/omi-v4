import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/api/worker_http.dart';
import 'package:omi/auth/auth.dart';

void main() {
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
}
