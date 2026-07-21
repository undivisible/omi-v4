import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum ProcessingConsentScope { memory, screen, audio, ai, channels }

final class ProcessingConsentReceipt {
  const ProcessingConsentReceipt({
    required this.policyVersion,
    required this.acceptedAt,
    required this.subjectUid,
    required this.scopes,
  });

  static const currentPolicyVersion = 1;
  static const requiredScopes = ProcessingConsentScope.values;

  factory ProcessingConsentReceipt.current({
    required String subjectUid,
    required DateTime acceptedAt,
  }) => ProcessingConsentReceipt(
    policyVersion: currentPolicyVersion,
    acceptedAt: acceptedAt.toUtc(),
    subjectUid: subjectUid,
    scopes: Set.unmodifiable(requiredScopes),
  );

  factory ProcessingConsentReceipt.fromJson(Object? value) {
    if (value is! Map<String, Object?> ||
        value.keys.toSet().difference({
          'policyVersion',
          'acceptedAt',
          'subjectUid',
          'scopes',
        }).isNotEmpty) {
      throw const ConsentPersistenceException('Consent receipt is invalid');
    }
    final policyVersion = value['policyVersion'];
    final acceptedAt = value['acceptedAt'];
    final subjectUid = value['subjectUid'];
    final rawScopes = value['scopes'];
    if (policyVersion is! int ||
        acceptedAt is! int ||
        acceptedAt <= 0 ||
        subjectUid is! String ||
        subjectUid.trim().isEmpty ||
        rawScopes is! List<Object?> ||
        rawScopes.any((scope) => scope is! String)) {
      throw const ConsentPersistenceException('Consent receipt is invalid');
    }
    final scopes = <ProcessingConsentScope>{};
    for (final rawScope in rawScopes.cast<String>()) {
      final matches = ProcessingConsentScope.values.where(
        (scope) => scope.name == rawScope,
      );
      if (matches.length != 1 || !scopes.add(matches.single)) {
        throw const ConsentPersistenceException('Consent receipt is invalid');
      }
    }
    return ProcessingConsentReceipt(
      policyVersion: policyVersion,
      acceptedAt: DateTime.fromMillisecondsSinceEpoch(acceptedAt, isUtc: true),
      subjectUid: subjectUid.trim(),
      scopes: Set.unmodifiable(scopes),
    );
  }

  final int policyVersion;
  final DateTime acceptedAt;
  final String subjectUid;
  final Set<ProcessingConsentScope> scopes;

  bool authorizes(String uid) =>
      policyVersion == currentPolicyVersion &&
      subjectUid == uid &&
      scopes.length == requiredScopes.length &&
      scopes.containsAll(requiredScopes);

  Map<String, Object?> toJson() => {
    'policyVersion': policyVersion,
    'acceptedAt': acceptedAt.toUtc().millisecondsSinceEpoch,
    'subjectUid': subjectUid,
    'scopes': scopes.map((scope) => scope.name).toList()..sort(),
  };
}

abstract interface class ConsentStore {
  Future<ProcessingConsentReceipt?> currentReceipt();

  Future<void> save(ProcessingConsentReceipt receipt);

  Future<void> revoke();
}

final class ConsentPersistenceException implements Exception {
  const ConsentPersistenceException(this.message);

  final String message;
}

final class PreferencesConsentStore implements ConsentStore {
  static const _key = 'processing_consent_receipt_v1';

  @override
  Future<ProcessingConsentReceipt?> currentReceipt() async {
    final encoded = (await SharedPreferences.getInstance()).getString(_key);
    if (encoded == null) return null;
    try {
      return ProcessingConsentReceipt.fromJson(jsonDecode(encoded));
    } on FormatException {
      throw const ConsentPersistenceException('Consent receipt is invalid');
    }
  }

  @override
  Future<void> save(ProcessingConsentReceipt receipt) async {
    final saved = await (await SharedPreferences.getInstance()).setString(
      _key,
      jsonEncode(receipt.toJson()),
    );
    if (!saved) {
      throw const ConsentPersistenceException('Consent receipt was not saved');
    }
  }

  @override
  Future<void> revoke() async {
    final removed = await (await SharedPreferences.getInstance()).remove(_key);
    if (!removed) {
      throw const ConsentPersistenceException(
        'Consent receipt was not removed',
      );
    }
  }
}

final class VolatileConsentStore implements ConsentStore {
  ProcessingConsentReceipt? receipt;

  @override
  Future<ProcessingConsentReceipt?> currentReceipt() async => receipt;

  @override
  Future<void> save(ProcessingConsentReceipt value) async => receipt = value;

  @override
  Future<void> revoke() async => receipt = null;
}
