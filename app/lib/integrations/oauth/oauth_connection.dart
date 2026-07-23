import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A live connection to one provider. This is the only record that ever holds
/// a token, and it is only ever written to the platform keychain.
@immutable
final class OAuthConnection {
  const OAuthConnection({
    required this.connectorId,
    required this.accessToken,
    required this.expiresAt,
    required this.grantedScopes,
    this.refreshToken,
    this.account,
    this.needsReconnect = false,
  });

  final String connectorId;
  final String accessToken;

  /// Absolute UTC expiry of [accessToken].
  final DateTime expiresAt;

  /// What the provider actually granted, which can be narrower than what was
  /// requested. The settings UI reads this, never the requested list.
  final List<String> grantedScopes;

  final String? refreshToken;

  /// Human-readable account label, when the provider returned one.
  final String? account;

  /// Set once the provider has told us the refresh token is dead. A connection
  /// in this state is never retried automatically — it waits for the user.
  final bool needsReconnect;

  bool expiresWithin(Duration skew, {DateTime? now}) =>
      (now ?? DateTime.now().toUtc()).add(skew).isAfter(expiresAt);

  OAuthConnection copyWith({
    String? accessToken,
    DateTime? expiresAt,
    List<String>? grantedScopes,
    String? refreshToken,
    String? account,
    bool? needsReconnect,
  }) => OAuthConnection(
    connectorId: connectorId,
    accessToken: accessToken ?? this.accessToken,
    expiresAt: expiresAt ?? this.expiresAt,
    grantedScopes: grantedScopes ?? this.grantedScopes,
    refreshToken: refreshToken ?? this.refreshToken,
    account: account ?? this.account,
    needsReconnect: needsReconnect ?? this.needsReconnect,
  );

  Map<String, Object?> toJson() => {
    'connectorId': connectorId,
    'accessToken': accessToken,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'grantedScopes': grantedScopes,
    if (refreshToken != null) 'refreshToken': refreshToken,
    if (account != null) 'account': account,
    if (needsReconnect) 'needsReconnect': true,
  };

  static OAuthConnection? fromJson(Object? value) {
    if (value is! Map) return null;
    final connectorId = value['connectorId'];
    final accessToken = value['accessToken'];
    final expiresAt = DateTime.tryParse('${value['expiresAt']}');
    final scopes = value['grantedScopes'];
    final refreshToken = value['refreshToken'];
    final account = value['account'];
    if (connectorId is! String ||
        connectorId.trim().isEmpty ||
        accessToken is! String ||
        expiresAt == null ||
        scopes is! List ||
        (refreshToken != null && refreshToken is! String) ||
        (account != null && account is! String)) {
      return null;
    }
    return OAuthConnection(
      connectorId: connectorId,
      accessToken: accessToken,
      expiresAt: expiresAt.toUtc(),
      grantedScopes: [for (final scope in scopes) '$scope'],
      refreshToken: refreshToken as String?,
      account: account as String?,
      needsReconnect: value['needsReconnect'] == true,
    );
  }
}

abstract interface class OAuthConnectionStore {
  Future<OAuthConnection?> read(String uid, String connectorId);
  Future<List<OAuthConnection>> readAll(String uid);
  Future<void> write(String uid, OAuthConnection value);
  Future<void> remove(String uid, String connectorId);
  Future<void> delete(String uid);
}

/// Keychain-backed storage, mirroring [SecureProviderCredentialStore]: one
/// UID-scoped JSON blob in `flutter_secure_storage`, nothing in preferences and
/// nothing on disk.
final class SecureOAuthConnectionStore implements OAuthConnectionStore {
  const SecureOAuthConnectionStore([
    this._storage = const FlutterSecureStorage(),
  ]);

  final FlutterSecureStorage _storage;

  @override
  Future<OAuthConnection?> read(String uid, String connectorId) async {
    final all = await readAll(uid);
    for (final value in all) {
      if (value.connectorId == connectorId) return value;
    }
    return null;
  }

  @override
  Future<List<OAuthConnection>> readAll(String uid) async {
    final raw = await _storage.read(key: _key(uid));
    if (raw == null) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (decoded is! List) return const [];
    final parsed = decoded.map(OAuthConnection.fromJson).toList();
    if (parsed.any((value) => value == null)) return const [];
    return parsed.cast<OAuthConnection>();
  }

  @override
  Future<void> write(String uid, OAuthConnection value) async {
    if (uid.trim().isEmpty) throw ArgumentError('Missing uid');
    final all = await readAll(uid);
    await _writeAll(uid, [
      value,
      ...all.where((existing) => existing.connectorId != value.connectorId),
    ]);
  }

  @override
  Future<void> remove(String uid, String connectorId) async {
    final next = (await readAll(uid))
        .where((existing) => existing.connectorId != connectorId)
        .toList(growable: false);
    if (next.isEmpty) {
      await delete(uid);
      return;
    }
    await _writeAll(uid, next);
  }

  @override
  Future<void> delete(String uid) => _storage.delete(key: _key(uid));

  Future<void> _writeAll(String uid, List<OAuthConnection> values) =>
      _storage.write(
        key: _key(uid),
        value: jsonEncode([for (final value in values) value.toJson()]),
      );

  String _key(String uid) => 'omi.oauth.${Uri.encodeComponent(uid)}.connections';
}

/// In-memory store for tests and previews.
final class VolatileOAuthConnectionStore implements OAuthConnectionStore {
  final values = <String, List<OAuthConnection>>{};

  @override
  Future<OAuthConnection?> read(String uid, String connectorId) async {
    for (final value in values[uid] ?? const <OAuthConnection>[]) {
      if (value.connectorId == connectorId) return value;
    }
    return null;
  }

  @override
  Future<List<OAuthConnection>> readAll(String uid) async =>
      List.unmodifiable(values[uid] ?? const []);

  @override
  Future<void> write(String uid, OAuthConnection value) async {
    final all = values[uid] ?? const <OAuthConnection>[];
    values[uid] = [
      value,
      ...all.where((existing) => existing.connectorId != value.connectorId),
    ];
  }

  @override
  Future<void> remove(String uid, String connectorId) async {
    final all = values[uid];
    if (all == null) return;
    final next = all
        .where((existing) => existing.connectorId != connectorId)
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
