import 'package:flutter_test/flutter_test.dart';
import 'package:omi/settings/settings.dart';

void main() {
  test('loads a strict settings snapshot', () async {
    final transport = QueueTransport([
      SettingsResponse(statusCode: 200, body: snapshotJson(revision: 4)),
    ]);

    final snapshot = await SettingsClient(transport).getSettings();

    expect(snapshot.revision, 4);
    expect(snapshot.settings.approvalMode, ApprovalMode.once);
    expect(transport.requests.single.path, '/v1/settings');
    expect(transport.requests.single.method, SettingsHttpMethod.get);
  });

  test('rejects unknown response fields', () async {
    final transport = QueueTransport([
      SettingsResponse(
        statusCode: 200,
        body: {...snapshotJson(), 'ignored': true},
      ),
    ]);

    await expectLater(
      SettingsClient(transport).getSettings(),
      throwsA(isA<SettingsDecodingException>()),
    );
  });

  test('loads strict setup health without credential values', () async {
    final transport = QueueTransport([
      const SettingsResponse(
        statusCode: 200,
        body: {
          'worker': true,
          'firebase': true,
          'memory': true,
          'channels': {'telegram': true, 'blooio': false},
          'billing': false,
          'models': {'managedChat': true, 'managedStt': false},
          'desktopAuth': false,
        },
      ),
    ]);

    final health = await SettingsClient(transport).getSetupHealth();

    expect(health.services.values.where((ready) => ready), hasLength(5));
    expect(health.blooio, isFalse);
    expect(transport.requests.single.path, '/v1/setup-health');
  });

  test('sends expected revision and task scope', () async {
    final transport = QueueTransport([
      SettingsResponse(statusCode: 200, body: changeJson(scopeId: 'task-7')),
    ]);

    final result = await SettingsClient(transport).changeSettings(
      expectedRevision: 3,
      patch: const SettingsPatch(proactiveRecommendations: false),
      scope: const SettingsScope.task('task-7', expiresAt: 9000),
    );

    expect(result.diff.proactiveRecommendations?.from, true);
    expect(result.diff.proactiveRecommendations?.to, false);
    expect(transport.requests.single.body, {
      'expectedRevision': 3,
      'patch': {'proactiveRecommendations': false},
      'duration': 'task',
      'taskId': 'task-7',
      'expiresAt': 9000,
    });
  });

  test('a change is validated before it reaches the transport', () async {
    final transport = QueueTransport([]);
    final client = SettingsClient(transport);

    await expectLater(
      client.changeSettings(
        expectedRevision: -1,
        patch: const SettingsPatch(proactiveRecommendations: false),
        scope: const SettingsScope.persistent(),
      ),
      throwsA(
        isA<SettingsDecodingException>().having(
          (error) => error.message,
          'message',
          'expectedRevision must not be negative',
        ),
      ),
    );
    await expectLater(
      client.changeSettings(
        expectedRevision: 0,
        patch: const SettingsPatch(),
        scope: const SettingsScope.persistent(),
      ),
      throwsA(
        isA<SettingsDecodingException>().having(
          (error) => error.message,
          'message',
          'patch must not be empty',
        ),
      ),
    );
    expect(transport.requests, isEmpty);
  });

  test('a confirmation receipt is only sent when one exists', () async {
    final withReceipt = QueueTransport([
      SettingsResponse(statusCode: 200, body: changeJson()),
    ]);
    final withoutReceipt = QueueTransport([
      SettingsResponse(statusCode: 200, body: changeJson()),
    ]);

    await SettingsClient(withReceipt).changeSettings(
      expectedRevision: 3,
      patch: const SettingsPatch(proactiveRecommendations: false),
      scope: const SettingsScope.task('task-7'),
      confirmationReceiptId: 'receipt-1',
    );
    await SettingsClient(withoutReceipt).changeSettings(
      expectedRevision: 3,
      patch: const SettingsPatch(proactiveRecommendations: false),
      scope: const SettingsScope.task('task-7'),
    );

    expect(
      withReceipt.requests.single.body?['confirmationReceiptId'],
      'receipt-1',
    );
    expect(
      withoutReceipt.requests.single.body?.containsKey('confirmationReceiptId'),
      isFalse,
    );
  });

  test('a revision conflict carries the server revision back', () async {
    final transport = QueueTransport([
      const SettingsResponse(
        statusCode: 409,
        body: {'error': 'Revision conflict', 'revision': 9},
      ),
    ]);

    await expectLater(
      SettingsClient(transport).changeSettings(
        expectedRevision: 3,
        patch: const SettingsPatch(proactiveRecommendations: false),
        scope: const SettingsScope.persistent(),
      ),
      throwsA(
        isA<SettingsConflictException>()
            .having((error) => error.revision, 'revision', 9)
            .having((error) => error.message, 'message', 'Revision conflict'),
      ),
    );
  });

  test('a conflict without a usable revision is a decoding failure', () async {
    for (final revision in <Object?>[null, '9', -1]) {
      final transport = QueueTransport([
        SettingsResponse(
          statusCode: 409,
          body: {'error': 'Revision conflict', 'revision': revision},
        ),
      ]);

      await expectLater(
        SettingsClient(transport).getSettings(),
        throwsA(
          isA<SettingsDecodingException>().having(
            (error) => error.message,
            'message',
            'conflict response requires a non-negative revision',
          ),
        ),
      );
    }
  });

  test('owner confirmation is distinguished from a plain refusal', () async {
    final confirmation = QueueTransport([
      const SettingsResponse(
        statusCode: 403,
        body: {'error': 'Owner confirmation required'},
      ),
    ]);
    final forbidden = QueueTransport([
      const SettingsResponse(statusCode: 403, body: {'error': 'Not an owner'}),
    ]);

    await expectLater(
      SettingsClient(confirmation).getSettings(),
      throwsA(isA<SettingsConfirmationRequiredException>()),
    );
    await expectLater(
      SettingsClient(forbidden).getSettings(),
      throwsA(
        isA<SettingsApiException>()
            .having((error) => error.statusCode, 'statusCode', 403)
            .having((error) => error.message, 'message', 'Not an owner'),
      ),
    );
  });

  test('an error body without an error string is a decoding failure', () async {
    for (final body in <Object?>[
      null,
      'boom',
      {'message': 'boom'},
    ]) {
      final transport = QueueTransport([
        SettingsResponse(statusCode: 500, body: body),
      ]);

      await expectLater(
        SettingsClient(transport).getSetupHealth(),
        throwsA(
          isA<SettingsDecodingException>().having(
            (error) => error.message,
            'message',
            'error response must contain an error string',
          ),
        ),
      );
    }
  });

  test(
    'transport failures are wrapped, client failures pass through',
    () async {
      final broken = SettingsClient(
        ThrowingTransport(const FormatException('connection reset')),
      );
      final rejecting = SettingsClient(
        ThrowingTransport(const SettingsApiException(401, 'Unauthorized')),
      );

      await expectLater(
        broken.getSettings(),
        throwsA(
          isA<SettingsTransportException>().having(
            (error) => error.message,
            'message',
            contains('connection reset'),
          ),
        ),
      );
      await expectLater(
        rejecting.getSettings(),
        throwsA(
          isA<SettingsApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
    },
  );

  test('a success body that is not an object is a decoding failure', () async {
    final transport = QueueTransport([
      const SettingsResponse(statusCode: 200, body: []),
    ]);

    await expectLater(
      SettingsClient(transport).getSettings(),
      throwsA(
        isA<SettingsDecodingException>().having(
          (error) => error.message,
          'message',
          'response must be an object',
        ),
      ),
    );
  });
}

SettingsJson settingsJson({
  String approvalMode = 'once',
  bool proactiveRecommendations = true,
}) => {
  'approvalMode': approvalMode,
  'proactiveRecommendations': proactiveRecommendations,
};

SettingsJson snapshotJson({int revision = 0}) => {
  'settings': settingsJson(),
  'revision': revision,
  'effectivePolicy': settingsJson(),
};

SettingsJson changeJson({
  String duration = 'task',
  String? scopeId = 'task-7',
  int revision = 3,
  bool restartRequired = false,
}) => {
  'settings': settingsJson(proactiveRecommendations: false),
  'revision': revision,
  'duration': duration,
  'scopeId': scopeId,
  'diff': {
    'proactiveRecommendations': {'from': true, 'to': false},
  },
  'effectivePolicy': settingsJson(proactiveRecommendations: false),
  'restartRequired': restartRequired,
};

final class QueueTransport implements SettingsTransport {
  QueueTransport(this._responses);

  final List<SettingsResponse> _responses;
  final List<SettingsRequest> requests = [];

  @override
  Future<SettingsResponse> send(SettingsRequest request) async {
    requests.add(request);
    return _responses.removeAt(0);
  }
}

final class ThrowingTransport implements SettingsTransport {
  const ThrowingTransport(this.error);

  final Object error;

  @override
  Future<SettingsResponse> send(SettingsRequest request) async => throw error;
}
