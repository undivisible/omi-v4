import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'auth_gateway.dart';
import 'auth_models.dart';

typedef BrowserLauncher = Future<bool> Function(Uri uri);

final class DesktopAuthCredential {
  const DesktopAuthCredential(this.customToken, this.generation);

  final String customToken;
  final int generation;
}

final class DesktopAuthHandoff {
  DesktopAuthHandoff({
    required this.apiOrigin,
    required this.appOrigin,
    BrowserLauncher? launchBrowser,
    http.Client Function()? clientFactory,
    this.pollInterval = const Duration(seconds: 1),
    this.timeout = const Duration(minutes: 5),
  }) : launchBrowser =
           launchBrowser ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication)),
       clientFactory = clientFactory ?? http.Client.new;

  final Uri apiOrigin;
  final Uri appOrigin;
  final BrowserLauncher launchBrowser;
  final http.Client Function() clientFactory;
  final Duration pollInterval;
  final Duration timeout;
  int _generation = 0;

  void cancel() => _generation++;

  bool isCurrent(DesktopAuthCredential credential) =>
      credential.generation == _generation;

  Future<DesktopAuthCredential> authenticate({
    required void Function(String code) onConfirmationCode,
  }) async {
    _validateOrigin(apiOrigin, 'API');
    _validateOrigin(appOrigin, 'app');
    final generation = ++_generation;
    final random = Random.secure();
    final verifier = _randomValue(random);
    final sessionId = _randomValue(random);
    final challenge = base64UrlEncode(
      sha256.convert(utf8.encode(verifier)).bytes,
    ).replaceAll('=', '');
    final confirmationCode = List.generate(6, (_) => random.nextInt(10)).join();
    final confirmationChallenge = base64UrlEncode(
      sha256.convert(utf8.encode(confirmationCode)).bytes,
    ).replaceAll('=', '');
    onConfirmationCode(confirmationCode);
    final client = clientFactory();
    try {
      final started = await client
          .post(
            apiOrigin.resolve('/v1/auth/desktop/start'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'sessionId': sessionId,
              'challenge': challenge,
              'confirmationChallenge': confirmationChallenge,
            }),
          )
          .timeout(const Duration(seconds: 15));
      _requireCurrent(generation);
      final startBody = _object(started.body);
      final browserUrl = Uri.tryParse(
        startBody?['browserUrl'] as String? ?? '',
      );
      if (started.statusCode != 201 || browserUrl == null) {
        throw _failure(startBody, 'Desktop sign-in could not start');
      }
      if (!_sameOrigin(browserUrl, appOrigin)) {
        throw const AuthOperationException(
          AuthFailure(
            AuthErrorCode.configurationMissing,
            'Desktop sign-in returned an unexpected app origin',
          ),
        );
      }
      final launched = await launchBrowser(
        browserUrl,
      ).timeout(const Duration(seconds: 15));
      _requireCurrent(generation);
      if (!launched) {
        throw const AuthOperationException(
          AuthFailure(
            AuthErrorCode.cancelled,
            'Could not open the sign-in browser',
          ),
        );
      }
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(pollInterval);
        _requireCurrent(generation);
        final exchanged = await client
            .post(
              apiOrigin.resolve('/v1/auth/desktop/exchange'),
              headers: const {'content-type': 'application/json'},
              body: jsonEncode({'sessionId': sessionId, 'verifier': verifier}),
            )
            .timeout(const Duration(seconds: 15));
        _requireCurrent(generation);
        final exchangeBody = _object(exchanged.body);
        if (exchanged.statusCode == 409 &&
            exchangeBody?['status'] == 'pending') {
          continue;
        }
        final customToken = exchangeBody?['customToken'];
        if (exchanged.statusCode == 200 &&
            customToken is String &&
            customToken.isNotEmpty) {
          _requireCurrent(generation);
          return DesktopAuthCredential(customToken, generation);
        }
        throw _failure(exchangeBody, 'Desktop sign-in failed');
      }
      throw const AuthOperationException(
        AuthFailure(AuthErrorCode.otpExpired, 'Desktop sign-in expired'),
      );
    } finally {
      client.close();
    }
  }

  void _requireCurrent(int generation) {
    if (generation != _generation) {
      throw const AuthOperationException(
        AuthFailure(AuthErrorCode.cancelled, 'Desktop sign-in cancelled'),
      );
    }
  }

  static void _validateOrigin(Uri uri, String label) {
    final loopback = {'localhost', '127.0.0.1', '::1'}.contains(uri.host);
    final validScheme =
        uri.scheme == 'https' || (loopback && uri.scheme == 'http');
    if (!validScheme ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.query.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw AuthOperationException(
        AuthFailure(
          AuthErrorCode.configurationMissing,
          '$label origin must be HTTPS or loopback HTTP',
        ),
      );
    }
  }

  static bool _sameOrigin(Uri left, Uri right) =>
      left.scheme == right.scheme &&
      left.host == right.host &&
      left.port == right.port &&
      left.userInfo.isEmpty &&
      left.fragment.isEmpty;

  static String _randomValue(Random random) => base64UrlEncode(
    List<int>.generate(32, (_) => random.nextInt(256)),
  ).replaceAll('=', '');

  static Map<String, Object?>? _object(String source) {
    try {
      final decoded = jsonDecode(source);
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static AuthOperationException _failure(
    Map<String, Object?>? body,
    String fallback,
  ) => AuthOperationException(
    AuthFailure(
      AuthErrorCode.network,
      body?['error'] is String ? body!['error']! as String : fallback,
    ),
  );
}
