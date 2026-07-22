import 'dart:convert';

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

  Map<String, Object?> toJson() => {
    'provider': provider.name,
    'model': model,
    'credential': credential,
    if (endpoint != null) 'endpoint': endpoint,
  };

  static ProviderCredential? fromJson(Object? value) {
    if (value is! Map) return null;
    final provider = AssistantProvider.values.where(
      (candidate) => candidate.name == value['provider'],
    );
    final model = value['model'];
    final credential = value['credential'];
    final endpoint = value['endpoint'];
    if (provider.length != 1 ||
        provider.single == AssistantProvider.worker ||
        model is! String ||
        model.trim().isEmpty ||
        credential is! String ||
        credential.trim().isEmpty ||
        (endpoint != null && endpoint is! String)) {
      return null;
    }
    return ProviderCredential(
      provider: provider.single,
      model: model.trim(),
      credential: credential.trim(),
      endpoint: (endpoint as String?)?.trim(),
    );
  }
}

abstract interface class ProviderCredentialStore {
  Future<ProviderCredential?> read(String uid);
  Future<List<ProviderCredential>> readAll(String uid);
  Future<void> write(String uid, ProviderCredential value);
  Future<void> remove(String uid, AssistantProvider provider);
  Future<void> delete(String uid);
}

final class SecureProviderCredentialStore implements ProviderCredentialStore {
  const SecureProviderCredentialStore([
    this._storage = const FlutterSecureStorage(),
  ]);

  final FlutterSecureStorage _storage;

  // The first stored credential is the one automatically routed to; the
  // rest stay available for switching without re-entering keys.
  @override
  Future<ProviderCredential?> read(String uid) async {
    final all = await readAll(uid);
    return all.isEmpty ? null : all.first;
  }

  @override
  Future<List<ProviderCredential>> readAll(String uid) async {
    final prefix = _prefix(uid);
    final raw = await _storage.read(key: '${prefix}providers');
    if (raw != null) {
      final decoded = _decodeList(raw);
      if (decoded != null) return decoded;
    }
    final legacy = await _readLegacy(prefix);
    if (legacy == null) return const [];
    if (!_valid(legacy)) return const [];
    return [legacy];
  }

  @override
  Future<void> write(String uid, ProviderCredential value) async {
    if (uid.trim().isEmpty || !_valid(value)) {
      throw ArgumentError('Invalid provider credential');
    }
    final all = await readAll(uid);
    final next = [
      value,
      ...all.where((existing) => existing.provider != value.provider),
    ];
    await _writeAll(uid, next);
  }

  @override
  Future<void> remove(String uid, AssistantProvider provider) async {
    final all = await readAll(uid);
    final next = all
        .where((existing) => existing.provider != provider)
        .toList(growable: false);
    if (next.isEmpty) {
      await delete(uid);
      return;
    }
    await _writeAll(uid, next);
  }

  @override
  Future<void> delete(String uid) async {
    final prefix = _prefix(uid);
    for (final field in const [
      'providers',
      'provider',
      'model',
      'credential',
      'endpoint',
    ]) {
      await _storage.delete(key: '$prefix$field');
    }
  }

  Future<void> _writeAll(String uid, List<ProviderCredential> values) async {
    final prefix = _prefix(uid);
    await _storage.write(
      key: '${prefix}providers',
      value: jsonEncode([for (final value in values) value.toJson()]),
    );
    for (final field in const ['provider', 'model', 'credential', 'endpoint']) {
      await _storage.delete(key: '$prefix$field');
    }
  }

  Future<ProviderCredential?> _readLegacy(String prefix) async {
    final values = await Future.wait([
      _storage.read(key: '${prefix}provider'),
      _storage.read(key: '${prefix}model'),
      _storage.read(key: '${prefix}credential'),
      _storage.read(key: '${prefix}endpoint'),
    ]);
    final [provider, model, credential, endpoint] = values;
    if (provider == null || model == null || credential == null) return null;
    return ProviderCredential.fromJson({
      'provider': provider,
      'model': model,
      'credential': credential,
      'endpoint': ?endpoint,
    });
  }

  List<ProviderCredential>? _decodeList(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! List) return null;
    final parsed = decoded.map(ProviderCredential.fromJson).toList();
    if (parsed.any((value) => value == null || !_valid(value))) return null;
    return parsed.cast<ProviderCredential>();
  }

  bool _valid(ProviderCredential value) =>
      value.provider != AssistantProvider.worker &&
      value.model.trim().isNotEmpty &&
      value.credential.trim().isNotEmpty &&
      (value.provider != AssistantProvider.compatible ||
          _safeEndpoint(value.endpoint));

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
  final values = <String, List<ProviderCredential>>{};

  @override
  Future<ProviderCredential?> read(String uid) async {
    final all = values[uid];
    return all == null || all.isEmpty ? null : all.first;
  }

  @override
  Future<List<ProviderCredential>> readAll(String uid) async =>
      List.unmodifiable(values[uid] ?? const []);

  @override
  Future<void> write(String uid, ProviderCredential value) async {
    final all = values[uid] ?? const [];
    values[uid] = [
      value,
      ...all.where((existing) => existing.provider != value.provider),
    ];
  }

  @override
  Future<void> remove(String uid, AssistantProvider provider) async {
    final all = values[uid];
    if (all == null) return;
    final next = all
        .where((existing) => existing.provider != provider)
        .toList(growable: false);
    if (next.isEmpty) {
      values.remove(uid);
    } else {
      values[uid] = next;
    }
  }

  @override
  Future<void> delete(String uid) async {
    values.remove(uid);
  }
}
