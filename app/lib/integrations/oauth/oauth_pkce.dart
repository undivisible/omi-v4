import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// RFC 7636 unreserved character set for the code verifier.
const _verifierAlphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

/// A PKCE verifier/challenge pair. A desktop app cannot hold a client secret,
/// so proof of possession of the verifier is the only thing binding the token
/// exchange to the browser round trip that started it.
@immutable
final class PkcePair {
  const PkcePair._(this.verifier, this.challenge);

  /// Derives the S256 challenge for [verifier].
  factory PkcePair.fromVerifier(String verifier) {
    if (verifier.length < 43 || verifier.length > 128) {
      throw ArgumentError.value(
        verifier.length,
        'verifier',
        'PKCE verifier must be 43-128 characters',
      );
    }
    for (final unit in verifier.codeUnits) {
      if (!_verifierAlphabet.codeUnits.contains(unit)) {
        throw ArgumentError.value(
          verifier,
          'verifier',
          'PKCE verifier must use unreserved characters only',
        );
      }
    }
    final digest = sha256.convert(ascii.encode(verifier));
    return PkcePair._(
      verifier,
      base64UrlEncode(digest.bytes).replaceAll('=', ''),
    );
  }

  /// Generates a fresh pair from a cryptographic random source.
  factory PkcePair.generate({Random? random, int length = 64}) {
    final source = random ?? Random.secure();
    final verifier = String.fromCharCodes([
      for (var index = 0; index < length; index += 1)
        _verifierAlphabet.codeUnitAt(source.nextInt(_verifierAlphabet.length)),
    ]);
    return PkcePair.fromVerifier(verifier);
  }

  final String verifier;
  final String challenge;

  String get method => 'S256';
}

/// The opaque `state` value that ties a redirect back to the request that
/// started it. Generated the same way as the verifier so it is equally
/// unguessable.
String generateOAuthState({Random? random, int length = 32}) {
  final source = random ?? Random.secure();
  return String.fromCharCodes([
    for (var index = 0; index < length; index += 1)
      _verifierAlphabet.codeUnitAt(source.nextInt(_verifierAlphabet.length)),
  ]);
}
