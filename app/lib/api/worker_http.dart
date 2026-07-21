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

  Future<({int statusCode, Object? body})> send({
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
    return (statusCode: response.statusCode, body: decoded);
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

final class WorkerAuthenticationException implements Exception {
  const WorkerAuthenticationException(this.message);

  final String message;
}

final class WorkerResponseException implements Exception {
  const WorkerResponseException(this.message);

  final String message;
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
