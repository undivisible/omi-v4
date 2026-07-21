import 'package:flutter_test/flutter_test.dart';
import 'package:omi/auth/auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'persists and revokes a versioned subject-bound scope receipt',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = PreferencesConsentStore();
      final receipt = ProcessingConsentReceipt.current(
        subjectUid: 'user-a',
        acceptedAt: DateTime.utc(2026, 7, 21, 12, 30),
      );

      expect(await store.currentReceipt(), isNull);
      await store.save(receipt);
      final restored = await PreferencesConsentStore().currentReceipt();
      expect(
        restored?.policyVersion,
        ProcessingConsentReceipt.currentPolicyVersion,
      );
      expect(restored?.acceptedAt, receipt.acceptedAt);
      expect(restored?.subjectUid, 'user-a');
      expect(restored?.scopes, ProcessingConsentScope.values.toSet());
      expect(restored?.authorizes('user-a'), isTrue);
      expect(restored?.authorizes('user-b'), isFalse);

      await store.revoke();
      expect(await PreferencesConsentStore().currentReceipt(), isNull);
    },
  );

  test('rejects stale, incomplete, and unknown processing receipts', () {
    final complete = ProcessingConsentReceipt.current(
      subjectUid: 'user-a',
      acceptedAt: DateTime.utc(2026, 7, 21),
    );
    final stale = ProcessingConsentReceipt(
      policyVersion: 0,
      acceptedAt: complete.acceptedAt,
      subjectUid: complete.subjectUid,
      scopes: complete.scopes,
    );
    final incomplete = ProcessingConsentReceipt(
      policyVersion: ProcessingConsentReceipt.currentPolicyVersion,
      acceptedAt: complete.acceptedAt,
      subjectUid: complete.subjectUid,
      scopes: const {ProcessingConsentScope.memory},
    );

    expect(stale.authorizes('user-a'), isFalse);
    expect(incomplete.authorizes('user-a'), isFalse);
    expect(
      () => ProcessingConsentReceipt.fromJson({
        ...complete.toJson(),
        'unexpected': true,
      }),
      throwsA(isA<ConsentPersistenceException>()),
    );
  });
}
