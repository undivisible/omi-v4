import 'channel_models.dart';

enum ChannelHttpMethod { get, post, delete }

final class ChannelRequest {
  const ChannelRequest({required this.method, required this.path, this.body});

  final ChannelHttpMethod method;
  final String path;
  final ChannelJson? body;
}

final class ChannelResponse {
  const ChannelResponse({required this.statusCode, this.body});

  final int statusCode;
  final Object? body;
}

abstract interface class AuthenticatedChannelTransport {
  Future<ChannelResponse> sendAuthenticated(ChannelRequest request);
}

sealed class ChannelClientException implements Exception {
  const ChannelClientException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class ChannelTransportException extends ChannelClientException {
  const ChannelTransportException(super.message);
}

final class ChannelApiException extends ChannelClientException {
  const ChannelApiException(this.statusCode, super.message);

  final int statusCode;
}

final class ChannelDecodingException extends ChannelClientException {
  const ChannelDecodingException(super.message);
}

final class ChannelClient {
  const ChannelClient(this._transport);

  final AuthenticatedChannelTransport _transport;

  Future<ChannelLinkToken> requestLink(ChannelProvider channel) async {
    final response = await _send(
      ChannelRequest(
        method: ChannelHttpMethod.post,
        path: '/v1/channels/${channel.name}/link',
      ),
    );
    final token = _decodeObject(response.body, ChannelLinkToken.fromJson);
    if (token.channel != channel) {
      throw const ChannelDecodingException(
        'response channel did not match request',
      );
    }
    return token;
  }

  Future<ChannelProvider> redeemCode(String code) async {
    final response = await _send(
      ChannelRequest(
        method: ChannelHttpMethod.post,
        path: '/v1/channels/link',
        body: {'code': code},
      ),
    );
    final body = _object(response.body);
    return ChannelProvider.fromJson(body['channel']);
  }

  Future<bool> isLinked(ChannelProvider channel) async {
    final response = await _send(
      const ChannelRequest(method: ChannelHttpMethod.get, path: '/v1/me'),
    );
    final body = _object(response.body);
    final channels = body['channels'];
    if (channels is! List<Object?>) {
      throw const ChannelDecodingException('channels must be a list');
    }
    return channels
        .map((value) => _decodeObject(value, LinkedChannelIdentity.fromJson))
        .any((identity) => identity.channel == channel);
  }

  Future<void> unlink(ChannelProvider channel) async {
    await _send(
      ChannelRequest(
        method: ChannelHttpMethod.delete,
        path: '/v1/channels/${channel.name}/link',
      ),
    );
  }

  Future<ChannelResponse> _send(ChannelRequest request) async {
    final ChannelResponse response;
    try {
      response = await _transport.sendAuthenticated(request);
    } on ChannelClientException {
      rethrow;
    } catch (error) {
      throw ChannelTransportException(error.toString());
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = response.body;
      final message = body is Map && body['error'] is String
          ? body['error']! as String
          : 'Channel request failed';
      throw ChannelApiException(response.statusCode, message);
    }
    return response;
  }

  T _decodeObject<T>(Object? value, T Function(ChannelJson) decode) {
    try {
      return decode(_object(value));
    } on ChannelFormatException catch (error) {
      throw ChannelDecodingException(error.message);
    } on TypeError catch (error) {
      throw ChannelDecodingException(error.toString());
    }
  }

  ChannelJson _object(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const ChannelDecodingException('response must be an object');
    }
    return value;
  }
}
