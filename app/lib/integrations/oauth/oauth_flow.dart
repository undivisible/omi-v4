import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'oauth_connection.dart';
import 'oauth_connector.dart';
import 'oauth_pkce.dart';

/// Anything that went wrong in the flow that is not a dead refresh token.
final class OAuthException implements Exception {
  const OAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The redirect did not belong to the request that started it. Treated as an
/// authorization-code injection attempt: the code is discarded unexchanged.
final class OAuthStateMismatchException extends OAuthException {
  const OAuthStateMismatchException() : super('Authorization state mismatch');
}

/// The grant is permanently gone (revoked, expired, or consent withdrawn).
/// Callers must surface "reconnect needed" and stop — never retry.
final class OAuthReconnectRequiredException extends OAuthException {
  const OAuthReconnectRequiredException(this.connectorId)
    : super('Reconnect required');

  final String connectorId;
}

/// A single authorization attempt: the PKCE pair, the state, and the loopback
/// redirect URI are all bound together here and nowhere else.
@immutable
final class OAuthAuthorizationRequest {
  OAuthAuthorizationRequest({
    required this.connector,
    required this.clientId,
    required this.redirectUri,
    PkcePair? pkce,
    String? state,
  }) : pkce = pkce ?? PkcePair.generate(),
       state = state ?? generateOAuthState();

  final OAuthConnector connector;
  final String clientId;
  final Uri redirectUri;
  final PkcePair pkce;
  final String state;

  Uri authorizationUri() => connector.authorizationEndpoint.replace(
    queryParameters: {
      ...connector.authorizationParameters,
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri.toString(),
      'scope': connector.scopeParameter,
      'state': state,
      'code_challenge': pkce.challenge,
      'code_challenge_method': pkce.method,
    },
  );

  /// Pulls the authorization code out of a loopback redirect, refusing
  /// anything whose `state` is absent or does not match this request.
  String codeFromRedirect(Uri redirect) {
    final received = redirect.queryParameters['state'];
    if (received == null || received != state) {
      throw const OAuthStateMismatchException();
    }
    final error = redirect.queryParameters['error'];
    if (error != null) {
      throw OAuthException('Authorization denied ($error)');
    }
    final code = redirect.queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw const OAuthException('Authorization response carried no code');
    }
    return code;
  }
}

/// Token endpoint calls. Kept free of any provider special-casing so a new
/// connector needs no change here.
final class OAuthTokenClient {
  const OAuthTokenClient({required this.httpClient, this.now});

  final http.Client httpClient;
  final DateTime Function()? now;

  DateTime get _now => (now ?? () => DateTime.now().toUtc())().toUtc();

  /// Exchanges the code for tokens, proving possession of the PKCE verifier
  /// and repeating the exact redirect URI the authorization used.
  Future<OAuthConnection> exchange(
    OAuthAuthorizationRequest request,
    String code,
  ) async {
    final body = await _post(request.connector.tokenEndpoint, {
      'grant_type': 'authorization_code',
      'code': code,
      'client_id': request.clientId,
      'redirect_uri': request.redirectUri.toString(),
      'code_verifier': request.pkce.verifier,
    }, request.connector.id);
    final accessToken = body['access_token'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw const OAuthException('Token response carried no access token');
    }
    final refresh = body['refresh_token'];
    return OAuthConnection(
      connectorId: request.connector.id,
      accessToken: accessToken,
      expiresAt: _expiry(body['expires_in']),
      grantedScopes: _scopes(body['scope']) ?? request.connector.scopeValues,
      refreshToken: refresh is String && refresh.isNotEmpty ? refresh : null,
      account: _account(request.connector, body),
    );
  }

  /// Trades the refresh token for a fresh access token. A provider that
  /// answers `invalid_grant` has permanently killed the grant, which surfaces
  /// as [OAuthReconnectRequiredException].
  Future<OAuthConnection> refresh(
    OAuthConnector connector,
    String clientId,
    OAuthConnection connection,
  ) async {
    final refreshToken = connection.refreshToken;
    if (refreshToken == null) {
      throw OAuthReconnectRequiredException(connector.id);
    }
    final body = await _post(connector.tokenEndpoint, {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
    }, connector.id);
    final accessToken = body['access_token'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw OAuthReconnectRequiredException(connector.id);
    }
    final rotated = body['refresh_token'];
    return connection.copyWith(
      accessToken: accessToken,
      expiresAt: _expiry(body['expires_in']),
      grantedScopes: _scopes(body['scope']) ?? connection.grantedScopes,
      refreshToken: rotated is String && rotated.isNotEmpty
          ? rotated
          : refreshToken,
      needsReconnect: false,
    );
  }

  /// Revokes at the provider. Returns false when the connector has no
  /// revocation endpoint, so the caller can say so rather than pretend.
  Future<bool> revoke(
    OAuthConnector connector,
    OAuthConnection connection,
  ) async {
    final endpoint = connector.revocationEndpoint;
    if (endpoint == null) return false;
    // Revoking the refresh token takes the whole grant with it; the access
    // token alone would leave the refresh token usable.
    final token = connection.refreshToken ?? connection.accessToken;
    final response = await httpClient.post(
      endpoint,
      headers: const {'content-type': 'application/x-www-form-urlencoded'},
      body: {'token': token},
    );
    // A token the provider has already forgotten is a successful revocation
    // from the user's point of view.
    if (response.statusCode >= 200 && response.statusCode < 300) return true;
    if (response.statusCode == 400) return true;
    throw OAuthException(
      'Revocation failed (${response.statusCode}) for ${connector.displayName}',
    );
  }

  Future<Map<String, Object?>> _post(
    Uri endpoint,
    Map<String, String> form,
    String connectorId,
  ) async {
    final response = await httpClient.post(
      endpoint,
      headers: const {
        'content-type': 'application/x-www-form-urlencoded',
        'accept': 'application/json',
      },
      body: form,
    );
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw OAuthException('Token endpoint returned ${response.statusCode}');
    }
    final body = decoded is Map
        ? decoded.map((key, value) => MapEntry('$key', value))
        : <String, Object?>{};
    if (response.statusCode >= 200 && response.statusCode < 300) return body;
    final error = '${body['error'] ?? response.statusCode}';
    if (error == 'invalid_grant' || error == 'invalid_client') {
      throw OAuthReconnectRequiredException(connectorId);
    }
    throw OAuthException('Token endpoint refused the request ($error)');
  }

  DateTime _expiry(Object? expiresIn) {
    final seconds = expiresIn is int
        ? expiresIn
        : int.tryParse('$expiresIn') ?? 3600;
    return _now.add(Duration(seconds: seconds));
  }

  List<String>? _scopes(Object? scope) {
    if (scope is! String || scope.trim().isEmpty) return null;
    return scope.split(' ').where((value) => value.isNotEmpty).toList();
  }

  String? _account(OAuthConnector connector, Map<String, Object?> body) {
    final field = connector.accountFieldName;
    if (field == null) return null;
    final value = body[field];
    return value is String && value.isNotEmpty ? value : null;
  }
}

/// A one-shot loopback listener on 127.0.0.1. Binding to port 0 and reading
/// the assigned port keeps the redirect URI unique to this attempt, and the
/// server is torn down as soon as the redirect lands.
final class LoopbackRedirectServer {
  LoopbackRedirectServer._(this._server, this.redirectUri);

  static const path = '/oauth/callback';

  static Future<LoopbackRedirectServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      path: path,
    );
    return LoopbackRedirectServer._(server, uri);
  }

  final HttpServer _server;
  final Uri redirectUri;

  /// Resolves with the first redirect that arrives on the callback path.
  Future<Uri> awaitRedirect({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final completer = Completer<Uri>();
    final subscription = _server.listen((request) async {
      if (request.uri.path != path) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(
          '<!doctype html><meta charset="utf-8">'
          '<title>Omi</title>'
          '<p style="font:14px -apple-system,sans-serif;padding:32px">'
          'Omi is connected. You can close this tab.</p>',
        );
      await request.response.close();
      if (!completer.isCompleted) completer.complete(request.uri);
    }, onError: completer.completeError);
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      throw const OAuthException('Authorization timed out');
    } finally {
      await subscription.cancel();
      await close();
    }
  }

  Future<void> close() => _server.close(force: true);
}
