import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' as firebase;
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'auth_gateway.dart';
import 'auth_models.dart';
import 'desktop_auth_handoff.dart';

Future<AuthGateway> initializeFirebaseAuth() async {
  final FirebaseClientOptions options;
  try {
    options = FirebaseClientOptions.fromEnvironment();
  } on FirebaseOptionsException catch (error) {
    return UnconfiguredAuthGateway(
      AuthFailure(AuthErrorCode.configurationMissing, error.message),
    );
  }
  try {
    final app = await Firebase.initializeApp(options: options.firebaseOptions);
    final auth = firebase.FirebaseAuth.instanceFor(app: app);
    if (kIsWeb) await auth.setPersistence(firebase.Persistence.LOCAL);
    const apiOrigin = String.fromEnvironment('OMI_API_ORIGIN');
    const appOrigin = String.fromEnvironment('OMI_APP_ORIGIN');
    final desktopHandoff =
        (options.platform == FirebaseClientPlatform.macos ||
                options.platform == FirebaseClientPlatform.windows) &&
            apiOrigin.isNotEmpty &&
            appOrigin.isNotEmpty
        ? DesktopAuthHandoff(
            apiOrigin: Uri.parse(apiOrigin),
            appOrigin: Uri.parse(appOrigin),
          )
        : null;
    return FirebaseAuthGateway(
      auth,
      supportsPhoneOtp: options.platform.supportsPhoneOtp,
      desktopHandoff: desktopHandoff,
    );
  } catch (error) {
    return const UnconfiguredAuthGateway(
      AuthFailure(
        AuthErrorCode.configurationMissing,
        'Firebase could not initialize with this configuration',
      ),
    );
  }
}

final class FirebaseAuthGateway implements AuthGateway {
  FirebaseAuthGateway(
    this._auth, {
    required this.supportsPhoneOtp,
    this.desktopHandoff,
  });

  final firebase.FirebaseAuth _auth;
  @override
  final bool supportsPhoneOtp;
  final DesktopAuthHandoff? desktopHandoff;

  @override
  bool get supportsDesktopBrowserHandoff => desktopHandoff != null;
  final Map<String, firebase.ConfirmationResult> _webChallenges = {};
  AuthSession? _session;

  @override
  bool get isConfigured => true;

  @override
  AuthFailure? get configurationFailure => null;

  @override
  AuthSession? get currentSession => _session;

  @override
  Stream<AuthSession?> get sessionChanges =>
      _auth.idTokenChanges().asyncMap(_sessionFor);

  @override
  Future<AuthSession?> restoreSession() => _sessionFor(_auth.currentUser);

  @override
  Future<AuthSession?> refreshSession() => _sessionFor(
    _auth.currentUser,
    forceRefresh:
        _session?.expiresAt.isBefore(
          DateTime.now().add(const Duration(minutes: 2)),
        ) ??
        false,
  );

  @override
  Future<PhoneOtpChallenge> requestPhoneOtp(String phoneNumber) async {
    if (!supportsPhoneOtp) {
      throw const AuthOperationException(
        AuthFailure(
          AuthErrorCode.unsupportedPlatform,
          'Phone sign-in is not supported on this platform',
        ),
      );
    }
    try {
      if (kIsWeb) {
        final confirmation = await _auth.signInWithPhoneNumber(phoneNumber);
        final id = DateTime.now().microsecondsSinceEpoch.toString();
        _webChallenges[id] = confirmation;
        return PhoneOtpChallenge(verificationId: id);
      }
      final completer = Completer<PhoneOtpChallenge>();
      await _auth.verifyPhoneNumber(
        phoneNumber: phoneNumber,
        verificationCompleted: (credential) async {
          try {
            final result = await _auth.signInWithCredential(credential);
            final session = await _requiredSession(result.user);
            if (!completer.isCompleted) {
              completer.complete(
                PhoneOtpChallenge(
                  verificationId: 'automatic',
                  completedSession: session,
                ),
              );
            }
          } catch (error) {
            if (!completer.isCompleted) completer.completeError(error);
          }
        },
        verificationFailed: (error) {
          if (!completer.isCompleted) completer.completeError(error);
        },
        codeSent: (verificationId, resendToken) {
          if (!completer.isCompleted) {
            completer.complete(
              PhoneOtpChallenge(
                verificationId: verificationId,
                resendToken: resendToken,
              ),
            );
          }
        },
        codeAutoRetrievalTimeout: (verificationId) {
          if (!completer.isCompleted) {
            completer.complete(
              PhoneOtpChallenge(verificationId: verificationId),
            );
          }
        },
      );
      return await completer.future;
    } on firebase.FirebaseAuthException catch (error) {
      throw AuthOperationException(
        firebaseFailureForCode(error.code, error.message),
      );
    } on UnsupportedError catch (_) {
      throw const AuthOperationException(
        AuthFailure(
          AuthErrorCode.unsupportedPlatform,
          'Phone sign-in is not supported on this platform',
        ),
      );
    }
  }

  @override
  Future<AuthSession> confirmPhoneOtp({
    required PhoneOtpChallenge challenge,
    required String code,
  }) async {
    try {
      final firebase.UserCredential result;
      if (kIsWeb) {
        final confirmation = _webChallenges.remove(challenge.verificationId);
        if (confirmation == null) {
          throw const AuthOperationException(
            AuthFailure(AuthErrorCode.otpExpired, 'Verification code expired'),
          );
        }
        result = await confirmation.confirm(code);
      } else {
        result = await _auth.signInWithCredential(
          firebase.PhoneAuthProvider.credential(
            verificationId: challenge.verificationId,
            smsCode: code,
          ),
        );
      }
      return _requiredSession(result.user);
    } on firebase.FirebaseAuthException catch (error) {
      throw AuthOperationException(
        firebaseFailureForCode(error.code, error.message),
      );
    }
  }

  @override
  Future<AuthSession> signIn(AuthProvider provider) async {
    try {
      final firebase.AuthProvider firebaseProvider = switch (provider) {
        AuthProvider.google => firebase.GoogleAuthProvider(),
        AuthProvider.apple => firebase.AppleAuthProvider(),
        AuthProvider.phone => throw const AuthOperationException(
          AuthFailure(
            AuthErrorCode.invalidPhoneNumber,
            'Phone sign-in requires an OTP',
          ),
        ),
      };
      final result = kIsWeb
          ? await _auth.signInWithPopup(firebaseProvider)
          : await _auth.signInWithProvider(firebaseProvider);
      return _requiredSession(result.user);
    } on firebase.FirebaseAuthException catch (error) {
      throw AuthOperationException(
        firebaseFailureForCode(error.code, error.message),
      );
    } on UnsupportedError catch (_) {
      throw const AuthOperationException(
        AuthFailure(
          AuthErrorCode.unsupportedPlatform,
          'This sign-in provider is not supported on this platform',
        ),
      );
    }
  }

  @override
  Future<AuthSession> signInWithDesktopBrowser({
    required void Function(String code) onConfirmationCode,
  }) async {
    final handoff = desktopHandoff;
    if (handoff == null) {
      throw const AuthOperationException(
        AuthFailure(
          AuthErrorCode.unsupportedPlatform,
          'Desktop browser sign-in is not configured',
        ),
      );
    }
    try {
      final credential = await handoff.authenticate(
        onConfirmationCode: onConfirmationCode,
      );
      if (!handoff.isCurrent(credential)) {
        throw const AuthOperationException(
          AuthFailure(AuthErrorCode.cancelled, 'Desktop sign-in cancelled'),
        );
      }
      final result = await _auth.signInWithCustomToken(credential.customToken);
      final session = await _requiredSession(result.user);
      if (!handoff.isCurrent(credential)) {
        await _auth.signOut();
        _session = null;
        throw const AuthOperationException(
          AuthFailure(AuthErrorCode.cancelled, 'Desktop sign-in cancelled'),
        );
      }
      return session;
    } on firebase.FirebaseAuthException catch (error) {
      throw AuthOperationException(
        firebaseFailureForCode(error.code, error.message),
      );
    }
  }

  @override
  Future<void> signOut() async {
    try {
      desktopHandoff?.cancel();
      await _auth.signOut();
      _session = null;
      _webChallenges.clear();
    } on firebase.FirebaseAuthException catch (error) {
      throw AuthOperationException(
        firebaseFailureForCode(error.code, error.message),
      );
    }
  }

  Future<AuthSession> _requiredSession(firebase.User? user) async {
    final session = await _sessionFor(user);
    if (session == null) {
      throw const AuthOperationException(
        AuthFailure(AuthErrorCode.unknown, 'Firebase returned no user'),
      );
    }
    return session;
  }

  Future<AuthSession?> _sessionFor(
    firebase.User? user, {
    bool forceRefresh = false,
  }) async {
    if (user == null) {
      _session = null;
      return null;
    }
    final token = await user.getIdTokenResult(forceRefresh);
    if (token.token == null || token.expirationTime == null) {
      throw const AuthOperationException(
        AuthFailure(AuthErrorCode.unknown, 'Firebase returned no ID token'),
      );
    }
    return _session = AuthSession(
      uid: user.uid,
      idToken: token.token!,
      expiresAt: token.expirationTime!,
      phoneNumber: user.phoneNumber,
      email: user.email,
      displayName: user.displayName,
    );
  }
}

AuthFailure firebaseFailureForCode(String errorCode, [String? message]) {
  final code = switch (errorCode) {
    'invalid-phone-number' => AuthErrorCode.invalidPhoneNumber,
    'invalid-verification-code' => AuthErrorCode.invalidOtp,
    'session-expired' || 'code-expired' => AuthErrorCode.otpExpired,
    'too-many-requests' || 'quota-exceeded' => AuthErrorCode.rateLimited,
    'popup-closed-by-user' ||
    'web-context-cancelled' ||
    'canceled' => AuthErrorCode.cancelled,
    'network-request-failed' => AuthErrorCode.network,
    'operation-not-supported-in-this-environment' ||
    'unimplemented' => AuthErrorCode.unsupportedPlatform,
    _ => AuthErrorCode.unknown,
  };
  return AuthFailure(code, message ?? 'Authentication failed');
}

enum FirebaseClientPlatform {
  web,
  android,
  ios,
  macos,
  windows;

  bool get supportsPhoneOtp =>
      this == FirebaseClientPlatform.web ||
      this == FirebaseClientPlatform.android ||
      this == FirebaseClientPlatform.ios;
}

final class FirebaseOptionsException implements Exception {
  const FirebaseOptionsException(this.message);

  final String message;
}

final class FirebaseClientOptions {
  const FirebaseClientOptions({
    required this.platform,
    required this.apiKey,
    required this.appId,
    required this.messagingSenderId,
    required this.projectId,
    this.authDomain,
  });

  factory FirebaseClientOptions.parse({
    required FirebaseClientPlatform platform,
    required String apiKey,
    required String appId,
    required String messagingSenderId,
    required String projectId,
    String authDomain = '',
  }) {
    if (!RegExp(r'^AIza[0-9A-Za-z_-]{20,}$').hasMatch(apiKey)) {
      throw const FirebaseOptionsException('FIREBASE_API_KEY is invalid');
    }
    final appIdMatch = RegExp(
      r'^\d+:\d+:(web|android|ios):[0-9A-Fa-f]+$',
    ).firstMatch(appId);
    final expectedAppKind = switch (platform) {
      FirebaseClientPlatform.web || FirebaseClientPlatform.windows => 'web',
      FirebaseClientPlatform.android => 'android',
      FirebaseClientPlatform.ios || FirebaseClientPlatform.macos => 'ios',
    };
    if (appIdMatch == null || appIdMatch.group(1) != expectedAppKind) {
      throw const FirebaseOptionsException('FIREBASE_APP_ID is invalid');
    }
    if (!RegExp(r'^\d+$').hasMatch(messagingSenderId)) {
      throw const FirebaseOptionsException(
        'FIREBASE_MESSAGING_SENDER_ID is invalid',
      );
    }
    if (!RegExp(r'^[a-z][a-z0-9-]{4,28}[a-z0-9]$').hasMatch(projectId)) {
      throw const FirebaseOptionsException('FIREBASE_PROJECT_ID is invalid');
    }
    final domain = authDomain.trim().toLowerCase();
    if (platform == FirebaseClientPlatform.web && !_validDomain(domain)) {
      throw const FirebaseOptionsException(
        'FIREBASE_AUTH_DOMAIN must be a valid web host',
      );
    }
    if (domain.isNotEmpty && !_validDomain(domain)) {
      throw const FirebaseOptionsException('FIREBASE_AUTH_DOMAIN is invalid');
    }
    return FirebaseClientOptions(
      platform: platform,
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: messagingSenderId,
      projectId: projectId,
      authDomain: domain.isEmpty ? null : domain,
    );
  }

  factory FirebaseClientOptions.fromEnvironment() {
    final platform = _currentPlatform();
    final prefix = platform.name.toUpperCase();
    const genericApiKey = String.fromEnvironment('FIREBASE_API_KEY');
    const genericAppId = String.fromEnvironment('FIREBASE_APP_ID');
    final apiKey = switch (prefix) {
      'WEB' => const String.fromEnvironment('FIREBASE_WEB_API_KEY'),
      'ANDROID' => const String.fromEnvironment('FIREBASE_ANDROID_API_KEY'),
      'IOS' => const String.fromEnvironment('FIREBASE_IOS_API_KEY'),
      'MACOS' => const String.fromEnvironment('FIREBASE_MACOS_API_KEY'),
      'WINDOWS' => const String.fromEnvironment('FIREBASE_WINDOWS_API_KEY'),
      _ => '',
    };
    final appId = switch (prefix) {
      'WEB' => const String.fromEnvironment('FIREBASE_WEB_APP_ID'),
      'ANDROID' => const String.fromEnvironment('FIREBASE_ANDROID_APP_ID'),
      'IOS' => const String.fromEnvironment('FIREBASE_IOS_APP_ID'),
      'MACOS' => const String.fromEnvironment('FIREBASE_MACOS_APP_ID'),
      'WINDOWS' => const String.fromEnvironment('FIREBASE_WINDOWS_APP_ID'),
      _ => '',
    };
    return FirebaseClientOptions.parse(
      platform: platform,
      apiKey: apiKey.isEmpty ? genericApiKey : apiKey,
      appId: appId.isEmpty ? genericAppId : appId,
      messagingSenderId: const String.fromEnvironment(
        'FIREBASE_MESSAGING_SENDER_ID',
      ),
      projectId: const String.fromEnvironment('FIREBASE_PROJECT_ID'),
      authDomain: const String.fromEnvironment('FIREBASE_AUTH_DOMAIN'),
    );
  }

  final FirebaseClientPlatform platform;
  final String apiKey;
  final String appId;
  final String messagingSenderId;
  final String projectId;
  final String? authDomain;

  FirebaseOptions get firebaseOptions => FirebaseOptions(
    apiKey: apiKey,
    appId: appId,
    messagingSenderId: messagingSenderId,
    projectId: projectId,
    authDomain: authDomain,
  );

  static bool _validDomain(String value) => RegExp(
    r'^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])$',
  ).hasMatch(value);

  static FirebaseClientPlatform _currentPlatform() {
    if (kIsWeb) return FirebaseClientPlatform.web;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => FirebaseClientPlatform.android,
      TargetPlatform.iOS => FirebaseClientPlatform.ios,
      TargetPlatform.macOS => FirebaseClientPlatform.macos,
      TargetPlatform.windows => FirebaseClientPlatform.windows,
      TargetPlatform.linux ||
      TargetPlatform.fuchsia => throw const FirebaseOptionsException(
        'Firebase authentication is not supported on this platform',
      ),
    };
  }
}
