import 'settings_models.dart';

enum SettingsHttpMethod { get, put }

final class SettingsRequest {
  const SettingsRequest({required this.method, required this.path, this.body});

  final SettingsHttpMethod method;
  final String path;
  final SettingsJson? body;
}

final class SettingsResponse {
  const SettingsResponse({required this.statusCode, this.body});

  final int statusCode;
  final Object? body;
}

abstract interface class SettingsTransport {
  Future<SettingsResponse> send(SettingsRequest request);
}

sealed class SettingsClientException implements Exception {
  const SettingsClientException(this.message);

  final String message;
}

final class SettingsTransportException extends SettingsClientException {
  const SettingsTransportException(super.message);
}

final class SettingsDecodingException extends SettingsClientException {
  const SettingsDecodingException(super.message);
}

sealed class SettingsRejectedException extends SettingsClientException {
  const SettingsRejectedException(super.message);
}

final class SettingsConflictException extends SettingsRejectedException {
  const SettingsConflictException(super.message, {required this.revision});

  final int revision;
}

final class SettingsConfirmationRequiredException
    extends SettingsRejectedException {
  const SettingsConfirmationRequiredException(super.message);
}

final class SettingsApiException extends SettingsRejectedException {
  const SettingsApiException(this.statusCode, super.message);

  final int statusCode;
}

final class SettingsClient {
  const SettingsClient(this._transport);

  final SettingsTransport _transport;

  Future<SettingsSnapshot> getSettings() async {
    final response = await _send(
      const SettingsRequest(
        method: SettingsHttpMethod.get,
        path: '/v1/settings',
      ),
    );
    return _decode(response.body, SettingsSnapshot.fromJson);
  }

  Future<SettingsChangeResult> changeSettings({
    required int expectedRevision,
    required SettingsPatch patch,
    required SettingsScope scope,
    String? confirmationReceiptId,
  }) async {
    if (expectedRevision < 0) {
      throw const SettingsDecodingException(
        'expectedRevision must not be negative',
      );
    }
    if (patch.isEmpty) {
      throw const SettingsDecodingException('patch must not be empty');
    }
    final response = await _send(
      SettingsRequest(
        method: SettingsHttpMethod.put,
        path: '/v1/settings',
        body: {
          'expectedRevision': expectedRevision,
          'patch': patch.toJson(),
          ...scope.toJson(),
          'confirmationReceiptId': ?confirmationReceiptId,
        },
      ),
    );
    return _decode(response.body, SettingsChangeResult.fromJson);
  }

  Future<SettingsResponse> _send(SettingsRequest request) async {
    final SettingsResponse response;
    try {
      response = await _transport.send(request);
    } on SettingsClientException {
      rethrow;
    } catch (error) {
      throw SettingsTransportException(error.toString());
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    final error = _errorBody(response.body);
    if (response.statusCode == 409) {
      final revision = error['revision'];
      if (revision is! int || revision < 0) {
        throw const SettingsDecodingException(
          'conflict response requires a non-negative revision',
        );
      }
      throw SettingsConflictException(
        error['error']! as String,
        revision: revision,
      );
    }
    if (response.statusCode == 403 &&
        error['error'] == 'Owner confirmation required') {
      throw SettingsConfirmationRequiredException(error['error']! as String);
    }
    throw SettingsApiException(response.statusCode, error['error']! as String);
  }

  SettingsJson _errorBody(Object? value) {
    if (value is! Map<String, Object?> || value['error'] is! String) {
      throw const SettingsDecodingException(
        'error response must contain an error string',
      );
    }
    return value;
  }

  T _decode<T>(Object? value, T Function(SettingsJson) decode) {
    try {
      if (value is! Map<String, Object?>) {
        throw const SettingsFormatException('response must be an object');
      }
      return decode(value);
    } on SettingsFormatException catch (error) {
      throw SettingsDecodingException(error.message);
    } on TypeError catch (error) {
      throw SettingsDecodingException(error.toString());
    }
  }
}
