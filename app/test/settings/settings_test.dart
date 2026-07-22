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
