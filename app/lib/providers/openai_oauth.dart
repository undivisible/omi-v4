import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../integrations/oauth/oauth_pkce.dart';

/// OpenAI's sanctioned Codex CLI desktop OAuth client, the same public client
/// Zed drives for its "ChatGPT subscription" provider (authorization-code +
/// PKCE, loopback redirect, no client secret). The client id, authorize/token
/// URLs and the Codex inference base are transcribed from
/// `zed-industries/zed`, `crates/language_models/src/provider/openai_subscribed.rs`
/// (PR #53166 / stable cherry-pick #56811). The registered client only allows
/// the Codex CLI's own loopback redirect URIs, so the ports and path below are
/// fixed rather than free.
const openAiOAuthClientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
const openAiAuthorizeUrl = 'https://auth.openai.com/oauth/authorize';
const openAiTokenUrl = 'https://auth.openai.com/oauth/token';
const openAiOAuthScope = 'openid profile email offline_access';

/// The Codex Responses-API base the OAuth bearer is entitled to. Chat
/// Completions was retired for this surface in Feb 2026; only the Responses
/// endpoint (`$openAiCodexBaseUrl/responses`) is served.
const openAiCodexBaseUrl = 'https://chatgpt.com/backend-api/codex';

/// The Codex CLI client's allow-listed loopback redirect URIs. A different
/// host, port or path makes `auth.openai.com` reject the authorize request.
const _callbackHost = '127.0.0.1';
const _callbackPorts = [1455, 1457];
const _callbackPath = '/auth/callback';

/// The tokens a successful ChatGPT sign-in (or refresh) yields. [accountId] is
/// the `chatgpt_account_id` claim the Codex endpoint needs as a header; the hub
/// re-derives it from the bearer, so it is carried here only for reference.
final class OpenAiOAuthTokens {
  const OpenAiOAuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.accountId,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String? accountId;
}

/// A terminal OpenAI OAuth failure. [forbidden] is set when the Codex surface
/// answers HTTP 403 — a signed-in account that is not entitled to Codex — so
/// the UI can steer the user to an `OPENAI_API_KEY` instead.
final class OpenAiOAuthException implements Exception {
  const OpenAiOAuthException(this.message, {this.forbidden = false});

  final String message;
  final bool forbidden;

  @override
  String toString() => message;
}

/// Drives the ChatGPT-subscription authorization-code + PKCE flow: it stands up
/// a loopback listener, hands the caller the authorize URL to open, captures the
/// redirect, exchanges the code, and refreshes tokens. [http.Client] and
/// [clock] are injectable for tests; [bindServer] lets a test capture the
/// redirect without a real socket.
final class OpenAiOAuthClient {
  OpenAiOAuthClient({
    http.Client? httpClient,
    DateTime Function()? clock,
    Future<HttpServer> Function(String host, int port)? bindServer,
  }) : _http = httpClient ?? http.Client(),
       _clock = clock ?? DateTime.now,
       _bind = bindServer ?? HttpServer.bind;

  final http.Client _http;
  final DateTime Function() _clock;
  final Future<HttpServer> Function(String host, int port) _bind;

  /// Binds the loopback listener and returns the authorize URL to open plus a
  /// [OpenAiPendingLogin] the caller awaits for the exchanged tokens.
  Future<OpenAiPendingLogin> beginSignIn() async {
    final pkce = PkcePair.generate();
    final state = generateOAuthState();
    HttpServer? server;
    var boundPort = _callbackPorts.first;
    for (final port in _callbackPorts) {
      try {
        server = await _bind(_callbackHost, port);
        boundPort = port;
        break;
      } on SocketException {
        continue;
      }
    }
    if (server == null) {
      throw const OpenAiOAuthException(
        'Could not open a local sign-in listener on port 1455 or 1457. Close '
        'anything using those ports, or sign in with an OPENAI_API_KEY.',
      );
    }
    final redirectUri = 'http://$_callbackHost:$boundPort$_callbackPath';
    final authorizeUri = Uri.parse(openAiAuthorizeUrl).replace(
      queryParameters: {
        'client_id': openAiOAuthClientId,
        'redirect_uri': redirectUri,
        'scope': openAiOAuthScope,
        'response_type': 'code',
        'code_challenge': pkce.challenge,
        'code_challenge_method': pkce.method,
        'id_token_add_organizations': 'true',
        'state': state,
        'codex_cli_simplified_flow': 'true',
        'originator': 'omi',
      },
    );
    final tokens = _await(server, state, pkce, redirectUri);
    return OpenAiPendingLogin(authorizeUrl: authorizeUri, tokens: tokens);
  }

  Future<OpenAiOAuthTokens> _await(
    HttpServer server,
    String state,
    PkcePair pkce,
    String redirectUri,
  ) async {
    try {
      await for (final request in server) {
        final uri = request.uri;
        if (uri.path != _callbackPath) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          continue;
        }
        final code = uri.queryParameters['code'];
        final returnedState = uri.queryParameters['state'];
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(
            '<html><body style="font-family:sans-serif;padding:2rem">'
            'You can close this tab and return to Omi.</body></html>',
          );
        await request.response.close();
        if (returnedState != state) {
          throw const OpenAiOAuthException('Sign-in state did not match.');
        }
        if (code == null || code.isEmpty) {
          final error = uri.queryParameters['error'] ?? 'no authorization code';
          throw OpenAiOAuthException('ChatGPT sign-in was declined: $error.');
        }
        return _exchangeCode(code, pkce, redirectUri);
      }
      throw const OpenAiOAuthException('Sign-in was cancelled.');
    } finally {
      await server.close(force: true);
    }
  }

  Future<OpenAiOAuthTokens> _exchangeCode(
    String code,
    PkcePair pkce,
    String redirectUri,
  ) async {
    final response = await _http.post(
      Uri.parse(openAiTokenUrl),
      headers: const {'Accept': 'application/json'},
      body: {
        'grant_type': 'authorization_code',
        'client_id': openAiOAuthClientId,
        'code': code,
        'redirect_uri': redirectUri,
        'code_verifier': pkce.verifier,
      },
    );
    return _tokensFrom(response, previousRefresh: '');
  }

  /// Exchanges a refresh token for a fresh access token.
  Future<OpenAiOAuthTokens> refresh(String refreshToken) async {
    final response = await _http.post(
      Uri.parse(openAiTokenUrl),
      headers: const {'Accept': 'application/json'},
      body: {
        'grant_type': 'refresh_token',
        'client_id': openAiOAuthClientId,
        'refresh_token': refreshToken,
      },
    );
    return _tokensFrom(response, previousRefresh: refreshToken);
  }

  void close() => _http.close();

  OpenAiOAuthTokens _tokensFrom(
    http.Response response, {
    required String previousRefresh,
  }) {
    if (response.statusCode == 403) {
      throw const OpenAiOAuthException(
        'This ChatGPT account is not entitled to Codex (HTTP 403). Sign in '
        'with an OPENAI_API_KEY instead.',
        forbidden: true,
      );
    }
    if (response.statusCode != 200) {
      throw OpenAiOAuthException(
        'OpenAI sign-in failed (HTTP ${response.statusCode}).',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const OpenAiOAuthException('OpenAI returned an unreadable reply.');
    }
    if (decoded is! Map<String, Object?>) {
      throw const OpenAiOAuthException('OpenAI returned an unreadable reply.');
    }
    final accessToken = decoded['access_token'];
    if (accessToken is! String || accessToken.trim().isEmpty) {
      throw const OpenAiOAuthException(
        'OpenAI did not return an access token.',
      );
    }
    final refresh = decoded['refresh_token'];
    final expiresIn = decoded['expires_in'];
    final idToken = decoded['id_token'];
    return OpenAiOAuthTokens(
      accessToken: accessToken,
      refreshToken: refresh is String && refresh.trim().isNotEmpty
          ? refresh
          : previousRefresh,
      expiresAt: _clock().add(
        Duration(seconds: expiresIn is int ? expiresIn : 3600),
      ),
      accountId:
          _accountIdFrom(idToken is String ? idToken : null) ??
          _accountIdFrom(accessToken),
    );
  }
}

/// A sign-in in progress: the URL the user must open, and the future that
/// completes with tokens once they approve.
final class OpenAiPendingLogin {
  const OpenAiPendingLogin({required this.authorizeUrl, required this.tokens});

  final Uri authorizeUrl;
  final Future<OpenAiOAuthTokens> tokens;
}

/// Reads the `chatgpt_account_id` claim out of a JWT, matching the locations
/// Zed's `extract_jwt_claims` checks (top level, then the
/// `https://api.openai.com/auth` namespaced object).
String? _accountIdFrom(String? jwt) {
  if (jwt == null) return null;
  final parts = jwt.split('.');
  if (parts.length < 2) return null;
  try {
    final payload = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    final claims = jsonDecode(payload);
    if (claims is! Map) return null;
    final direct = claims['chatgpt_account_id'];
    if (direct is String && direct.isNotEmpty) return direct;
    final auth = claims['https://api.openai.com/auth'];
    if (auth is Map) {
      final nested = auth['chatgpt_account_id'];
      if (nested is String && nested.isNotEmpty) return nested;
    }
  } catch (_) {
    return null;
  }
  return null;
}
