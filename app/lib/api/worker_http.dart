import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth.dart';
import '../channels/channels.dart';
import '../memory/memory.dart';
import '../settings/settings.dart';

final class WorkerHttpClient {
  WorkerHttpClient({
    required Uri baseUri,
    required this.sessionProvider,
    http.Client? client,
  }) : _baseUri = _validateBaseUri(baseUri),
       _client = client ?? http.Client();

  final Uri _baseUri;
  final Future<AuthSession?> Function() sessionProvider;
  final http.Client _client;

  Uri get trustedOrigin {
    if (_baseUri.scheme != 'https') {
      throw StateError('Managed Worker features require an HTTPS API origin.');
    }
    return _baseUri.replace(path: '/', query: null, fragment: null);
  }

  Future<({int statusCode, Object? body})> send({
    required String method,
    required String path,
    Map<String, String> query = const {},
    Map<String, Object?>? body,
  }) async {
    final response = await sendWithSession(
      method: method,
      path: path,
      query: query,
      body: body,
    );
    return (statusCode: response.statusCode, body: response.body);
  }

  Future<({AuthSession session, int statusCode, Object? body})>
  sendWithSession({
    required String method,
    required String path,
    Map<String, String> query = const {},
    Map<String, Object?>? body,
  }) async {
    final session = await sessionProvider();
    if (session == null || session.idToken.isEmpty) {
      throw const WorkerAuthenticationException('Sign in is required');
    }
    if (!session.expiresAt.isAfter(DateTime.now())) {
      throw const WorkerAuthenticationException('Session expired');
    }
    final uri = _baseUri.resolve(path).replace(queryParameters: query);
    final response = await _client.send(
      http.Request(method, uri)
        ..headers.addAll({
          'accept': 'application/json',
          'authorization': 'Bearer ${session.idToken}',
          if (body != null) 'content-type': 'application/json',
        })
        ..body = body == null ? '' : jsonEncode(body),
    );
    final text = await response.stream.bytesToString();
    Object? decoded;
    if (text.isNotEmpty) {
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        throw const WorkerResponseException('Worker returned invalid JSON');
      }
    }
    return (session: session, statusCode: response.statusCode, body: decoded);
  }

  void close() => _client.close();

  static Uri _validateBaseUri(Uri uri) {
    final loopback = {
      'localhost',
      '127.0.0.1',
      '::1',
    }.contains(uri.host.toLowerCase());
    if ((uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ArgumentError.value(
        uri,
        'baseUri',
        'must use HTTPS unless the host is loopback',
      );
    }
    return uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');
  }
}

enum OmiPlan { byok, pro }

final class BillingEntitlement {
  const BillingEntitlement({required this.plan, required this.active});

  final OmiPlan plan;
  final bool active;
}

final class WorkerBillingClient {
  const WorkerBillingClient(this._client);

  final WorkerHttpClient _client;

  Future<BillingEntitlement> getEntitlement() async {
    final response = await _client.send(method: 'GET', path: '/v1/entitlement');
    final body = _object(response, const {'plan', 'active'});
    final plan = body['plan'];
    final active = body['active'];
    if ((plan != 'byok' && plan != 'pro') || active is! bool) {
      throw const WorkerResponseException(
        'Worker returned invalid entitlement',
      );
    }
    return BillingEntitlement(
      plan: plan == 'pro' ? OmiPlan.pro : OmiPlan.byok,
      active: active,
    );
  }

  Future<Uri> createCheckout() => _session('/v1/payments/stripe/checkout');

  Future<Uri> createPortal() => _session('/v1/payments/stripe/portal');

  Future<Uri> _session(String path) async {
    final response = await _client.send(method: 'POST', path: path);
    final body = _object(response, const {'id', 'url'});
    if (body['id'] is! String || body['url'] is! String) {
      throw const WorkerResponseException(
        'Worker returned invalid billing session',
      );
    }
    final uri = Uri.tryParse(body['url']! as String);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const WorkerResponseException('Worker returned unsafe billing URL');
    }
    return uri;
  }

  Map<String, Object?> _object(
    ({int statusCode, Object? body}) response,
    Set<String> fields,
  ) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = response.body;
      final message = body is Map<String, Object?> && body['error'] is String
          ? body['error']! as String
          : 'Billing request failed';
      throw WorkerResponseException(message);
    }
    final body = response.body;
    if (body is! Map<String, Object?> ||
        body.keys.any((key) => !fields.contains(key)) ||
        fields.any((key) => !body.containsKey(key))) {
      throw const WorkerResponseException(
        'Worker returned invalid billing response',
      );
    }
    return body;
  }
}

final class OAuthDeviceStart {
  const OAuthDeviceStart({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.interval,
    required this.expiresIn,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int interval;
  final int expiresIn;
}

enum OAuthDevicePoll { connected, pending, slowDown }

final class WorkerOAuthClient {
  const WorkerOAuthClient(this._client);

  final WorkerHttpClient _client;

  Future<OAuthDeviceStart> startDevice(String provider) async {
    final response = await _client.send(
      method: 'POST',
      path: '/v1/oauth/$provider/device/start',
    );
    final body = response.body;
    if (response.statusCode != 200 ||
        body is! Map<String, Object?> ||
        body['deviceCode'] is! String ||
        body['userCode'] is! String) {
      throw WorkerResponseException(
        body is Map<String, Object?> && body['error'] is String
            ? body['error']! as String
            : 'Sign-in is unavailable',
      );
    }
    return OAuthDeviceStart(
      deviceCode: body['deviceCode']! as String,
      userCode: body['userCode']! as String,
      verificationUri: body['verificationUri'] is String
          ? body['verificationUri']! as String
          : '',
      interval: body['interval'] is int ? body['interval']! as int : 5,
      expiresIn: body['expiresIn'] is int ? body['expiresIn']! as int : 300,
    );
  }

  /// Returns connected on success, pending while authorization is pending,
  /// and slowDown when the provider asked for a longer poll interval.
  Future<OAuthDevicePoll> pollDevice(String provider, String deviceCode) async {
    final response = await _client.send(
      method: 'POST',
      path: '/v1/oauth/$provider/device/poll',
      body: {'deviceCode': deviceCode},
    );
    if (response.statusCode == 202) {
      final pendingBody = response.body;
      return pendingBody is Map<String, Object?> &&
              pendingBody['error'] == 'slow_down'
          ? OAuthDevicePoll.slowDown
          : OAuthDevicePoll.pending;
    }
    final body = response.body;
    if (response.statusCode != 200 ||
        body is! Map<String, Object?> ||
        body['connected'] != true) {
      throw WorkerResponseException(
        body is Map<String, Object?> && body['error'] is String
            ? body['error']! as String
            : 'Sign-in failed',
      );
    }
    return OAuthDevicePoll.connected;
  }

  Future<List<String>> connectedProviders() async {
    final response = await _client.send(
      method: 'GET',
      path: '/v1/oauth/status',
    );
    final body = response.body;
    if (response.statusCode != 200 ||
        body is! Map<String, Object?> ||
        body['connections'] is! List) {
      throw const WorkerResponseException('Could not load connections');
    }
    return [
      for (final row in body['connections']! as List)
        if (row is Map && row['provider'] is String) row['provider'] as String,
    ];
  }

  Future<void> disconnect(String provider) async {
    await _client.send(method: 'DELETE', path: '/v1/oauth/$provider');
  }
}

final class GeminiLiveToken {
  const GeminiLiveToken({
    required this.token,
    required this.model,
    required this.expireTime,
    required this.newSessionExpireTime,
  });

  final String token;
  final String model;
  final DateTime expireTime;
  final DateTime newSessionExpireTime;
}

abstract interface class LiveVoiceTokenClient {
  Future<GeminiLiveToken> createGeminiToken();
}

final class WorkerVoiceClient implements LiveVoiceTokenClient {
  const WorkerVoiceClient(this._client);

  final WorkerHttpClient _client;

  @override
  Future<GeminiLiveToken> createGeminiToken() async {
    final response = await _client.send(
      method: 'POST',
      path: '/v1/voice/gemini/token',
    );
    if (response.statusCode != 200) {
      final body = response.body;
      throw WorkerResponseException(
        body is Map<String, Object?> && body['error'] is String
            ? body['error']! as String
            : 'Live voice is unavailable (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
    final body = response.body;
    const fields = {'token', 'model', 'expireTime', 'newSessionExpireTime'};
    if (body is! Map<String, Object?> ||
        body.length != fields.length ||
        fields.any((key) => body[key] is! String)) {
      throw const WorkerResponseException(
        'Worker returned an invalid live voice token',
      );
    }
    final token = body['token']! as String;
    final model = body['model']! as String;
    final expireTime = DateTime.tryParse(body['expireTime']! as String);
    final newSessionExpireTime = DateTime.tryParse(
      body['newSessionExpireTime']! as String,
    );
    if (token.isEmpty ||
        token.length > 16384 ||
        token.codeUnits.any((unit) => unit <= 0x20 || unit >= 0x7f) ||
        model.isEmpty ||
        expireTime == null ||
        newSessionExpireTime == null) {
      throw const WorkerResponseException(
        'Worker returned an invalid live voice token',
      );
    }
    return GeminiLiveToken(
      token: token,
      model: model,
      expireTime: expireTime,
      newSessionExpireTime: newSessionExpireTime,
    );
  }
}

abstract interface class ManagedSttClient {
  Uri get trustedWorkerOrigin;

  Future<ManagedSttSession> createSession({
    required String idempotencyKey,
    required String deviceId,
    required String language,
    required ManagedSttEncoding encoding,
    required int sampleRate,
    required int channels,
  });
}

enum ManagedSttEncoding { linear16, opus }

final class ManagedSttSession {
  const ManagedSttSession({required this.websocketUrl, required this.session});

  final String websocketUrl;
  final AuthSession session;
}

final class WorkerManagedSttClient implements ManagedSttClient {
  const WorkerManagedSttClient(this._client);

  final WorkerHttpClient _client;

  @override
  Uri get trustedWorkerOrigin => _client.trustedOrigin;

  @override
  Future<ManagedSttSession> createSession({
    required String idempotencyKey,
    required String deviceId,
    required String language,
    required ManagedSttEncoding encoding,
    required int sampleRate,
    required int channels,
  }) async {
    final response = await _client.sendWithSession(
      method: 'POST',
      path: '/v1/stt/sessions',
      body: {
        'idempotencyKey': idempotencyKey,
        'model': 'nova-3',
        'language': language,
        'encoding': encoding.name,
        'sampleRate': sampleRate,
        'channels': channels,
        'diarize': true,
        'interimResults': true,
        'deviceId': deviceId,
        'sourceId': 'omi-device',
      },
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw WorkerResponseException(
        'Managed transcription session was rejected (${response.statusCode})',
      );
    }
    final body = response.body;
    if (body is! Map<String, Object?> ||
        body.keys.toSet().difference(const {
          'sessionId',
          'websocketUrl',
          'maxSessionSeconds',
          'state',
        }).isNotEmpty ||
        body.length != 4 ||
        body['sessionId'] is! String ||
        body['websocketUrl'] is! String ||
        body['maxSessionSeconds'] is! int ||
        body['state'] != 'ready') {
      throw const WorkerResponseException(
        'Worker returned an invalid transcription session',
      );
    }
    final sessionId = body['sessionId']! as String;
    final websocketUrl = Uri.tryParse(body['websocketUrl']! as String);
    final maxSessionSeconds = body['maxSessionSeconds']! as int;
    final loopback =
        websocketUrl != null &&
        {
          'localhost',
          '127.0.0.1',
          '::1',
        }.contains(websocketUrl.host.toLowerCase());
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sessionId) ||
        websocketUrl == null ||
        (websocketUrl.scheme != 'wss' &&
            !(websocketUrl.scheme == 'ws' && loopback)) ||
        websocketUrl.userInfo.isNotEmpty ||
        websocketUrl.hasQuery ||
        websocketUrl.hasFragment ||
        !websocketUrl.path.endsWith('/v1/stt/sessions/$sessionId/stream') ||
        maxSessionSeconds <= 0 ||
        maxSessionSeconds > 3600) {
      throw const WorkerResponseException(
        'Worker returned an invalid transcription session',
      );
    }
    return ManagedSttSession(
      websocketUrl: websocketUrl.toString(),
      session: response.session,
    );
  }
}

final class WorkerAuthenticationException implements Exception {
  const WorkerAuthenticationException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class WorkerResponseException implements Exception {
  const WorkerResponseException(this.message, {this.statusCode});

  final String message;

  /// HTTP status of the failed Worker response, when one was received.
  final int? statusCode;

  @override
  String toString() => message;
}

final class WorkerMemoryTransport implements MemoryTransport {
  const WorkerMemoryTransport(this._client);

  final WorkerHttpClient _client;

  @override
  Future<MemoryResponse> send(MemoryRequest request) async {
    final response = await _client.send(
      method: request.method.name.toUpperCase(),
      path: request.path,
      query: request.query,
      body: request.body,
    );
    return MemoryResponse(statusCode: response.statusCode, body: response.body);
  }
}

final class WorkerSettingsTransport implements SettingsTransport {
  const WorkerSettingsTransport(this._client);

  final WorkerHttpClient _client;

  @override
  Future<SettingsResponse> send(SettingsRequest request) async {
    final response = await _client.send(
      method: request.method.name.toUpperCase(),
      path: request.path,
      body: request.body,
    );
    return SettingsResponse(
      statusCode: response.statusCode,
      body: response.body,
    );
  }
}

final class WorkerChannelTransport implements AuthenticatedChannelTransport {
  const WorkerChannelTransport(this._client);

  final WorkerHttpClient _client;

  @override
  Future<ChannelResponse> sendAuthenticated(ChannelRequest request) async {
    final response = await _client.send(
      method: request.method.name.toUpperCase(),
      path: request.path,
    );
    return ChannelResponse(
      statusCode: response.statusCode,
      body: response.body,
    );
  }
}
