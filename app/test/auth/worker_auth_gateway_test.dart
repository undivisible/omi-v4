import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/auth/auth_gateway.dart';
import 'package:omi/auth/auth_models.dart';
import 'package:omi/auth/worker_auth_gateway.dart';

final class _MemoryStore implements WorkerAuthCredentialStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String refreshToken) async => value = refreshToken;

  @override
  Future<void> clear() async => value = null;
}

void main() {
  final origin = Uri.parse('https://api.example.com');

  String credentials({String uid = 'u1', int expiresAt = 2000}) => jsonEncode({
    'accessToken': 'access-token',
    'refreshToken': 'refresh-token',
    'expiresAt': expiresAt,
    'uid': uid,
  });

  WorkerAuthGateway gatewayFor(
    Future<http.Response> Function(http.Request request) handler, {
    _MemoryStore? store,
    DateTime Function()? now,
  }) => WorkerAuthGateway(
    apiOrigin: origin,
    store: store ?? _MemoryStore(),
    clientFactory: () => MockClient(handler),
    now: now,
  );

  test('a channel code is exchanged for a session and the refresh token is '
      'the only credential kept', () async {
    final store = _MemoryStore();
    late http.Request seen;
    final gateway = gatewayFor((request) async {
      seen = request;
      return http.Response(credentials(), 200);
    }, store: store);

    final session = await gateway.signInWithChannelCode(' ab12cd3 ');

    expect(seen.url.path, '/v1/auth/channel/exchange');
    expect(jsonDecode(seen.body), {'code': 'ab12cd3'});
    expect(session.uid, 'u1');
    expect(session.idToken, 'access-token');
    expect(session.expiresAt, DateTime.fromMillisecondsSinceEpoch(2000));
    // The access token is short-lived and re-mintable; only the refresh
    // credential is worth persisting.
    expect(store.value, 'refresh-token');
    expect(gateway.currentSession?.uid, 'u1');
  });

  test('a code that cannot be one of ours never reaches the worker', () async {
    var called = false;
    final gateway = gatewayFor((request) async {
      called = true;
      return http.Response(credentials(), 200);
    });

    for (final bad in ['', 'short', 'waytoolongcode', 'ab-12cd']) {
      await expectLater(
        gateway.signInWithChannelCode(bad),
        throwsA(
          isA<AuthOperationException>().having(
            (error) => error.failure.code,
            'code',
            AuthErrorCode.invalidOtp,
          ),
        ),
      );
    }
    expect(called, isFalse);
  });

  test(
    'the worker\'s opaque refusal is reported as a bad code, not a fault',
    () async {
      final gateway = gatewayFor((request) async => http.Response('{}', 401));

      await expectLater(
        gateway.signInWithChannelCode('ab12cd3'),
        throwsA(
          isA<AuthOperationException>().having(
            (error) => error.failure.code,
            'code',
            AuthErrorCode.invalidOtp,
          ),
        ),
      );
    },
  );

  test('rate limiting is distinguished from a wrong code', () async {
    final gateway = gatewayFor((request) async => http.Response('{}', 429));

    await expectLater(
      gateway.signInWithChannelCode('ab12cd3'),
      throwsA(
        isA<AuthOperationException>().having(
          (error) => error.failure.code,
          'code',
          AuthErrorCode.rateLimited,
        ),
      ),
    );
  });

  test('a stored refresh token restores the session on launch', () async {
    final store = _MemoryStore()..value = 'stored-refresh';
    late http.Request seen;
    final gateway = gatewayFor((request) async {
      seen = request;
      return http.Response(credentials(uid: 'u2'), 200);
    }, store: store);

    final session = await gateway.restoreSession();

    expect(seen.url.path, '/v1/auth/refresh');
    expect(jsonDecode(seen.body), {'refreshToken': 'stored-refresh'});
    expect(session?.uid, 'u2');
    expect(store.value, 'refresh-token');
  });

  test('a refresh token the worker rejects is dropped rather than retried '
      'forever', () async {
    final store = _MemoryStore()..value = 'revoked';
    final gateway = gatewayFor(
      (request) async => http.Response('{}', 401),
      store: store,
    );

    expect(await gateway.restoreSession(), isNull);
    expect(store.value, isNull);
  });

  test('no stored credential is not a failure, just no session', () async {
    var called = false;
    final gateway = gatewayFor((request) async {
      called = true;
      return http.Response(credentials(), 200);
    });

    expect(await gateway.restoreSession(), isNull);
    expect(called, isFalse);
  });

  test('a live session is reused until it is nearly expired', () async {
    var requests = 0;
    var now = DateTime.fromMillisecondsSinceEpoch(0);
    final gateway = gatewayFor((request) async {
      requests++;
      return http.Response(
        credentials(expiresAt: const Duration(hours: 1).inMilliseconds),
        200,
      );
    }, now: () => now);

    await gateway.signInWithChannelCode('ab12cd3');
    expect(requests, 1);

    await gateway.refreshSession();
    expect(requests, 1, reason: 'a session with time left needs no round trip');

    now = DateTime.fromMillisecondsSinceEpoch(
      const Duration(hours: 1).inMilliseconds,
    );
    await gateway.refreshSession();
    expect(requests, 2);
  });

  test(
    'signing out clears the credential even when the network is gone',
    () async {
      final store = _MemoryStore();
      var attempts = 0;
      final gateway = gatewayFor((request) async {
        attempts++;
        if (request.url.path == '/v1/auth/signout') {
          throw http.ClientException('offline');
        }
        return http.Response(credentials(), 200);
      }, store: store);

      await gateway.signInWithChannelCode('ab12cd3');
      await gateway.signOut();

      expect(attempts, 2);
      expect(store.value, isNull);
      expect(gateway.currentSession, isNull);
    },
  );

  test('an unusable reply is refused rather than half-applied', () async {
    final store = _MemoryStore();
    final gateway = gatewayFor(
      (request) async => http.Response('{"accessToken":"a"}', 200),
      store: store,
    );

    await expectLater(
      gateway.signInWithChannelCode('ab12cd3'),
      throwsA(isA<AuthOperationException>()),
    );
    expect(store.value, isNull);
    expect(gateway.currentSession, isNull);
  });

  test(
    'the phone leg is a channel the user opens, not a challenge we issue',
    () async {
      final gateway = gatewayFor((request) async => http.Response('{}', 200));

      expect(gateway.supportsPhoneOtp, isFalse);
      expect(gateway.supportsDesktopBrowserHandoff, isFalse);
      expect(gateway.isConfigured, isTrue);
      await expectLater(
        gateway.requestPhoneOtp('+15125789425'),
        throwsA(isA<AuthOperationException>()),
      );
    },
  );

  test(
    'a non-https origin is a configuration failure, not a sign-in failure',
    () {
      final gateway = WorkerAuthGateway(
        apiOrigin: Uri.parse('http://insecure.example.com'),
        store: _MemoryStore(),
      );

      expect(gateway.isConfigured, isFalse);
      expect(
        gateway.configurationFailure?.code,
        AuthErrorCode.configurationMissing,
      );
    },
  );
}
