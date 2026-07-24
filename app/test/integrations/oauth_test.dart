import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/integrations/oauth/oauth.dart';
import 'package:shared_preferences/shared_preferences.dart';

OAuthAuthorizationRequest _request({String state = 'state-1'}) =>
    OAuthAuthorizationRequest(
      connector: googleOAuthConnector,
      clientId: 'client-abc',
      redirectUri: Uri.parse('http://127.0.0.1:51234/oauth/callback'),
      pkce: PkcePair.fromVerifier('a' * 64),
      state: state,
    );

OAuthConnection _connection({
  DateTime? expiresAt,
  String? refreshToken = 'refresh-1',
  bool needsReconnect = false,
}) => OAuthConnection(
  connectorId: googleOAuthConnector.id,
  accessToken: 'access-1',
  expiresAt: expiresAt ?? DateTime.utc(2030),
  grantedScopes: googleOAuthConnector.scopeValues,
  refreshToken: refreshToken,
  needsReconnect: needsReconnect,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PKCE', () {
    test('challenge is the unpadded base64url SHA-256 of the verifier', () {
      final pair = PkcePair.fromVerifier('a' * 64);
      final expected = base64Url
          .encode(sha256.convert(ascii.encode('a' * 64)).bytes)
          .replaceAll('=', '');
      expect(pair.challenge, expected);
      expect(pair.method, 'S256');
      expect(pair.challenge.contains('='), isFalse);
    });

    test('generated verifiers are in range, unreserved, and unique', () {
      final first = PkcePair.generate();
      final second = PkcePair.generate();
      expect(first.verifier.length, 64);
      expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(first.verifier), isTrue);
      expect(first.verifier, isNot(second.verifier));
      expect(PkcePair.fromVerifier(first.verifier).challenge, first.challenge);
    });

    test('verifiers outside 43-128 characters are rejected', () {
      expect(() => PkcePair.fromVerifier('short'), throwsArgumentError);
      expect(() => PkcePair.fromVerifier('a' * 129), throwsArgumentError);
      expect(
        () => PkcePair.fromVerifier('a b${'c' * 60}'),
        throwsArgumentError,
      );
    });

    test('authorization URI carries the challenge, never the verifier', () {
      final uri = _request().authorizationUri();
      final query = uri.queryParameters;
      expect(query['code_challenge_method'], 'S256');
      expect(query['response_type'], 'code');
      expect(query['access_type'], 'offline');
      expect(query['state'], 'state-1');
      expect(uri.toString().contains('a' * 64), isFalse);
      expect(query['scope'], contains('gmail.readonly'));
      expect(query['scope'], isNot(contains('gmail.modify')));
    });
  });

  group('redirect binding', () {
    test('a mismatched state is rejected before any exchange', () {
      final request = _request();
      expect(
        () => request.codeFromRedirect(
          Uri.parse('http://127.0.0.1/oauth/callback?code=c&state=other'),
        ),
        throwsA(isA<OAuthStateMismatchException>()),
      );
    });

    test('a missing state is rejected', () {
      expect(
        () => _request().codeFromRedirect(
          Uri.parse('http://127.0.0.1/oauth/callback?code=c'),
        ),
        throwsA(isA<OAuthStateMismatchException>()),
      );
    });

    test('a matching state yields the code, and an error surfaces', () {
      final request = _request();
      expect(
        request.codeFromRedirect(
          Uri.parse('http://127.0.0.1/oauth/callback?code=c&state=state-1'),
        ),
        'c',
      );
      expect(
        () => request.codeFromRedirect(
          Uri.parse(
            'http://127.0.0.1/oauth/callback?error=access_denied&state=state-1',
          ),
        ),
        throwsA(isA<OAuthException>()),
      );
    });
  });

  group('token client', () {
    test('exchange sends the verifier and no client secret', () async {
      late Map<String, String> sent;
      final client = OAuthTokenClient(
        httpClient: MockClient((request) async {
          sent = Uri.splitQueryString(request.body);
          return http.Response(
            jsonEncode({
              'access_token': 'at',
              'refresh_token': 'rt',
              'expires_in': 3600,
              'scope': 'https://www.googleapis.com/auth/gmail.readonly',
            }),
            200,
          );
        }),
        now: () => DateTime.utc(2030),
      );
      final connection = await client.exchange(_request(), 'code-1');
      expect(sent['grant_type'], 'authorization_code');
      expect(sent['code_verifier'], 'a' * 64);
      expect(sent.containsKey('client_secret'), isFalse);
      expect(connection.accessToken, 'at');
      expect(connection.refreshToken, 'rt');
      expect(
        connection.expiresAt,
        DateTime.utc(2030).add(const Duration(seconds: 3600)),
      );
      expect(connection.grantedScopes, [
        'https://www.googleapis.com/auth/gmail.readonly',
      ]);
    });

    test('invalid_grant on refresh surfaces as reconnect required', () async {
      final client = OAuthTokenClient(
        httpClient: MockClient(
          (request) async =>
              http.Response(jsonEncode({'error': 'invalid_grant'}), 400),
        ),
      );
      expect(
        () => client.refresh(googleOAuthConnector, 'client-abc', _connection()),
        throwsA(isA<OAuthReconnectRequiredException>()),
      );
    });
  });

  group('connection manager', () {
    test('refreshes a token that is about to expire', () async {
      var calls = 0;
      final store = VolatileOAuthConnectionStore();
      final now = DateTime.utc(2030);
      await store.write(
        'u',
        _connection(expiresAt: now.add(const Duration(seconds: 30))),
      );
      final manager = OAuthConnectionManager(
        connections: store,
        clientIds: VolatileOAuthClientIdStore()
          ..values['google'] = 'client-abc',
        now: () => now,
        httpClient: MockClient((request) async {
          calls += 1;
          expect(
            Uri.splitQueryString(request.body)['grant_type'],
            'refresh_token',
          );
          return http.Response(
            jsonEncode({'access_token': 'fresh', 'expires_in': 3600}),
            200,
          );
        }),
      );

      expect(await manager.accessToken('u', googleOAuthConnector), 'fresh');
      expect(calls, 1);
      // The stored token is now current, so a second read hits no network.
      expect(await manager.accessToken('u', googleOAuthConnector), 'fresh');
      expect(calls, 1);
      expect((await store.read('u', 'google'))?.refreshToken, 'refresh-1');
    });

    test('a valid token is used without contacting the network', () async {
      final store = VolatileOAuthConnectionStore();
      await store.write('u', _connection());
      final manager = OAuthConnectionManager(
        connections: store,
        clientIds: VolatileOAuthClientIdStore(),
        now: () => DateTime.utc(2029),
        httpClient: MockClient((_) async => fail('no request expected')),
      );
      expect(await manager.accessToken('u', googleOAuthConnector), 'access-1');
    });

    test(
      'a revoked refresh token becomes reconnect-needed and never retries',
      () async {
        var calls = 0;
        final now = DateTime.utc(2030);
        final store = VolatileOAuthConnectionStore();
        await store.write('u', _connection(expiresAt: now));
        final manager = OAuthConnectionManager(
          connections: store,
          clientIds: VolatileOAuthClientIdStore()
            ..values['google'] = 'client-abc',
          now: () => now,
          httpClient: MockClient((_) async {
            calls += 1;
            return http.Response(jsonEncode({'error': 'invalid_grant'}), 400);
          }),
        );

        for (var attempt = 0; attempt < 3; attempt += 1) {
          await expectLater(
            manager.accessToken('u', googleOAuthConnector),
            throwsA(isA<OAuthReconnectRequiredException>()),
          );
        }
        // Exactly one network attempt across three calls: the dead grant is
        // recorded, not retried.
        expect(calls, 1);
        expect((await store.read('u', 'google'))?.needsReconnect, isTrue);
        expect(
          await manager.state('u', googleOAuthConnector),
          OAuthConnectionState.reconnectRequired,
        );
      },
    );

    test('disconnect calls the revocation endpoint with the grant', () async {
      Uri? revoked;
      String? token;
      final store = VolatileOAuthConnectionStore();
      await store.write('u', _connection());
      final manager = OAuthConnectionManager(
        connections: store,
        clientIds: VolatileOAuthClientIdStore(),
        httpClient: MockClient((request) async {
          revoked = request.url;
          token = Uri.splitQueryString(request.body)['token'];
          return http.Response('', 200);
        }),
      );

      await manager.disconnect('u', googleOAuthConnector);
      expect(revoked, googleOAuthConnector.revocationEndpoint);
      // The refresh token is revoked, since that is what carries the grant.
      expect(token, 'refresh-1');
      expect(await store.read('u', 'google'), isNull);
      expect(
        await manager.state('u', googleOAuthConnector),
        OAuthConnectionState.disconnected,
      );
    });

    test('a failed revocation is reported, not swallowed', () async {
      final store = VolatileOAuthConnectionStore();
      await store.write('u', _connection());
      final manager = OAuthConnectionManager(
        connections: store,
        clientIds: VolatileOAuthClientIdStore(),
        httpClient: MockClient((_) async => http.Response('nope', 500)),
      );
      await expectLater(
        manager.disconnect('u', googleOAuthConnector),
        throwsA(isA<OAuthException>()),
      );
      expect(await store.read('u', 'google'), isNull);
    });

    test('connecting without a client id refuses to start a flow', () async {
      final manager = OAuthConnectionManager(
        connections: VolatileOAuthConnectionStore(),
        clientIds: VolatileOAuthClientIdStore(),
        loopback: () => fail('no loopback expected'),
        launcher: (_) async => fail('no browser expected'),
        httpClient: MockClient((_) async => fail('no request expected')),
      );
      await expectLater(
        manager.connect('u', googleOAuthConnector),
        throwsA(isA<OAuthException>()),
      );
    });
  });

  group('storage', () {
    test('tokens land in the keychain and nowhere else', () async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      const store = SecureOAuthConnectionStore();

      await store.write('user-a', _connection());
      const clientIds = PreferencesOAuthClientIdStore();
      await clientIds.write('google', 'client-abc');

      expect((await store.read('user-a', 'google'))?.accessToken, 'access-1');
      expect(await store.read('user-b', 'google'), isNull);

      final preferences = await SharedPreferences.getInstance();
      final spilled = [
        for (final key in preferences.getKeys()) '${preferences.get(key)}',
      ].join('\n');
      expect(spilled, contains('client-abc'));
      expect(spilled, isNot(contains('access-1')));
      expect(spilled, isNot(contains('refresh-1')));

      await store.remove('user-a', 'google');
      expect(await store.read('user-a', 'google'), isNull);
    });

    test('a connection round-trips through JSON', () {
      final restored = OAuthConnection.fromJson(
        jsonDecode(jsonEncode(_connection(needsReconnect: true).toJson())),
      );
      expect(restored?.refreshToken, 'refresh-1');
      expect(restored?.needsReconnect, isTrue);
      expect(restored?.grantedScopes, googleOAuthConnector.scopeValues);
      expect(OAuthConnection.fromJson({'connectorId': 'google'}), isNull);
    });
  });

  group('connector surface', () {
    test('Google asks only for read-only scopes', () {
      for (final scope in googleOAuthConnector.scopeValues) {
        expect(
          scope.contains('.readonly') ||
              scope == 'openid' ||
              scope.endsWith('userinfo.email'),
          isTrue,
          reason: '$scope is not read-only',
        );
      }
      expect(googleOAuthConnector.revocable, isTrue);
    });

    test('registered connectors have unique ids and a lookup', () {
      final ids = oauthConnectors.map((value) => value.id).toSet();
      expect(ids.length, oauthConnectors.length);
      expect(oauthConnectorById('google'), googleOAuthConnector);
      expect(oauthConnectorById('nope'), isNull);
    });
  });
}
