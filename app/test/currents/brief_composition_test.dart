import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/currents/currents.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  test('a composed brief is attached to the hero card', () async {
    final hub = _Hub();
    final controller = CurrentsController(
      CurrentsClient(_Transport()),
      hub: hub,
      now: () => DateTime(2026, 7, 23, 9, 5),
    );

    await controller.load();
    expect(hub.composed.single.nowLocal, 'Thursday 9:05 AM');
    expect(hub.composed.single.items.single.title, 'Ship release');
    expect(
      hub.composed.single.items.single.nextStep,
      'Review release checklist',
    );
    expect(controller.items.single.metadata?['crepus'], isNull);

    hub.answer(hub.composed.single.requestId, 'text "Ship release"');
    await Future<void>.delayed(Duration.zero);
    expect(controller.items.single.metadata?['crepus'], 'text "Ship release"');
  });

  test('nothing composed leaves the hand-built brief alone', () async {
    final hub = _Hub();
    final controller = CurrentsController(
      CurrentsClient(_Transport()),
      hub: hub,
      now: () => DateTime(2026, 7, 23, 13, 0),
    );

    await controller.load();
    hub.answer(hub.composed.single.requestId, null);
    await Future<void>.delayed(Duration.zero);
    expect(controller.items.single.metadata?['crepus'], isNull);
  });

  test('a superseded composition is discarded', () async {
    final hub = _Hub();
    final controller = CurrentsController(
      CurrentsClient(_Transport()),
      hub: hub,
      now: () => DateTime(2026, 7, 23, 9, 5),
    );

    await controller.load();
    final stale = hub.composed.first.requestId;
    await controller.load();
    hub.answer(stale, 'text "stale"');
    await Future<void>.delayed(Duration.zero);
    expect(controller.items.single.metadata?['crepus'], isNull);
  });

  test('an unavailable hub is never asked', () async {
    final controller = CurrentsController(
      CurrentsClient(_Transport()),
      hub: const UnavailableNativeHub('no native hub here'),
    );
    await controller.load();
    expect(controller.items.single.metadata?['crepus'], isNull);
  });
}

final class _Composed {
  const _Composed(this.requestId, this.nowLocal, this.items);

  final String requestId;
  final String nowLocal;
  final List<BriefItem> items;
}

final class _Hub implements NativeHub {
  final _events = StreamController<NativeEvent>.broadcast();
  final composed = <_Composed>[];

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => _events.stream;

  @override
  void composeBrief({
    required String requestId,
    required String nowLocal,
    required List<BriefItem> items,
  }) => composed.add(_Composed(requestId, nowLocal, items));

  void answer(String requestId, String? crepus) => _events.add(
    NativeEventBriefComposed(
      value: BriefComposed(requestId: requestId, crepus: crepus),
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Transport implements CurrentsTransport {
  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async {
    if (request.path.endsWith('/generate')) {
      return const CurrentsResponse(statusCode: 200, body: {'current': null});
    }
    return CurrentsResponse(
      statusCode: 200,
      body: {
        'currents': [_current],
      },
    );
  }
}

const _current = <String, Object?>{
  'id': 'current-1',
  'title': 'Ship release',
  'summary': 'The release checklist is unfinished.',
  'status': 'surfaced',
  'evidence': [
    {'sourceId': 'conversation-1', 'reason': 'Cited commitment'},
  ],
  'reason': 'Cited commitment',
  'confidence': 0.9,
  'proposedNextStep': 'Review release checklist',
  'timing': {
    'surfaceAt': '2026-07-21T12:00:00.000Z',
    'expiresAt': null,
    'snoozedUntil': null,
  },
  'feedbackReference': null,
  'executionReference': null,
  'createdAt': '2026-07-21T12:00:00.000Z',
  'updatedAt': '2026-07-21T12:00:00.000Z',
};
