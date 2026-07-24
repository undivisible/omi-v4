import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'oauth_client_config.dart';
import 'oauth_connection.dart';
import 'oauth_connector.dart';
import 'oauth_flow.dart';

/// What settings shows for a connector.
enum OAuthConnectionState {
  /// No grant stored.
  disconnected,

  /// A usable grant.
  connected,

  /// The provider killed the grant. The user has to act; nothing retries.
  reconnectRequired,
}

/// Opens the system browser for the authorization step. Injected so tests
/// never launch anything.
typedef OAuthBrowserLauncher = Future<bool> Function(Uri authorizationUri);

Future<bool> _launchInBrowser(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Drives connect, refresh, and disconnect for every connector.
///
/// Nothing in here knows what Google is: the connector descriptor supplies the
/// endpoints and scopes, so a second provider reuses this class unchanged.
final class OAuthConnectionManager {
  OAuthConnectionManager({
    http.Client? httpClient,
    OAuthConnectionStore? connections,
    OAuthClientIdStore? clientIds,
    OAuthBrowserLauncher? launcher,
    Future<LoopbackRedirectServer> Function()? loopback,
    DateTime Function()? now,
  }) : _http = httpClient ?? http.Client(),
       _connections = connections ?? const SecureOAuthConnectionStore(),
       clientIds = clientIds ?? const PreferencesOAuthClientIdStore(),
       _launcher = launcher ?? _launchInBrowser,
       _loopback = loopback ?? LoopbackRedirectServer.start,
       _now = now ?? (() => DateTime.now().toUtc());

  /// Refresh this far ahead of expiry, so a long request never starts with a
  /// token that dies mid-flight.
  static const refreshSkew = Duration(minutes: 2);

  final http.Client _http;
  final OAuthConnectionStore _connections;
  final OAuthClientIdStore clientIds;
  final OAuthBrowserLauncher _launcher;
  final Future<LoopbackRedirectServer> Function() _loopback;
  final DateTime Function() _now;

  late final OAuthTokenClient _tokens = OAuthTokenClient(
    httpClient: _http,
    now: _now,
  );

  Future<OAuthConnection?> connection(String uid, OAuthConnector connector) =>
      _connections.read(uid, connector.id);

  Future<OAuthConnectionState> state(
    String uid,
    OAuthConnector connector,
  ) async {
    final value = await _connections.read(uid, connector.id);
    if (value == null) return OAuthConnectionState.disconnected;
    return value.needsReconnect
        ? OAuthConnectionState.reconnectRequired
        : OAuthConnectionState.connected;
  }

  /// Runs the full authorization-code-with-PKCE flow and stores the result in
  /// the keychain.
  Future<OAuthConnection> connect(String uid, OAuthConnector connector) async {
    final clientId = await clientIds.read(connector.id);
    if (clientId == null || clientId.isEmpty) {
      throw OAuthException(
        'Add a ${connector.displayName} client ID before connecting.',
      );
    }
    final server = await _loopback();
    final request = OAuthAuthorizationRequest(
      connector: connector,
      clientId: clientId,
      redirectUri: server.redirectUri,
    );
    final redirect = server.awaitRedirect();
    if (!await _launcher(request.authorizationUri())) {
      await server.close();
      throw const OAuthException('Could not open the browser');
    }
    final code = request.codeFromRedirect(await redirect);
    final connection = await _tokens.exchange(request, code);
    await _connections.write(uid, connection);
    return connection;
  }

  /// Returns a token that is valid now, refreshing first when it is close to
  /// expiry. A connection already marked [OAuthConnectionState.reconnectRequired]
  /// throws immediately instead of hammering a dead grant.
  Future<String> accessToken(String uid, OAuthConnector connector) async {
    final stored = await _connections.read(uid, connector.id);
    if (stored == null || stored.needsReconnect) {
      throw OAuthReconnectRequiredException(connector.id);
    }
    if (!stored.expiresWithin(refreshSkew, now: _now())) {
      return stored.accessToken;
    }
    final clientId = await clientIds.read(connector.id);
    if (clientId == null || clientId.isEmpty) {
      throw OAuthReconnectRequiredException(connector.id);
    }
    try {
      final refreshed = await _tokens.refresh(connector, clientId, stored);
      await _connections.write(uid, refreshed);
      return refreshed.accessToken;
    } on OAuthReconnectRequiredException {
      // Record the dead grant so no later call retries it.
      await _connections.write(uid, stored.copyWith(needsReconnect: true));
      rethrow;
    }
  }

  /// Revokes at the provider, then forgets locally. The local record is
  /// dropped even if revocation fails, but the failure is reported so the user
  /// is never told access is gone when it is not.
  Future<void> disconnect(String uid, OAuthConnector connector) async {
    final stored = await _connections.read(uid, connector.id);
    if (stored == null) return;
    Object? failure;
    try {
      await _tokens.revoke(connector, stored);
    } catch (error) {
      failure = error;
    }
    await _connections.remove(uid, connector.id);
    if (failure != null) {
      throw OAuthException(
        'Signed out locally, but ${connector.displayName} did not confirm '
        'revocation: $failure',
      );
    }
  }
}
