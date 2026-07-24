import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/integrations/oauth/oauth.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('granted scopes are shown in plain language', (tester) async {
    final store = VolatileOAuthConnectionStore();
    await store.write(
      'u',
      OAuthConnection(
        connectorId: 'google',
        accessToken: 'at',
        expiresAt: DateTime.utc(2030),
        grantedScopes: const ['https://www.googleapis.com/auth/gmail.readonly'],
        refreshToken: 'rt',
      ),
    );
    await tester.pumpWidget(
      _host(
        OAuthConnectorTile(
          connector: googleOAuthConnector,
          uid: 'u',
          previewMode: false,
          manager: OAuthConnectionManager(
            connections: store,
            clientIds: VolatileOAuthClientIdStore(),
            httpClient: MockClient((_) async => http.Response('', 200)),
          ),
          readPathBuilder: (_) => null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);
    await tester.tap(find.byKey(const Key('oauth_google_scopes')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Read your Gmail messages'), findsOneWidget);
    expect(
      find.textContaining('revokes this access at Google'),
      findsOneWidget,
    );
  });

  testWidgets('disconnect revokes and clears the row', (tester) async {
    var revoked = 0;
    final store = VolatileOAuthConnectionStore();
    await store.write(
      'u',
      OAuthConnection(
        connectorId: 'google',
        accessToken: 'at',
        expiresAt: DateTime.utc(2030),
        grantedScopes: googleOAuthConnector.scopeValues,
        refreshToken: 'rt',
      ),
    );
    await tester.pumpWidget(
      _host(
        OAuthConnectorTile(
          connector: googleOAuthConnector,
          uid: 'u',
          previewMode: false,
          manager: OAuthConnectionManager(
            connections: store,
            clientIds: VolatileOAuthClientIdStore(),
            httpClient: MockClient((request) async {
              expect(request.url, googleOAuthConnector.revocationEndpoint);
              revoked += 1;
              return http.Response('', 200);
            }),
          ),
          readPathBuilder: (_) => null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('oauth_google_action')));
    await tester.pumpAndSettle();

    expect(revoked, 1);
    expect(find.text('Not connected'), findsOneWidget);
    expect(await store.read('u', 'google'), isNull);
  });

  testWidgets('a dead grant reads as reconnect needed', (tester) async {
    final store = VolatileOAuthConnectionStore();
    await store.write(
      'u',
      OAuthConnection(
        connectorId: 'google',
        accessToken: 'at',
        expiresAt: DateTime.utc(2030),
        grantedScopes: googleOAuthConnector.scopeValues,
        refreshToken: 'rt',
        needsReconnect: true,
      ),
    );
    await tester.pumpWidget(
      _host(
        OAuthConnectorTile(
          connector: googleOAuthConnector,
          uid: 'u',
          previewMode: false,
          manager: OAuthConnectionManager(
            connections: store,
            clientIds: VolatileOAuthClientIdStore(),
            httpClient: MockClient((_) async => fail('no request expected')),
          ),
          readPathBuilder: (_) => null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Reconnect needed'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
  });
}
