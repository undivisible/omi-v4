import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'auth_gateway.dart';
import 'auth_models.dart';

/// Where the refresh credential lives between launches.
///
/// Only the refresh token is persisted. The access token is minutes-lived and
/// is cheaper to re-mint than to store.
abstract interface class WorkerAuthCredentialStore {
  Future<String?> read();
  Future<void> write(String refreshToken);
  Future<void> clear();
}

/// A gateway that can say whether this device managed to remember the
/// credential, so a sign-in that worked but will not survive a relaunch can be
/// shown as exactly that instead of being discovered next launch.
abstract interface class CredentialPersistenceReporter {
  String? get credentialPersistenceFailure;
}

final class SecureWorkerAuthCredentialStore
    implements WorkerAuthCredentialStore {
  const SecureWorkerAuthCredentialStore([
    this._storage = const FlutterSecureStorage(
      // macOS is not sandboxed here and is signed for development, so it has
      // no keychain-access-group entitlement — and the data protection
      // keychain refuses every write without one (errSecMissingEntitlement,
      // -34018). Adding the entitlement is worse than useless: without a
      // matching provisioning profile the process is killed on launch. The
      // file keychain accepts the item and returns it across launches.
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    ),
  ]);

  static const _key = 'omi_worker_refresh_token';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String refreshToken) =>
      _storage.write(key: _key, value: refreshToken);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// Signs in against the Worker's own session endpoints, with no Firebase.
///
/// The credential is a code the user already holds: they message the Omi bot
/// on Telegram or from their phone over iMessage, it replies with a
/// seven-character code, and they type it here. That is why there is no OTP
/// request step — nothing is sent *to* the user by this app, so there is no
/// "we texted you" to claim. `supportsPhoneOtp` is false for the same reason:
/// the phone leg is a channel the user opens, not a challenge we issue.
///
/// Two credentials come back and are treated differently, matching how the
/// Worker issues them: the access token is short-lived and held in memory, the
/// refresh token is opaque, persisted, and revocable server-side.
final class WorkerAuthGateway
    implements AuthGateway, CredentialPersistenceReporter {
  WorkerAuthGateway({
    required this.apiOrigin,
    WorkerAuthCredentialStore? store,
    http.Client Function()? clientFactory,
    DateTime Function()? now,
  }) : _store = store ?? const SecureWorkerAuthCredentialStore(),
       _clientFactory = clientFactory ?? http.Client.new,
       _now = now ?? DateTime.now;

  final Uri apiOrigin;
  final WorkerAuthCredentialStore _store;
  final http.Client Function() _clientFactory;
  final DateTime Function() _now;

  final _sessions = StreamController<AuthSession?>.broadcast();
  AuthSession? _session;
  String? _refreshToken;
  String? _credentialPersistenceFailure;

  @override
  String? get credentialPersistenceFailure => _credentialPersistenceFailure;

  /// A code that is plausibly one of ours. The Worker normalises and checks it
  /// properly; this only avoids spending an attempt on an obvious typo.
  static final _codePattern = RegExp(r'^[0-9A-Za-z]{7}$');

  /// How long the stored credential is waited for before launch proceeds
  /// without it.
  static const _keychainTimeout = Duration(seconds: 5);

  @override
  bool get isConfigured => apiOrigin.scheme == 'https';

  @override
  AuthFailure? get configurationFailure => isConfigured
      ? null
      : const AuthFailure(
          AuthErrorCode.configurationMissing,
          'Set an HTTPS API origin to sign in.',
        );

  @override
  bool get supportsPhoneOtp => false;

  @override
  bool get supportsDesktopBrowserHandoff => false;

  @override
  bool get supportsChannelCode => true;

  @override
  AuthSession? get currentSession => _session;

  @override
  Stream<AuthSession?> get sessionChanges => _sessions.stream;

  @override
  Future<AuthSession?> restoreSession() async {
    _refreshToken ??= await _storedRefreshToken();
    if (_refreshToken == null) return null;
    return refreshSession();
  }

  /// Reading the keychain can fail outright — no plugin on this platform, a
  /// locked keychain, a denied prompt. None of those mean "signed out
  /// permanently", but all of them mean there is no credential to offer now,
  /// and none of them should take the app down on launch.
  ///
  /// A failed read is recorded rather than passed off as an empty keychain, so
  /// that a device which cannot reach its credential is distinguishable from
  /// one that was never signed in on.
  Future<String?> _storedRefreshToken() async {
    try {
      // Launch must not wait on the keychain. A prompt the user never answers
      // would otherwise hold the app on its restoring frame indefinitely.
      final stored = await _store.read().timeout(_keychainTimeout);
      _credentialPersistenceFailure = null;
      return stored;
    } catch (_) {
      _credentialPersistenceFailure =
          'This device could not read its saved sign-in. '
          'Ask the bot for a new code.';
      return null;
    }
  }

  @override
  Future<AuthSession?> refreshSession({bool forceRefresh = false}) async {
    final session = _session;
    if (!forceRefresh &&
        session != null &&
        session.expiresAt.isAfter(_now().add(const Duration(minutes: 1)))) {
      return session;
    }
    final refreshToken = _refreshToken ??= await _storedRefreshToken();
    if (refreshToken == null) return null;
    try {
      return await _exchange('/v1/auth/refresh', {
        'refreshToken': refreshToken,
      });
    } on AuthOperationException {
      // A refresh token the Worker will not honour is not a transient fault:
      // the session was revoked or expired. Drop it rather than retrying it
      // on every launch.
      await _clear();
      return null;
    }
  }

  /// Redeems a sign-in code from Telegram or iMessage.
  @override
  ///
  /// Async so that a rejected code arrives as a failed future like every other
  /// refusal, rather than throwing under the caller before it has one.
  Future<AuthSession> signInWithChannelCode(String code) async {
    final trimmed = code.trim();
    if (!_codePattern.hasMatch(trimmed)) {
      throw const AuthOperationException(
        AuthFailure(AuthErrorCode.invalidOtp, 'That code does not look right.'),
      );
    }
    return await _exchange('/v1/auth/channel/exchange', {'code': trimmed});
  }

  @override
  Future<void> signOut() async {
    final session = _session;
    if (session != null) {
      final client = _clientFactory();
      try {
        await client.post(
          apiOrigin.replace(path: '/v1/auth/signout'),
          headers: {'authorization': 'Bearer ${session.idToken}'},
        );
      } catch (_) {
        // Losing the network must not strand the user signed in locally. The
        // refresh token is dropped below either way; the server-side row
        // expires on its own.
      } finally {
        client.close();
      }
    }
    await _clear();
  }

  Future<AuthSession> _exchange(String path, Map<String, Object?> body) async {
    final client = _clientFactory();
    final http.Response response;
    try {
      response = await client.post(
        apiOrigin.replace(path: path),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode(body),
      );
    } catch (error) {
      throw AuthOperationException(
        AuthFailure(AuthErrorCode.network, error.toString()),
      );
    } finally {
      client.close();
    }
    if (response.statusCode == 429) {
      throw const AuthOperationException(
        AuthFailure(
          AuthErrorCode.rateLimited,
          'Too many attempts. Try again shortly.',
        ),
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // The Worker answers every refusal with the same opaque 401 so that a
      // guesser learns nothing. Say the one useful thing instead of inventing
      // a distinction the server deliberately withheld.
      throw const AuthOperationException(
        AuthFailure(
          AuthErrorCode.invalidOtp,
          'That code was not accepted. Ask the bot for a new one.',
        ),
      );
    }
    final decoded = _decode(response.body);
    final session = _sessionFrom(decoded);
    _refreshToken = _text(decoded, 'refreshToken');
    // The keychain is allowed to fail here. By this point the Worker has
    // already consumed the code and minted the session — it is gone, and it is
    // single-use, so throwing would tell the user their sign-in failed when it
    // demonstrably succeeded and leave them holding a code that can never work
    // again. Persistence only buys a silent restore on the next launch; losing
    // it costs one more code later, which is a far smaller thing than losing
    // the session in hand.
    try {
      await _store.write(_refreshToken!);
      _credentialPersistenceFailure = null;
    } catch (_) {
      _credentialPersistenceFailure =
          'Signed in, but this device could not remember it. '
          'You will need a new code next time the app starts.';
    }
    _session = session;
    _sessions.add(session);
    return session;
  }

  Map<String, Object?> _decode(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw const AuthOperationException(
        AuthFailure(
          AuthErrorCode.unknown,
          'The server sent an unusable reply.',
        ),
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const AuthOperationException(
        AuthFailure(
          AuthErrorCode.unknown,
          'The server sent an unusable reply.',
        ),
      );
    }
    return decoded;
  }

  AuthSession _sessionFrom(Map<String, Object?> body) {
    final expiresAt = body['expiresAt'];
    if (expiresAt is! int) {
      throw const AuthOperationException(
        AuthFailure(
          AuthErrorCode.unknown,
          'The server sent an unusable reply.',
        ),
      );
    }
    return AuthSession(
      uid: _text(body, 'uid'),
      idToken: _text(body, 'accessToken'),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt),
    );
  }

  String _text(Map<String, Object?> body, String key) {
    final value = body[key];
    if (value is! String || value.trim().isEmpty) {
      throw const AuthOperationException(
        AuthFailure(
          AuthErrorCode.unknown,
          'The server sent an unusable reply.',
        ),
      );
    }
    return value;
  }

  Future<void> _clear() async {
    _refreshToken = null;
    _session = null;
    _credentialPersistenceFailure = null;
    await _store.clear();
    _sessions.add(null);
  }

  @override
  Future<PhoneOtpChallenge> requestPhoneOtp(String phoneNumber) async =>
      throw const AuthOperationException(
        AuthFailure(
          AuthErrorCode.unsupportedPlatform,
          'Message Omi from your phone or on Telegram to get a code.',
        ),
      );

  @override
  Future<AuthSession> confirmPhoneOtp({
    required PhoneOtpChallenge challenge,
    required String code,
  }) => signInWithChannelCode(code);

  @override
  Future<AuthSession> signIn(AuthProvider provider) async =>
      throw const AuthOperationException(
        AuthFailure(
          AuthErrorCode.unsupportedPlatform,
          'Message Omi from your phone or on Telegram to get a code.',
        ),
      );

  @override
  Future<AuthSession> signInWithDesktopBrowser({
    required void Function(String code) onConfirmationCode,
  }) async => throw const AuthOperationException(
    AuthFailure(
      AuthErrorCode.unsupportedPlatform,
      'Message Omi from your phone or on Telegram to get a code.',
    ),
  );

  void dispose() => unawaited(_sessions.close());
}
