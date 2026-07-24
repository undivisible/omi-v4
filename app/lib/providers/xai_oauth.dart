import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../integrations/oauth/oauth_pkce.dart';

/// xAI's sanctioned desktop OAuth client for coding agents (device-code + PKCE
/// against `accounts.x.ai` / `auth.x.ai`). The client id, scope and endpoints
/// are the public values shipped by xAI's own OIDC discovery document
/// (`https://auth.x.ai/.well-known/openid-configuration`); they carry no client
/// secret because a desktop client cannot hold one. Values transcribed from
/// Nous Research's Hermes Agent (`hermes_cli/auth.py`), which pins the same
/// first-party client the Zed and opencode integrations use.
const xaiOAuthIssuer = 'https://auth.x.ai';
const xaiOAuthClientId = 'b1a00492-073a-47ea-816f-4c329264a828';
const xaiOAuthScope =
    'openid profile email offline_access grok-cli:access api:access';
const xaiOAuthDeviceCodeUrl = '$xaiOAuthIssuer/oauth2/device/code';
const xaiOAuthTokenUrl = '$xaiOAuthIssuer/oauth2/token';

/// Inference base for the xAI Responses-style API the hub already reaches; the
/// OAuth access token is presented to it as a bearer, exactly where an
/// `XAI_API_KEY` would otherwise go.
const xaiInferenceBaseUrl = 'https://api.x.ai/v1';

const _deviceCodeGrant = 'urn:ietf:params:oauth:grant-type:device_code';

/// A device-authorization challenge: the code the user types, the URL they open,
/// and the pacing the server asks the client to poll at.
final class XaiDeviceAuthorization {
  const XaiDeviceAuthorization({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.verificationUriComplete,
    required this.interval,
    required this.expiresIn,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final String verificationUriComplete;
  final Duration interval;
  final Duration expiresIn;
}

/// The tokens a successful login (or refresh) yields. [expiresAt] is derived
/// from the server's `expires_in` so the app can refresh ahead of expiry.
final class XaiOAuthTokens {
  const XaiOAuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
}

/// A terminal OAuth failure. [forbidden] is set when xAI answered HTTP 403,
/// which — even for a valid SuperGrok subscriber — means the account is not on
/// the OAuth API allowlist yet and the user must fall back to an `XAI_API_KEY`.
final class XaiOAuthException implements Exception {
  const XaiOAuthException(this.message, {this.forbidden = false});

  final String message;
  final bool forbidden;

  @override
  String toString() => message;
}

/// Drives the xAI device-code + PKCE flow and refreshes access tokens. The
/// [http.Client] and [clock]/[sleep] hooks are injectable so the flow is
/// testable without real network or wall-clock waits.
final class XaiOAuthClient {
  XaiOAuthClient({
    http.Client? httpClient,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
  }) : _http = httpClient ?? http.Client(),
       _clock = clock ?? DateTime.now,
       _sleep = sleep ?? Future.delayed;

  final http.Client _http;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;

  /// Requests a device code, binding the flow to a fresh PKCE verifier that
  /// [pollForTokens] must be given back.
  Future<(XaiDeviceAuthorization, PkcePair)> requestDeviceCode() async {
    final pkce = PkcePair.generate();
    final response = await _http.post(
      Uri.parse(xaiOAuthDeviceCodeUrl),
      headers: const {'Accept': 'application/json'},
      body: {
        'client_id': xaiOAuthClientId,
        'scope': xaiOAuthScope,
        'code_challenge': pkce.challenge,
        'code_challenge_method': pkce.method,
      },
    );
    if (response.statusCode == 403) {
      throw _forbidden();
    }
    if (response.statusCode != 200) {
      throw XaiOAuthException(
        'xAI declined to start sign-in (HTTP ${response.statusCode}).',
      );
    }
    final body = _decode(response.body);
    final deviceCode = body['device_code'];
    final userCode = body['user_code'];
    final verificationUri = body['verification_uri'];
    if (deviceCode is! String || userCode is! String) {
      throw const XaiOAuthException('xAI returned an unusable device code.');
    }
    final complete = body['verification_uri_complete'];
    final interval = body['interval'];
    final expiresIn = body['expires_in'];
    return (
      XaiDeviceAuthorization(
        deviceCode: deviceCode,
        userCode: userCode,
        verificationUri: verificationUri is String ? verificationUri : '',
        verificationUriComplete: complete is String
            ? complete
            : (verificationUri is String ? verificationUri : ''),
        interval: Duration(seconds: interval is int ? interval : 5),
        expiresIn: Duration(seconds: expiresIn is int ? expiresIn : 600),
      ),
      pkce,
    );
  }

  /// Polls the token endpoint until the user approves, the code expires, or a
  /// terminal error is returned. Honors `authorization_pending`/`slow_down`.
  Future<XaiOAuthTokens> pollForTokens(
    XaiDeviceAuthorization authorization,
    PkcePair pkce,
  ) async {
    final deadline = _clock().add(authorization.expiresIn);
    var interval = authorization.interval;
    while (_clock().isBefore(deadline)) {
      await _sleep(interval);
      final response = await _http.post(
        Uri.parse(xaiOAuthTokenUrl),
        headers: const {'Accept': 'application/json'},
        body: {
          'grant_type': _deviceCodeGrant,
          'client_id': xaiOAuthClientId,
          'device_code': authorization.deviceCode,
          'code_verifier': pkce.verifier,
        },
      );
      if (response.statusCode == 200) {
        return _tokensFrom(_decode(response.body), previousRefresh: '');
      }
      if (response.statusCode == 403) {
        throw _forbidden();
      }
      final error = _errorCode(response.body);
      if (error == 'authorization_pending') continue;
      if (error == 'slow_down') {
        interval += const Duration(seconds: 5);
        continue;
      }
      throw XaiOAuthException(
        'xAI sign-in failed: ${error ?? 'HTTP ${response.statusCode}'}.',
      );
    }
    throw const XaiOAuthException('The sign-in code expired. Try again.');
  }

  /// Exchanges a refresh token for a fresh access token, keeping the old
  /// refresh token when xAI does not rotate it.
  Future<XaiOAuthTokens> refresh(String refreshToken) async {
    final response = await _http.post(
      Uri.parse(xaiOAuthTokenUrl),
      headers: const {'Accept': 'application/json'},
      body: {
        'grant_type': 'refresh_token',
        'client_id': xaiOAuthClientId,
        'refresh_token': refreshToken,
      },
    );
    if (response.statusCode == 403) {
      throw _forbidden();
    }
    if (response.statusCode != 200) {
      throw XaiOAuthException(
        'xAI could not refresh the session (HTTP ${response.statusCode}).',
      );
    }
    return _tokensFrom(_decode(response.body), previousRefresh: refreshToken);
  }

  void close() => _http.close();

  XaiOAuthTokens _tokensFrom(
    Map<String, Object?> body, {
    required String previousRefresh,
  }) {
    final accessToken = body['access_token'];
    if (accessToken is! String || accessToken.trim().isEmpty) {
      throw const XaiOAuthException('xAI did not return an access token.');
    }
    final refresh = body['refresh_token'];
    final expiresIn = body['expires_in'];
    return XaiOAuthTokens(
      accessToken: accessToken,
      refreshToken: refresh is String && refresh.trim().isNotEmpty
          ? refresh
          : previousRefresh,
      expiresAt: _clock().add(
        Duration(seconds: expiresIn is int ? expiresIn : 3600),
      ),
    );
  }

  Map<String, Object?> _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }

  String? _errorCode(String raw) {
    final code = _decode(raw)['error'];
    return code is String ? code : null;
  }

  XaiOAuthException _forbidden() => const XaiOAuthException(
    'xAI has not enabled OAuth for this account yet (HTTP 403). Sign in with '
    'an XAI_API_KEY instead.',
    forbidden: true,
  );
}
