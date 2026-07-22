import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/capabilities/desktop_capabilities.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/onboarding_screen.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  testWidgets(
    'a stale scan-completed event cannot be accepted while a retried scan '
    'has not yet produced a new request id, and the genuine retry result '
    'is still honored',
    (tester) async {
      final auth = AuthController(const UnconfiguredAuthGateway());
      final hub = _ScanHub()..available = false;
      final services = AppServices.forTesting(
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        auth: auth,
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      );
      addTearDown(services.dispose);
      addTearDown(hub.close);

      final capabilities = _AllGrantedCapabilities();

      await tester.pumpWidget(
        MaterialApp(
          home: OnboardingScreen(
            services: services,
            capabilities: capabilities,
            onFinish: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('continue_preview_intro')));
      await tester.pumpAndSettle();

      // The scan attempt fails immediately (native unavailable): no request
      // id has ever been assigned, matching the window where scanRequestId
      // is null.
      expect(find.text('Try again'), findsOneWidget);
      expect(hub.scanRequests, isEmpty);

      // A stale/foreign completed event arrives while no request is
      // outstanding. The buggy version accepted any event once
      // scanRequestId was null; the fix must reject it regardless.
      hub.eventsController.add(
        NativeEventOnboardingScanCompleted(
          value: OnboardingScanCompleted(
            requestId: 'stale-foreign-request',
            sources: [
              OnboardingScanSource(
                source: 'workspace',
                state: OnboardingScanState.complete,
                detail: 'should not be accepted',
                itemsFound: Uint64.fromBigInt(BigInt.zero),
              ),
            ],
            summary: 'stale summary',
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Try again'), findsOneWidget);
      expect(find.textContaining('stale summary'), findsNothing);

      // Retry: this time the hub is available and the scan actually starts.
      hub.available = true;
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(hub.scanRequests, hasLength(1));
      final realRequestId = hub.scanRequests.single.requestId;

      // The same stale event, resent, still must not be accepted now that a
      // real request is outstanding under a different id.
      hub.eventsController.add(
        NativeEventOnboardingScanCompleted(
          value: OnboardingScanCompleted(
            requestId: 'stale-foreign-request',
            sources: [
              OnboardingScanSource(
                source: 'workspace',
                state: OnboardingScanState.complete,
                detail: 'still should not be accepted',
                itemsFound: Uint64.fromBigInt(BigInt.zero),
              ),
            ],
            summary: 'still stale',
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('still stale'), findsNothing);

      // The genuine retry result is honored.
      hub.eventsController.add(
        NativeEventOnboardingScanCompleted(
          value: OnboardingScanCompleted(
            requestId: realRequestId,
            sources: [
              OnboardingScanSource(
                source: 'workspace',
                state: OnboardingScanState.complete,
                detail: 'genuine result',
                itemsFound: Uint64.fromBigInt(BigInt.one),
              ),
            ],
            summary: 'genuine summary',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('genuine summary'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
    },
  );

  testWidgets(
    '"Already have an account?" is tappable and skips straight to the '
    'tutorial via an eager resync instead of the fresh scan',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final auth = AuthController(const UnconfiguredAuthGateway());
      final hub = _ScanHub();
      final services = AppServices.forTesting(
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        auth: auth,
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      );
      addTearDown(services.dispose);
      addTearDown(hub.close);

      await tester.pumpWidget(
        MaterialApp(
          home: OnboardingScreen(
            services: services,
            capabilities: _AllGrantedCapabilities(),
            onFinish: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final button = find.byKey(const Key('already_have_account'));
      expect(button, findsOneWidget);
      await tester.ensureVisible(button);

      await tester.tap(button);
      await tester.pumpAndSettle();

      // Access (login + permissions) is reused, then completing it must
      // skip straight to the tutorial ("use" stage) rather than the fresh
      // on-device scan.
      expect(find.byKey(const Key('shift_left')), findsOneWidget);
      expect(find.byKey(const Key('shift_right')), findsOneWidget);
      expect(hub.scanRequests, isEmpty);
    },
  );
}

final class _AllGrantedCapabilities implements DesktopCapabilityGateway {
  @override
  Future<Map<CoreCapability, CapabilityStatus>> check() async => {
    for (final capability in CoreCapability.values)
      capability: const CapabilityStatus(
        state: CapabilityState.granted,
        detail: 'Verified',
      ),
  };

  @override
  Future<void> request(CoreCapability capability) async {}

  @override
  Future<void> dismissOverlay() async {}
}

final class _ScanHub implements NativeHub, OnboardingScanHub {
  final eventsController = StreamController<NativeEvent>.broadcast();
  final scanRequests = <({String requestId, List<String> roots})>[];
  @override
  bool available = true;

  Future<void> close() => eventsController.close();

  @override
  Stream<NativeEvent> get events => eventsController.stream;

  @override
  Future<void> initialize() async {}

  @override
  void configureMemory({
    required String requestId,
    required String databasePath,
    required String tenantId,
    required String personId,
  }) {}

  @override
  void scanOnboarding({
    required String requestId,
    required List<String> roots,
    required bool includeAppleNotes,
    required bool includeAppleMail,
    required int recordedAtMs,
  }) {
    scanRequests.add((requestId: requestId, roots: roots));
  }

  @override
  void capture({
    required String requestId,
    required String ingestionKey,
    required CaptureSource source,
    required int occurredAtMs,
    required int recordedAtMs,
    String? text,
    String? application,
    String? windowTitle,
    TranscriptLocator? transcriptLocator,
  }) {}

  @override
  void search({
    required String requestId,
    required String query,
    int limit = 12,
    int? asOfValidAtMs,
    int? asOfRecordedAtMs,
  }) {}

  @override
  void exportMemory({
    required String requestId,
    int afterCommit = 0,
    int afterEventIndex = -1,
    int? highWaterMark,
    int limit = 100,
  }) {}

  @override
  void listMemoryItems({required String requestId, int limit = 50}) {}

  @override
  void correctMemory({
    required String requestId,
    required String claimId,
    required String text,
    required String value,
    required int occurredAtMs,
    required int recordedAtMs,
  }) {}

  @override
  void deleteMemorySource({
    required String requestId,
    required String sourceId,
    required int deletedAtMs,
  }) {}

  @override
  void sendMessage({
    required String requestId,
    required String text,
    String? conversationId,
  }) {}

  @override
  void configureAssistant({
    required String requestId,
    required AssistantProvider provider,
    required String model,
    required String credential,
    String? endpoint,
  }) {}

  @override
  void configureTrustedAssistant({
    required String requestId,
    required String managedWorkerOrigin,
  }) {}

  @override
  void clearAssistant(String requestId) {}

  @override
  void decideApproval({
    required String requestId,
    required String proposalId,
    required ApprovalDecision decision,
    ComputerUseAuthorityReceipt? authorityReceipt,
  }) {}

  @override
  void startTranscription({
    required String requestId,
    required String audioStreamId,
    required String deviceId,
    required TranscriptionAuth auth,
    required String language,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
  }) {}

  @override
  void stopTranscription({
    required String requestId,
    required String audioStreamId,
  }) {}

  @override
  void cancel(String requestId) {}

  @override
  void sendAudio({
    required String requestId,
    required int sequence,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
    required bool endOfStream,
    required Uint8List bytes,
  }) {}

  @override
  void dispose() {}
}
