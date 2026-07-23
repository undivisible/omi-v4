import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/api/facetime_client.dart';
import 'package:omi/api/worker_http.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/setup_account_screens.dart';
import 'package:omi/native/native_hub.dart';

final class FakeFaceTimeClient implements FaceTimeClient {
  FakeFaceTimeClient(this._answer);

  final Future<FaceTimeCall> Function(String handle) _answer;
  final calls = <String>[];

  @override
  Future<FaceTimeCall> placeCall({
    required String handle,
    String? idempotencyKey,
  }) {
    calls.add(handle);
    return _answer(handle);
  }
}

final class _CallHub implements NativeHub {
  final controller = StreamController<NativeEvent>.broadcast();
  String? joinedRequestId;
  String? joinedLink;

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => controller.stream;

  @override
  Future<void> initialize() async {}

  @override
  void joinCall({
    required String requestId,
    required String link,
    required String ephemeralToken,
    required String model,
    String? displayName,
    bool video = true,
  }) {
    joinedRequestId = requestId;
    joinedLink = link;
  }

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _Tokens implements LiveVoiceTokenClient {
  @override
  Future<GeminiLiveToken> createGeminiToken() async => GeminiLiveToken(
    token: 'ephemeral',
    model: 'gemini-live',
    expireTime: DateTime.fromMillisecondsSinceEpoch(2000),
    newSessionExpireTime: DateTime.fromMillisecondsSinceEpoch(1000),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppServices makeServices(
    FaceTimeClient facetime, {
    NativeHub? hub,
    LiveVoiceTokenClient? tokens,
  }) {
    final services = AppServices.forTesting(
      nativeHub: hub ?? const UnavailableNativeHub('test'),
      liveVoiceTokens: tokens,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      auth: AuthController(const UnconfiguredAuthGateway()),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      facetime: facetime,
    );
    addTearDown(services.dispose);
    return services;
  }

  Widget host(AppServices services) => MaterialApp(
    home: SettingsScreen(
      services: services,
      initialSection: SettingsSection.calls,
    ),
  );

  Future<void> placeCall(WidgetTester tester, String handle) async {
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('facetime_tile')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('facetime_handle_field')),
      handle,
    );
    await tester.tap(find.byKey(const Key('facetime_call')));
    await tester.pumpAndSettle();
  }

  testWidgets('the provider being switched off reads as an explanation', (
    tester,
  ) async {
    final client = FakeFaceTimeClient(
      (handle) async => throw const FaceTimeUnavailableException(
        'FaceTime calling is not yet available from Blooio',
      ),
    );
    await tester.pumpWidget(host(makeServices(client)));
    await placeCall(tester, '+15551234567');

    expect(find.byKey(const Key('facetime_unavailable')), findsOneWidget);
    expect(find.text("FaceTime calling isn't available yet"), findsOneWidget);
    expect(find.textContaining('Nobody was rung'), findsOneWidget);
    // Not an error: no red error line and no dialog on top of the dialog.
    expect(find.byKey(const Key('facetime_error')), findsNothing);
    expect(find.byKey(const Key('facetime_dialog')), findsOneWidget);
  });

  testWidgets('a real failure is surfaced as an error', (tester) async {
    final client = FakeFaceTimeClient(
      (handle) async =>
          throw const WorkerResponseException('FaceTime calling unavailable'),
    );
    await tester.pumpWidget(host(makeServices(client)));
    await placeCall(tester, '+15551234567');

    expect(find.byKey(const Key('facetime_error')), findsOneWidget);
    expect(find.byKey(const Key('facetime_unavailable')), findsNothing);
  });

  testWidgets('a placed call reaches the worker and shows its link', (
    tester,
  ) async {
    final client = FakeFaceTimeClient(
      (handle) async => FaceTimeCall(
        handle: handle,
        link: 'https://facetime.apple.com/join#v=1&p=abc',
      ),
    );
    await tester.pumpWidget(host(makeServices(client)));
    await placeCall(tester, 'friend@example.com');

    expect(client.calls, ['friend@example.com']);
    expect(find.byKey(const Key('facetime_link')), findsOneWidget);
  });

  testWidgets('the bridge is joined and its call state is reflected', (
    tester,
  ) async {
    final hub = _CallHub();
    addTearDown(hub.controller.close);
    final client = FakeFaceTimeClient(
      (handle) async => FaceTimeCall(
        handle: handle,
        link: 'https://facetime.apple.com/join#v=1&p=abc',
      ),
    );
    await tester.pumpWidget(
      host(makeServices(client, hub: hub, tokens: _Tokens())),
    );
    await placeCall(tester, '+15551234567');

    expect(hub.joinedLink, 'https://facetime.apple.com/join#v=1&p=abc');
    expect(find.text('Joining the call\u2026'), findsOneWidget);

    hub.controller.add(
      NativeEventCallState(
        value: CallState(
          requestId: hub.joinedRequestId!,
          state: CallPhase.joined,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Joined. Omi is on the call.'), findsOneWidget);

    hub.controller.add(
      NativeEventCallState(
        value: CallState(
          requestId: hub.joinedRequestId!,
          state: CallPhase.failed,
          detail: 'bridge closed',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('The call could not be joined.'), findsOneWidget);
    expect(find.text('bridge closed'), findsOneWidget);
  });
}
