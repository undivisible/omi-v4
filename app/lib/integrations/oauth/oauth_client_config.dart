import 'package:shared_preferences/shared_preferences.dart';

/// Build-time client ids, one define per connector: for Google, pass
/// `--dart-define=OMI_OAUTH_CLIENT_ID_GOOGLE=...`. A client id is a public
/// identifier, not a secret, so this is the one piece of connector
/// configuration that is allowed outside the keychain. There is deliberately
/// no client-secret equivalent: the desktop flow is PKCE only.
const _defines = <String, String>{
  'google': String.fromEnvironment('OMI_OAUTH_CLIENT_ID_GOOGLE'),
};

/// Where the client id the user pasted lives. Not a token, so preferences are
/// the right home — tokens never come near this store.
abstract interface class OAuthClientIdStore {
  Future<String?> read(String connectorId);
  Future<void> write(String connectorId, String clientId);
  Future<void> clear(String connectorId);
}

final class PreferencesOAuthClientIdStore implements OAuthClientIdStore {
  const PreferencesOAuthClientIdStore();

  @override
  Future<String?> read(String connectorId) async {
    final stored = (await SharedPreferences.getInstance()).getString(
      _key(connectorId),
    );
    final trimmed = stored?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    final define = _defines[connectorId]?.trim();
    return define == null || define.isEmpty ? null : define;
  }

  @override
  Future<void> write(String connectorId, String clientId) async {
    await (await SharedPreferences.getInstance()).setString(
      _key(connectorId),
      clientId.trim(),
    );
  }

  @override
  Future<void> clear(String connectorId) async {
    await (await SharedPreferences.getInstance()).remove(_key(connectorId));
  }

  String _key(String connectorId) => 'omi_oauth_client_id_v1_$connectorId';
}

final class VolatileOAuthClientIdStore implements OAuthClientIdStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String connectorId) async => values[connectorId];

  @override
  Future<void> write(String connectorId, String clientId) async {
    values[connectorId] = clientId.trim();
  }

  @override
  Future<void> clear(String connectorId) async {
    values.remove(connectorId);
  }
}
