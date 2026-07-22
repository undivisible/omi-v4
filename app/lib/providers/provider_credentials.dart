import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../native/generated/signals/signals.dart' show AssistantProvider;

final class ProviderCredential {
  const ProviderCredential({
    required this.provider,
    required this.model,
    required this.credential,
    this.endpoint,
  });

  final AssistantProvider provider;
  final String model;
  final String credential;
  final String? endpoint;
}

abstract interface class ProviderCredentialStore {
  Future<ProviderCredential?> read(String uid);
  Future<void> write(String uid, ProviderCredential value);
  Future<void> delete(String uid);
}

final class SecureProviderCredentialStore implements ProviderCredentialStore {
  const SecureProviderCredentialStore([
    this._storage = const FlutterSecureStorage(),
  ]);

  final FlutterSecureStorage _storage;

  @override
  Future<ProviderCredential?> read(String uid) async {
    final prefix = _prefix(uid);
    final values = await Future.wait([
      _storage.read(key: '${prefix}provider'),
      _storage.read(key: '${prefix}model'),
      _storage.read(key: '${prefix}credential'),
      _storage.read(key: '${prefix}endpoint'),
    ]);
    final [provider, model, credential, endpoint] = values;
    if (provider == null ||
        model == null ||
        model.trim().isEmpty ||
        credential == null ||
        credential.trim().isEmpty) {
      return null;
    }
    final parsed = AssistantProvider.values.where(
      (value) => value.name == provider,
    );
    if (parsed.length != 1 || parsed.single == AssistantProvider.worker) {
      return null;
    }
    if (parsed.single == AssistantProvider.compatible &&
        !_safeEndpoint(endpoint)) {
      return null;
    }
    return ProviderCredential(
      provider: parsed.single,
      model: model.trim(),
      credential: credential.trim(),
      endpoint: parsed.single == AssistantProvider.compatible
          ? endpoint?.trim()
          : null,
    );
  }

  @override
  Future<void> write(String uid, ProviderCredential value) async {
    if (uid.trim().isEmpty ||
        value.provider == AssistantProvider.worker ||
        value.model.trim().isEmpty ||
        value.credential.trim().isEmpty ||
        (value.provider == AssistantProvider.compatible &&
            !_safeEndpoint(value.endpoint))) {
      throw ArgumentError('Invalid provider credential');
    }
    final prefix = _prefix(uid);
    await _storage.write(key: '${prefix}provider', value: value.provider.name);
    await _storage.write(key: '${prefix}model', value: value.model.trim());
    await _storage.write(
      key: '${prefix}credential',
      value: value.credential.trim(),
    );
    if (value.endpoint case final endpoint?) {
      await _storage.write(key: '${prefix}endpoint', value: endpoint.trim());
    } else {
      await _storage.delete(key: '${prefix}endpoint');
    }
  }

  @override
  Future<void> delete(String uid) async {
    final prefix = _prefix(uid);
    for (final field in const ['provider', 'model', 'credential', 'endpoint']) {
      await _storage.delete(key: '$prefix$field');
    }
  }

  String _prefix(String uid) => 'omi.ai.${Uri.encodeComponent(uid)}.';

  bool _safeEndpoint(String? value) {
    final uri = value == null ? null : Uri.tryParse(value.trim());
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment;
  }
}

final class VolatileProviderCredentialStore implements ProviderCredentialStore {
  final values = <String, ProviderCredential>{};

  @override
  Future<ProviderCredential?> read(String uid) async => values[uid];

  @override
  Future<void> write(String uid, ProviderCredential value) async {
    values[uid] = value;
  }

  @override
  Future<void> delete(String uid) async {
    values.remove(uid);
  }
}
