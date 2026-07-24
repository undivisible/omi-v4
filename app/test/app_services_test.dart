import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/api/dev_assistant.dart';
import 'package:omi/api/worker_http.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/conversations/conversations.dart';
import 'package:omi/currents/currents.dart';
import 'package:omi/features/chat_screen.dart';
import 'package:omi/features/cursor_pill_controller.dart';
import 'package:omi/keyboard/keyboard.dart';
import 'package:omi/native/generated/signals/signals.dart';
import 'package:omi/native/native_hub.dart';
import 'package:omi/providers/providers.dart';
import 'package:omi/settings/system_audio_capture_mode_store.dart'
    show VolatileSystemAudioCaptureModeStore;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // Dev-key resolution reads real files (worker/.dev.vars relative to cwd),
  // which would make signed-out behavior depend on the machine running the
  // tests. Every test starts with no dev key; opt in per test.
  setUp(() => debugDevAssistantAccess = DevAssistantAccess.none);
  tearDownAll(() => debugDevAssistantAccess = DevAssistantAccess.none);
  test('onboarding profile capture sends a chat memory event', () async {
    final auth = AuthController(
      _FakeAuthGateway(_session('user-a')),
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    await services.initialize();

    await services.captureOnboardingProfile(
      name: 'Ada',
      languages: ['English', 'French'],
    );

    final capture = hub.captures.single;
    expect(capture.source, CaptureSource.chat);
    expect(capture.text, 'The user’s name is Ada. They speak English, French.');
    services.dispose();
  });

  test(
    'onboarding profile capture configures local memory before capturing '
    'when auth is unavailable, instead of skipping memory configuration',
    () async {
      final auth = AuthController(const UnconfiguredAuthGateway());
      final hub = _FakeHub();
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      );

      // No services.initialize() call: this reproduces the cold-start race
      // where captureOnboardingProfile can run before configureMemory has.
      await services.captureOnboardingProfile(
        name: 'Ada',
        languages: ['English'],
      );

      expect(hub.databasePaths, isNotEmpty);
      expect(
        hub.captures.single.text,
        'The user’s name is Ada. They speak English.',
      );
      services.dispose();
      await hub.close();
    },
  );

  test(
    'onboarding profile capture skips without processing authority',
    () async {
      final auth = AuthController(
        _FakeAuthGateway(_session('user-a')),
        consentStore: VolatileConsentStore(),
      );
      await auth.restoreSession();
      final hub = _FakeHub();
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      );
      await services.initialize();

      await services.captureOnboardingProfile(
        name: 'Ada',
        languages: ['English'],
      );

      expect(hub.captures, isEmpty);
      services.dispose();
    },
  );

  test('system audio capture mode is resent on connect and meeting auth is '
      'minted when a meeting becomes active', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final auth = AuthController(
      _FakeAuthGateway(_session('user-a')),
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final store = VolatileSystemAudioCaptureModeStore()
      ..value = SystemAudioCaptureMode.always;
    final managedStt = _FakeManagedStt(_managedSession('user-a'));
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      managedStt: managedStt,
      captureModeStore: store,
    );
    await services.initialize();
    await _waitFor(() => hub.captureModes.isNotEmpty);
    expect(hub.captureModes.single, SystemAudioCaptureMode.always);

    await services.setSystemAudioCaptureMode(SystemAudioCaptureMode.never);
    expect(store.value, SystemAudioCaptureMode.never);
    expect(hub.captureModes.last, SystemAudioCaptureMode.never);
    expect(await services.systemAudioCaptureMode, SystemAudioCaptureMode.never);

    hub.eventsController.add(
      const NativeEventMeetingStateChanged(
        value: MeetingStateChanged(active: true, suggestedTitle: null),
      ),
    );
    await _waitFor(() => hub.meetingAuth.isNotEmpty);
    final request = managedStt.requests.single;
    expect(request.sampleRate, 16000);
    expect(request.channels, 1);
    expect(request.encoding, ManagedSttEncoding.linear16);
    final (mintedAuth, origin) = hub.meetingAuth.single;
    expect(mintedAuth, isA<TranscriptionAuthManaged>());
    expect(origin, 'https://api.example.test/');

    hub.eventsController.add(
      const NativeEventError(
        value: NativeError(
          requestId: 'meeting-capture',
          code: 'meeting_capture_session_lost',
          message: 'meeting capture transcription session was lost',
          retryable: true,
        ),
      ),
    );
    await _waitFor(() => hub.meetingAuth.length == 2);
    services.dispose();
  });

  test(
    'desktop channel inbox runs one stable assistant request at a time',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final auth = AuthController(
        _FakeAuthGateway(_session('user-a')),
        consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
      );
      await auth.restoreSession();
      final hub = _FakeHub();
      final inbox = _FakeConversationInboxTransport()
        ..completionFailures = 1
        ..items.add(
          const ConversationInboxItem(
            id: 'inbox-message-1',
            channel: 'telegram',
            text: 'What should I focus on?',
            channelMessageId: 'telegram-message-1',
            receivedAt: 1,
            attempt: 2,
            leaseToken: 'lease-token-1',
            leaseUntil: 4102444800000,
            memoryContext: 'Relevant synced memory:\n- Sam prefers espresso',
          ),
        )
        ..items.add(
          const ConversationInboxItem(
            id: 'inbox-message-action',
            channel: 'telegram',
            text: 'Click the button',
            channelMessageId: 'telegram-message-action',
            receivedAt: 2,
            attempt: 1,
            leaseToken: 'lease-token-action',
            leaseUntil: 300002,
          ),
        );
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
        conversationInbox: inbox,
        inboxPollInterval: const Duration(milliseconds: 1),
      );

      await services.initialize();
      await _waitFor(() => hub.messages.isNotEmpty);
      expect(hub.messages.single, (
        'chat-channel:inbox-message-1:2',
        'What should I focus on?',
      ));
      expect(
        hub.memoryContexts.single,
        'Relevant synced memory:\n- Sam prefers espresso',
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(inbox.claims, 1);

      hub.eventsController.add(
        const NativeEventAssistantDelta(
          value: AssistantDelta(
            requestId: 'chat-channel:inbox-message-1:2',
            text: 'Finish ',
            finalSegment: false,
          ),
        ),
      );
      hub.eventsController.add(
        const NativeEventAssistantDelta(
          value: AssistantDelta(
            requestId: 'chat-channel:inbox-message-1:2',
            text: 'the launch.',
            finalSegment: true,
          ),
        ),
      );
      await _waitFor(() => inbox.completed.isNotEmpty);
      expect(inbox.completed.single.outcome, ConversationInboxOutcome.done);
      expect(inbox.completed.single.responseText, 'Finish the launch.');
      expect(inbox.completionCalls, 2);
      expect(
        hub.messages
            .where((message) => message.$1 == 'chat-channel:inbox-message-1:2')
            .length,
        1,
      );
      await _waitFor(() => hub.messages.length == 2);
      hub.eventsController.add(
        const NativeEventActionProposal(
          value: ActionProposal(
            proposalId: 'channel-action',
            requestId: 'chat-channel:inbox-message-action:1',
            title: 'Click on screen',
            summary: 'Click at (10, 20)',
            risk: ActionRisk.external,
          ),
        ),
      );
      hub.eventsController.add(
        const NativeEventAssistantDelta(
          value: AssistantDelta(
            requestId: 'chat-channel:inbox-message-action:1',
            text: '',
            finalSegment: true,
          ),
        ),
      );
      await _waitFor(() => inbox.completed.length == 2);
      expect(
        inbox.completed.last.responseText,
        'Approval required on desktop: Click on screen — Click at (10, 20)',
      );

      services.dispose();
      await hub.close();
    },
  );

  test('desktop channel inbox retries terminal assistant failures', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final auth = AuthController(
      _FakeAuthGateway(_session('user-a')),
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final inbox = _FakeConversationInboxTransport()
      ..items.add(
        const ConversationInboxItem(
          id: 'inbox-message-2',
          channel: 'blooio',
          text: 'Summarize today',
          channelMessageId: 'blooio-message-1',
          receivedAt: 1,
          attempt: 1,
          leaseToken: 'lease-token-2',
          leaseUntil: 300001,
        ),
      );
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      conversationInbox: inbox,
      inboxPollInterval: const Duration(milliseconds: 1),
    );

    await services.initialize();
    await _waitFor(() => hub.messages.isNotEmpty);
    hub.eventsController.add(
      const NativeEventError(
        value: NativeError(
          requestId: 'chat-channel:inbox-message-2:1',
          code: 'provider_unavailable',
          message: 'Try later',
          retryable: true,
        ),
      ),
    );
    await _waitFor(() => inbox.completed.isNotEmpty);
    expect(inbox.completed.single.outcome, ConversationInboxOutcome.retry);
    expect(inbox.completed.single.error, 'Try later');

    services.dispose();
    await hub.close();
  });

  test(
    'desktop channel inbox fences late replies after authority loss',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final gateway = _FakeAuthGateway(_session('user-a'));
      final auth = AuthController(
        gateway,
        consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
      );
      await auth.restoreSession();
      final hub = _FakeHub();
      final inbox = _FakeConversationInboxTransport()
        ..items.add(
          const ConversationInboxItem(
            id: 'inbox-message-3',
            channel: 'telegram',
            text: 'Private request',
            channelMessageId: 'telegram-message-3',
            receivedAt: 1,
            attempt: 1,
            leaseToken: 'lease-token-3',
            leaseUntil: 300001,
          ),
        );
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
        conversationInbox: inbox,
        inboxPollInterval: const Duration(milliseconds: 1),
      );

      await services.initialize();
      await _waitFor(() => hub.messages.isNotEmpty);
      gateway.emit(null);
      await _waitFor(
        () => hub.cancelled.contains('chat-channel:inbox-message-3:1'),
      );
      hub.eventsController.add(
        const NativeEventAssistantDelta(
          value: AssistantDelta(
            requestId: 'chat-channel:inbox-message-3:1',
            text: 'Must not cross accounts',
            finalSegment: true,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(inbox.completed, isEmpty);

      services.dispose();
      await hub.close();
    },
  );

  testWidgets('chat sends, streams progress, cancels, and approves proposals', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final auth = AuthController(
      _FakeAuthGateway(_session('user-a')),
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final conversations = _FakeConversationTransport();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      conversations: conversations,
    );
    await services.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatScreen(services: services)),
      ),
    );

    await tester.enterText(find.byKey(const Key('chat_input')), 'Help me plan');
    await tester.tap(find.byKey(const Key('send_chat')));
    await tester.pump();
    // Let the send transition land: mid-flight the exchange is still climbing
    // into the viewport and nothing in it can be tapped.
    await tester.pump(const Duration(milliseconds: 900));
    final requestId = hub.messages.single.$1;
    expect(hub.messages.single.$2, 'Help me plan');
    expect(conversations.appended.single.text, 'Help me plan');
    expect(
      conversations.appended.single.clientMessageId,
      matches(RegExp(r'^chat-[a-f0-9]{32}-g0-\d+$')),
    );
    expect(find.text('Help me plan'), findsOneWidget);

    hub.eventsController.add(
      const NativeEventActionProposal(
        value: ActionProposal(
          proposalId: 'unowned',
          requestId: 'other-request',
          title: 'Unowned',
          summary: 'Must not appear',
          risk: ActionRisk.reversible,
        ),
      ),
    );
    hub.eventsController.add(
      NativeEventActionProposal(
        value: ActionProposal(
          proposalId: 'expired',
          requestId: requestId,
          title: 'Expired',
          summary: 'Must not appear',
          risk: ActionRisk.reversible,
          expiresAtMs: DateTime.now().millisecondsSinceEpoch - 1,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Unowned'), findsNothing);
    expect(find.text('Expired'), findsNothing);

    hub.eventsController.add(
      NativeEventAssistantDelta(
        value: AssistantDelta(
          requestId: requestId,
          text: 'I can ',
          finalSegment: false,
        ),
      ),
    );
    hub.eventsController.add(
      NativeEventAssistantDelta(
        value: AssistantDelta(
          requestId: requestId,
          text: 'help.',
          finalSegment: false,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('I can help.'), findsOneWidget);

    hub.eventsController.add(
      NativeEventToolProgress(
        value: ToolProgress(
          requestId: requestId,
          tool: 'planner',
          status: ToolStatus.running,
          detail: 'Reading tasks',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('planner · running · Reading tasks'), findsOneWidget);

    hub.eventsController.add(
      const NativeEventRuntimeStatus(
        value: RuntimeStatus(
          phase: RuntimePhase.ready,
          computerUseAvailable: true,
          computerUseCapabilities: ComputerUseCapabilities(
            platform: 'macos',
            backend: 'praefectus-accessibility',
            sessionIsolation: ComputerUseSessionIsolation.sharedDesktop,
            permissions: [
              ComputerUsePermission(name: 'accessibility', granted: true),
            ],
            actions: [
              ComputerUseActionCapability(
                name: 'invoke',
                available: true,
                deliveryRoute: ComputerUseDeliveryRoute.targetAddressed,
                backgroundSupport: ComputerUseBackgroundSupport.guarded,
              ),
              ComputerUseActionCapability(
                name: 'set_value',
                available: true,
                deliveryRoute: ComputerUseDeliveryRoute.targetAddressed,
                backgroundSupport: ComputerUseBackgroundSupport.guarded,
              ),
            ],
          ),
          localAiAvailable: false,
          memoryAvailable: true,
          agentHarnessAvailable: true,
        ),
      ),
    );
    hub.eventsController.add(
      NativeEventActionProposal(
        value: ActionProposal(
          proposalId: 'proposal-1',
          requestId: requestId,
          title: 'Create task',
          summary: 'Add the task to your list.',
          risk: ActionRisk.reversible,
          computerAction: const ComputerUseActionInvoke(
            targetName: 'Save',
            backgroundOnly: false,
          ),
          operationId: 'operation-1',
          actionHash: List.filled(64, 'a').join(),
          targetProvenance: ComputerUseTargetProvenance(
            processId: 42,
            processGeneration: 'process-generation-1',
            windowId: 'window-1',
            role: 'button',
            observationGeneration: Uint64.fromBigInt(BigInt.from(9)),
          ),
        ),
      ),
    );
    hub.eventsController.add(
      NativeEventActionProposal(
        value: ActionProposal(
          proposalId: 'proposal-type',
          requestId: requestId,
          title: 'Type response',
          summary: 'Type 23 bytes',
          risk: ActionRisk.external,
          computerAction: const ComputerUseActionSetValue(
            targetName: 'Response',
            value: 'send the exact response',
            backgroundOnly: true,
          ),
          operationId: 'operation-2',
          actionHash: List.filled(64, 'b').join(),
          targetProvenance: ComputerUseTargetProvenance(
            processId: 42,
            processGeneration: 'process-generation-1',
            windowId: 'window-1',
            role: 'text_field',
            observationGeneration: Uint64.fromBigInt(BigInt.from(9)),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Invoke “Save” · Interactive'), findsOneWidget);
    expect(find.text('send the exact response'), findsOneWidget);
    expect(find.text('Background only'), findsOneWidget);
    expect(
      find.textContaining('Conservative risk: external side effect'),
      findsOneWidget,
    );
    expect(find.textContaining('process 42'), findsNWidgets(2));
    expect(
      find.textContaining('guarded shared-desktop background'),
      findsNWidgets(2),
    );
    hub.executableProposals.add('proposal-1');
    final approve = find.byKey(const ValueKey('approve_proposal-1'));
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    expect(hub.approvals.map((approval) => approval.$1), ['proposal-1']);
    expect(hub.executedProposals, ['proposal-1']);
    final approvalRequestId = hub.approvalRequests.single.$1;
    services.cancelChatRequest(approvalRequestId);
    expect(hub.cancelled, contains(approvalRequestId));
    hub.eventsController.add(
      NativeEventActionProposal(
        value: ActionProposal(
          proposalId: 'proposal-non-executable',
          requestId: requestId,
          title: 'Review plan',
          summary: 'No computer action attached.',
          risk: ActionRisk.reversible,
        ),
      ),
    );
    await tester.pump();
    final approveNonExecutable = find.byKey(
      const ValueKey('approve_proposal-non-executable'),
    );
    await tester.ensureVisible(approveNonExecutable);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(approveNonExecutable);
    expect(hub.approvals.map((approval) => approval.$1), [
      'proposal-1',
      'proposal-non-executable',
    ]);
    expect(hub.executedProposals, ['proposal-1']);
    hub.eventsController.add(
      NativeEventActionProposal(
        value: ActionProposal(
          proposalId: 'proposal-cancelled',
          requestId: requestId,
          title: 'Must disappear',
          summary: 'This belongs to cancelled work.',
          risk: ActionRisk.reversible,
          expiresAtMs: DateTime.now().millisecondsSinceEpoch + 60000,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Must disappear'), findsOneWidget);
    await tester.tap(find.byKey(const Key('cancel_chat')));
    expect(hub.cancelled, contains(requestId));
    await tester.pump();
    expect(find.text('Must disappear'), findsNothing);

    services.dispose();
    await tester.pump();
    await hub.close();
  });

  testWidgets('preview chat never subscribes or dispatches actions', (
    tester,
  ) async {
    final auth = AuthController(
      _FakeAuthGateway(_session('user-a')),
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    await services.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatScreen(services: services, previewMode: true)),
      ),
    );
    hub.eventsController.add(
      const NativeEventError(
        value: NativeError(
          code: 'test_error',
          message: 'must remain hidden',
          retryable: false,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('must remain hidden'), findsNothing);
    expect(
      tester.widget<TextField>(find.byKey(const Key('chat_input'))).enabled,
      isFalse,
    );
    expect(hub.messages, isEmpty);

    services.dispose();
    await tester.pump();
    await hub.close();
  });

  testWidgets('chat clears prior-account messages on authority change', (
    tester,
  ) async {
    final gateway = _FakeAuthGateway(_session('user-a'));
    final auth = AuthController(
      gateway,
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final conversations = _FakeConversationTransport();
    final replay = Completer<List<ConversationMessage>>();
    conversations.replayBarrier = replay;
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      conversations: conversations,
    );
    await services.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatScreen(services: services)),
      ),
    );

    gateway.emit(_session('user-b'));
    await tester.pump();
    expect(auth.snapshot.session?.uid, 'user-b');
    replay.complete(const [
      ConversationMessage(
        cursor: 1,
        clientMessageId: 'private-message',
        role: 'user',
        source: 'app',
        text: 'user-a private history',
        createdAt: 1,
      ),
    ]);
    await tester.pump();

    expect(find.text('user-a private history'), findsNothing);
    services.dispose();
    await tester.pump();
    await hub.close();
  });

  testWidgets('chat refreshes remote messages without replacing local state', (
    tester,
  ) async {
    final auth = AuthController(
      _FakeAuthGateway(_session('user-a')),
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final conversations = _FakeConversationTransport();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      conversations: conversations,
    );
    await services.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatScreen(services: services)),
      ),
    );
    await tester.pump();

    await tester.enterText(
      find.byKey(const Key('chat_input')),
      'Local thought',
    );
    await tester.tap(find.byKey(const Key('send_chat')));
    await tester.pump();
    conversations.replayed.addAll(const [
      ConversationMessage(
        cursor: 1,
        clientMessageId: 'telegram:message-1',
        role: 'user',
        source: 'telegram',
        text: 'Remote thought',
        createdAt: 1,
      ),
      ConversationMessage(
        cursor: 2,
        clientMessageId: 'assistant:chat-remote',
        role: 'assistant',
        source: 'telegram',
        text: 'Remote answer',
        createdAt: 2,
      ),
    ]);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.text('Local thought'), findsOneWidget);
    expect(find.text('Remote thought'), findsOneWidget);
    expect(find.text('Remote answer'), findsOneWidget);
    expect(conversations.replayAfter, [0, 0]);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('Remote thought'), findsOneWidget);
    expect(find.text('Remote answer'), findsOneWidget);
    expect(conversations.replayAfter, [0, 0, 2]);

    services.dispose();
    await tester.pump();
    await hub.close();
  });

  test('native approval authority blocks replay until acknowledged', () async {
    final auth = AuthController(
      _FakeAuthGateway(_session('user-a')),
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub()
      ..failAtomicApproval = true
      ..executableProposals.add('atomic-retry');
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    await services.initialize();
    final parentRequestId = await services.sendChatMessage(text: 'Click it');
    hub.eventsController.add(
      NativeEventActionProposal(
        value: ActionProposal(
          proposalId: 'atomic-retry',
          requestId: parentRequestId,
          title: 'Click',
          summary: 'Click once',
          risk: ActionRisk.reversible,
          computerAction: const ComputerUseActionInvoke(
            targetName: 'Save',
            backgroundOnly: false,
          ),
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    await expectLater(
      services.decideChatApproval(
        proposalId: 'atomic-retry',
        decision: ApprovalDecision.approveOnce,
      ),
      throwsStateError,
    );
    hub.failAtomicApproval = false;
    hub.rejectAtomicApproval = true;
    await services.decideChatApproval(
      proposalId: 'atomic-retry',
      decision: ApprovalDecision.approveOnce,
    );
    await Future<void>.delayed(Duration.zero);

    hub.rejectAtomicApproval = false;
    hub.dropAtomicApproval = true;
    final ambiguousRequestId = await services.decideChatApproval(
      proposalId: 'atomic-retry',
      decision: ApprovalDecision.approveOnce,
    );
    await Future<void>.delayed(Duration.zero);

    hub.dropAtomicApproval = false;
    await expectLater(
      services.decideChatApproval(
        proposalId: 'atomic-retry',
        decision: ApprovalDecision.approveOnce,
      ),
      throwsStateError,
    );
    hub.eventsController.add(
      NativeEventApprovalDecisionAcknowledged(
        value: ApprovalDecisionAcknowledgement(
          requestId: ambiguousRequestId,
          proposalId: 'atomic-retry',
          decision: ApprovalDecision.approveOnce,
          accepted: true,
          executionPending: true,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await expectLater(
      services.decideChatApproval(
        proposalId: 'atomic-retry',
        decision: ApprovalDecision.approveOnce,
      ),
      throwsStateError,
    );

    services.dispose();
    await hub.close();
  });

  for (final outcomeCase
      in <
        ({
          String name,
          NativeEvent Function(String requestId) terminal,
          String state,
          String detail,
        })
      >[
        (
          name: 'unknown',
          terminal: (requestId) => NativeEventError(
            value: NativeError(
              requestId: requestId,
              code: 'computer_use_outcome_unknown',
              message: 'Outcome unknown.',
              retryable: false,
            ),
          ),
          state: 'outcome_unknown',
          detail:
              'Approved computer action outcome is unknown; automatic retry is prohibited.',
        ),
        (
          name: 'failed before effect',
          terminal: (requestId) => NativeEventError(
            value: NativeError(
              requestId: requestId,
              code: 'computer_use_unavailable',
              message: 'Computer use unavailable.',
              retryable: false,
            ),
          ),
          state: 'failed',
          detail: 'Native execution failed.',
        ),
        (
          name: 'cancelled before effect',
          terminal: (requestId) => NativeEventToolProgress(
            value: ToolProgress(
              requestId: requestId,
              tool: 'request',
              status: ToolStatus.cancelled,
              detail: 'request cancelled',
            ),
          ),
          state: 'cancelled_before_effect',
          detail: 'Approved computer action was cancelled before any effect.',
        ),
        (
          name: 'expired before effect',
          terminal: (requestId) => NativeEventError(
            value: NativeError(
              requestId: requestId,
              code: 'proposal_expired',
              message: 'Expired before effect.',
              retryable: false,
            ),
          ),
          state: 'expired_before_effect',
          detail: 'Approved computer action expired before any effect.',
        ),
      ]) {
    test(
      'Current approval is consumed before native dispatch and records ${outcomeCase.name}',
      () async {
        final auth = AuthController(
          _FakeAuthGateway(_session('user-a')),
          consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
        );
        await auth.restoreSession();
        final hub = _FakeHub()
          ..executableProposals.add('current-proposal')
          ..rejectAtomicApprovalWithoutFollowup =
              outcomeCase.state != 'outcome_unknown';
        final currentsTransport = _CurrentApprovalTransport(hub);
        final services = AppServices.forTesting(
          auth: auth,
          nativeHub: hub,
          deviceRelay: DeviceRelayService(
            role: DeviceRelayRole.desktopObserver,
            adapter: const UnavailableDeviceRelayAdapter(),
          ),
          memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
          currentsClient: CurrentsClient(currentsTransport),
        );
        await services.initialize();
        final parentRequestId = await services.handoffCurrentAction(
          const CurrentActionHandoff(
            executionId: 'execution-1',
            approvalNonce: 'nonce-1',
            instruction: 'Invoke Save',
            policyGeneration: 3,
          ),
        );
        hub.eventsController.add(
          NativeEventActionProposal(
            value: ActionProposal(
              proposalId: 'current-proposal',
              requestId: parentRequestId,
              title: 'Invoke Save',
              summary: 'Invoke the exact accessible target.',
              risk: ActionRisk.external,
              computerAction: const ComputerUseActionInvoke(
                targetName: 'Save',
                backgroundOnly: false,
              ),
              operationId: 'operation-1',
              actionHash: List.filled(64, 'a').join(),
              targetProvenance: ComputerUseTargetProvenance(
                processId: 42,
                processGeneration: 'process-generation-1',
                windowId: 'window-1',
                role: 'button',
                observationGeneration: Uint64.fromBigInt(BigInt.from(9)),
              ),
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final approvalRequestId = await services.decideChatApproval(
          proposalId: 'current-proposal',
          decision: ApprovalDecision.approveOnce,
        );

        expect(currentsTransport.approvalObservedBeforeNative, isTrue);
        expect(hub.approvalReceipts.single?.executionId, 'execution-1');
        expect(hub.approvalReceipts.single?.firebaseToken, isNotEmpty);
        expect(
          hub.approvalReceipts.single?.receiptToken,
          '0123456789012345678901234567890123456789012',
        );
        hub.eventsController.add(outcomeCase.terminal(approvalRequestId));
        await _waitFor(() => currentsTransport.outcomes.isNotEmpty);
        expect(currentsTransport.outcomes.single, {
          'state': outcomeCase.state,
          'detail': outcomeCase.detail,
        });

        services.dispose();
        await hub.close();
      },
    );
  }

  test('authority fences chat and tombstones late terminal events', () async {
    final gateway = _FakeAuthGateway(_session('user-a'));
    final auth = AuthController(
      gateway,
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    await services.initialize();
    final received = <NativeEvent>[];
    final subscription = services.nativeEvents.listen(received.add);
    services.configureAssistant(
      provider: AssistantProvider.worker,
      model: 'managed-chat',
      endpoint: 'https://assistant.example.test/v1',
      credential: 'runtime-session-token',
    );
    expect(hub.assistantConfigurations.single.$1, AssistantProvider.worker);
    expect(hub.assistantConfigurations.single.$2, 'managed-chat');
    final requestId = await services.sendChatMessage(text: 'private request');

    gateway.emit(_session('user-b'));
    await _waitFor(() => auth.snapshot.session?.uid == 'user-b');
    hub.eventsController.add(
      NativeEventAssistantDelta(
        value: AssistantDelta(
          requestId: requestId,
          text: 'late data',
          finalSegment: true,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(hub.cancelled, contains(requestId));
    expect(hub.assistantClears, hasLength(1));
    expect(received.whereType<NativeEventAssistantDelta>(), isEmpty);

    await subscription.cancel();
    services.dispose();
    await hub.close();
  });

  test(
    'managed assistant refreshes its Firebase token and clears on revoke',
    () async {
      final now = DateTime.now();
      final gateway = _FakeAuthGateway(_session('user-a'))
        ..refreshResults.addAll([
          AuthSession(
            uid: 'user-a',
            idToken: 'fresh-token-1',
            expiresAt: now.add(const Duration(milliseconds: 40)),
          ),
          AuthSession(
            uid: 'user-a',
            idToken: 'fresh-token-2',
            expiresAt: now.add(const Duration(hours: 1)),
          ),
        ]);
      final auth = AuthController(
        gateway,
        consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
      );
      await auth.restoreSession();
      final hub = _FakeHub();
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
        managedStt: _FakeManagedStt(
          _managedSession('user-a'),
          trustedWorkerOrigin: Uri.parse('https://worker.example.test'),
        ),
        assistantRefreshLead: const Duration(milliseconds: 30),
        assistantMinimumRefreshDelay: const Duration(milliseconds: 5),
      );

      await services.initialize();
      expect(hub.assistantConfigurations.single, (
        AssistantProvider.worker,
        'mimo-v2.5-pro',
        'https://worker.example.test/v1',
        'fresh-token-1',
      ));
      expect(hub.trustedAssistantOrigins, ['https://worker.example.test/']);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(hub.assistantConfigurations, hasLength(2));
      expect(hub.assistantConfigurations.last.$4, 'fresh-token-2');

      final revocation = auth.revokeProcessingConsent();
      expect(hub.assistantClears, hasLength(1));
      await revocation;
      services.dispose();
      await hub.close();
    },
  );

  test('UID-scoped BYOK overrides the managed assistant route', () async {
    final auth = AuthController(
      _FakeAuthGateway(_session('user-a')),
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final credentials = VolatileProviderCredentialStore()
      ..values['user-a'] = const [
        ProviderCredential(
          provider: AssistantProvider.xai,
          model: 'grok-4.5',
          credential: 'user-key',
        ),
      ];
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      providerCredentials: credentials,
      managedStt: _FakeManagedStt(
        _managedSession('user-a'),
        trustedWorkerOrigin: Uri.parse('https://worker.example.test'),
      ),
    );

    await services.initialize();

    expect(hub.assistantConfigurations.single, (
      AssistantProvider.xai,
      'grok-4.5',
      null,
      'user-key',
    ));
    services.dispose();
    await hub.close();
  });

  test('managed assistant rejects a non-origin Worker URL', () async {
    final auth = AuthController(
      _FakeAuthGateway(_session('user-a')),
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    final hub = _FakeHub();

    expect(
      () => AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
        managedStt: _FakeManagedStt(
          _managedSession('user-a'),
          trustedWorkerOrigin: Uri.parse(
            'https://user@worker.example.test/path',
          ),
        ),
      ),
      throwsArgumentError,
    );
    auth.dispose();
    await hub.close();
  });

  test('production initialization scopes memory and forwards events', () async {
    final session = _session('user-a');
    final gateway = _FakeAuthGateway(session);
    final consent = VolatileConsentStore()..receipt = _receipt('user-a');
    final auth = AuthController(gateway, consentStore: consent);
    await auth.restoreSession();
    final hub = _FakeHub();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );

    await services.initialize();
    final received = services.nativeEvents.first;
    const event = NativeEventRuntimeStatus(
      value: RuntimeStatus(
        phase: RuntimePhase.ready,
        computerUseAvailable: false,
        localAiAvailable: false,
        memoryAvailable: true,
        agentHarnessAvailable: true,
      ),
    );
    hub.eventsController.add(event);

    expect(hub.initializeCalls, 1);
    expect(hub.databasePaths, ['/tmp/user-a.sqlite3']);
    expect(hub.personIds, ['user-a']);
    expect(await received, event);
    services.dispose();
    await hub.close();
  });

  test('no current consent keeps native services inert', () async {
    final gateway = _FakeAuthGateway(_session('user-a'));
    final auth = AuthController(gateway);
    await auth.restoreSession();
    final hub = _FakeHub();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );

    await services.initialize();

    expect(hub.initializeCalls, 0);
    expect(hub.databasePaths, isEmpty);
    services.dispose();
    await hub.close();
  });

  test(
    'onboarding scan starts native services without memory authority',
    () async {
      final auth = AuthController(_FakeAuthGateway(null));
      final hub = _FakeHub();
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      );

      await services.initialize();
      final requestId = await services.scanOnboardingSources();

      expect(hub.initializeCalls, 1);
      expect(hub.databasePaths, isEmpty);
      expect(hub.scanRequests.single.requestId, requestId);
      services.dispose();
      await hub.close();
    },
  );

  test('in-flight transcripts enforce immutable UID-scoped payloads', () async {
    final gateway = _FakeAuthGateway(_session('user-a'));
    final auth = AuthController(
      gateway,
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      now: () => DateTime.fromMillisecondsSinceEpoch(2_500),
    );
    await services.initialize();
    final errors = <Object>[];
    final errorSubscription = services.nativeEvents.listen(
      (_) {},
      onError: errors.add,
    );

    final partial = NativeEventTranscriptDelta(
      value: TranscriptDelta(
        requestId: 'audio-1',
        audioStreamId: 'omi-stream-1',
        segmentId: 'omi-stream-1-segment-0',
        segmentSequence: Uint64.fromBigInt(BigInt.zero),
        sttEpoch: 1,
        deviceId: 'omi-device-1',
        provider: 'deepgram',
        startMs: 0,
        endMs: 900,
        occurredAtMs: 1000,
        text: 'unfinished',
        finalSegment: false,
      ),
    );
    final completed = NativeEventTranscriptDelta(
      value: TranscriptDelta(
        requestId: 'audio-1',
        audioStreamId: 'omi-stream-1',
        segmentId: 'omi-stream-1-segment-1',
        segmentSequence: Uint64.fromBigInt(BigInt.one),
        sttEpoch: 1,
        deviceId: 'omi-device-1',
        provider: 'deepgram',
        startMs: 900,
        endMs: 1900,
        occurredAtMs: 2000,
        text: ' Remember this ',
        finalSegment: true,
        language: 'en',
      ),
    );
    hub.eventsController
      ..add(partial)
      ..add(completed)
      ..add(
        completed.copyWith(
          value: completed.value.copyWith(requestId: 'audio-recreated'),
        ),
      );
    await _waitFor(() => hub.captures.length == 1);
    hub.eventsController.add(
      completed.copyWith(
        value: completed.value.copyWith(
          requestId: 'audio-retry-with-conflict',
          deviceId: 'changed-device',
        ),
      ),
    );
    await _waitFor(() => errors.isNotEmpty);

    expect(hub.captures.map((capture) => capture.text), ['Remember this']);
    expect(hub.captures.map((capture) => capture.source), [
      CaptureSource.omiDevice,
    ]);
    expect(hub.captures.single.occurredAtMs, 2000);
    expect(hub.captures.single.recordedAtMs, 2500);
    expect(hub.captures.single.transcriptLocator?.deviceId, 'omi-device-1');
    expect(hub.captures.single.transcriptLocator?.provider, 'deepgram');
    expect(hub.captures.single.transcriptLocator?.streamId, 'omi-stream-1');
    expect(
      hub.captures.single.transcriptLocator?.segmentId,
      'omi-stream-1-segment-1',
    );
    expect(hub.captures.single.transcriptLocator?.startMs, 900);
    expect(hub.captures.single.transcriptLocator?.endMs, 1900);
    expect(errors.single, isA<TranscriptCaptureConflict>());

    hub.eventsController.add(
      NativeEventMemoryCaptured(
        value: MemoryCaptured(
          requestId: hub.captures.single.requestId,
          sourceId: 'source-1',
          evidenceId: 'evidence-1',
        ),
      ),
    );
    hub.eventsController.add(completed);
    await Future<void>.delayed(Duration.zero);
    expect(hub.captures, hasLength(1));
    hub.eventsController.add(
      completed.copyWith(value: completed.value.copyWith(occurredAtMs: 2001)),
    );
    await _waitFor(() => errors.length == 2);
    expect(errors.last, isA<TranscriptCaptureConflict>());

    gateway.emit(_session('user-b'));
    await _waitFor(() => hub.disposeCalls == 1);
    hub.eventsController.add(completed);
    await Future<void>.delayed(Duration.zero);
    expect(hub.captures, hasLength(1));
    services.dispose();
    await errorSubscription.cancel();
    await hub.close();
  });

  test('completed transcript ledger evicts its oldest fingerprint', () async {
    final gateway = _FakeAuthGateway(_session('user-a'));
    final auth = AuthController(
      gateway,
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    await services.initialize();

    NativeEventTranscriptDelta event(int sequence) =>
        NativeEventTranscriptDelta(
          value: TranscriptDelta(
            requestId: 'stream',
            audioStreamId: 'omi-stream-ledger',
            segmentId: 'omi-stream-ledger-segment-$sequence',
            segmentSequence: Uint64.fromBigInt(BigInt.from(sequence)),
            sttEpoch: 1,
            deviceId: 'omi-device-ledger',
            provider: 'deepgram',
            startMs: sequence * 1000,
            endMs: sequence * 1000 + 900,
            occurredAtMs: sequence,
            text: 'segment $sequence',
            finalSegment: true,
          ),
        );
    for (var sequence = 0; sequence <= 256; sequence += 1) {
      hub.eventsController.add(event(sequence));
      await _waitFor(() => hub.captures.length == sequence + 1);
      final capture = hub.captures.last;
      hub.eventsController.add(
        NativeEventMemoryCaptured(
          value: MemoryCaptured(
            requestId: capture.requestId,
            sourceId: 'source-$sequence',
            evidenceId: 'evidence-$sequence',
          ),
        ),
      );
    }
    await Future<void>.delayed(Duration.zero);
    hub.eventsController.add(event(0));
    await _waitFor(() => hub.captures.length == 258);

    services.dispose();
    await hub.close();
  });

  test('late revoked completion cannot acknowledge same-UID regrant', () async {
    final session = _session('user-a');
    final gateway = _FakeAuthGateway(session);
    final auth = AuthController(
      gateway,
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    await services.initialize();
    final transcript = NativeEventTranscriptDelta(
      value: TranscriptDelta(
        requestId: 'same-stream',
        audioStreamId: 'omi-stream-regrant',
        segmentId: 'omi-stream-regrant-segment-1',
        segmentSequence: Uint64.fromBigInt(BigInt.one),
        sttEpoch: 1,
        deviceId: 'omi-device-regrant',
        provider: 'deepgram',
        startMs: 3000,
        endMs: 3900,
        occurredAtMs: 4000,
        text: 'same evidence',
        finalSegment: true,
      ),
    );

    hub.eventsController.add(transcript);
    await _waitFor(() => hub.captures.length == 1);
    final oldCapture = hub.captures.single;
    await auth.revokeProcessingConsent();
    await _waitFor(() => hub.disposeCalls == 1);

    gateway.emit(session);
    await _waitFor(() => auth.snapshot.phase == AuthPhase.signedIn);
    await auth.grantProcessingConsent();
    await _waitFor(() => hub.initializeCalls == 2);
    hub.eventsController.add(transcript);
    await _waitFor(() => hub.captures.length == 2);
    final newCapture = hub.captures.last;
    expect(newCapture.ingestionKey, oldCapture.ingestionKey);
    expect(newCapture.requestId, isNot(oldCapture.requestId));

    hub.eventsController.add(
      NativeEventMemoryCaptured(
        value: MemoryCaptured(
          requestId: oldCapture.requestId,
          sourceId: 'old-source',
          evidenceId: 'old-evidence',
        ),
      ),
    );
    hub.eventsController.add(transcript);
    await Future<void>.delayed(Duration.zero);
    expect(hub.captures, hasLength(2));
    hub.eventsController.add(
      NativeEventMemoryCaptured(
        value: MemoryCaptured(
          requestId: newCapture.requestId,
          sourceId: 'new-source',
          evidenceId: 'new-evidence',
        ),
      ),
    );
    hub.eventsController.add(transcript);
    await Future<void>.delayed(Duration.zero);
    expect(hub.captures, hasLength(2));

    services.dispose();
    await hub.close();
  });

  test(
    'account switch removes authority until the new subject consents',
    () async {
      final gateway = _FakeAuthGateway(_session('user-a'));
      final consent = VolatileConsentStore()..receipt = _receipt('user-a');
      final auth = AuthController(gateway, consentStore: consent);
      await auth.restoreSession();
      final hub = _FakeHub();
      final adapter = _DeviceAdapter();
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.mobileOwner,
          adapter: adapter,
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      );
      await services.initialize();

      gateway.emit(_session('user-b'));
      await _waitFor(() => hub.disposeCalls == 1);

      expect(adapter.disconnectCalls, greaterThanOrEqualTo(2));
      expect(hub.databasePaths, ['/tmp/user-a.sqlite3']);
      expect(hub.personIds, ['user-a']);
      expect(auth.snapshot.hasProcessingAuthority, isFalse);
      services.dispose();
      await hub.close();
      await adapter.close();
    },
  );

  test('consent revocation stops capture and shuts native down', () async {
    final gateway = _FakeAuthGateway(_session('user-a'));
    final consent = VolatileConsentStore()..receipt = _receipt('user-a');
    final auth = AuthController(gateway, consentStore: consent);
    await auth.restoreSession();
    final hub = _FakeHub();
    final adapter = _DeviceAdapter();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.mobileOwner,
        adapter: adapter,
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    await services.initialize();
    hub.eventsController.add(
      NativeEventTranscriptDelta(
        value: TranscriptDelta(
          requestId: 'audio-revoked',
          audioStreamId: 'omi-stream-revoked',
          segmentId: 'omi-stream-revoked-segment-0',
          segmentSequence: Uint64.fromBigInt(BigInt.zero),
          sttEpoch: 1,
          deviceId: 'omi-device-revoked',
          provider: 'deepgram',
          startMs: 2000,
          endMs: 2900,
          occurredAtMs: 3000,
          text: 'must not outlive consent',
          finalSegment: true,
        ),
      ),
    );
    await _waitFor(() => hub.captures.length == 1);
    hub.failCancel = true;

    await auth.revokeProcessingConsent();
    await _waitFor(() => hub.disposeCalls == 1);

    expect(adapter.disconnectCalls, greaterThanOrEqualTo(2));
    expect(hub.cancelled, contains(hub.captures.single.requestId));
    // After revocation, pairing still succeeds — but audio streaming (the
    // part that needs processing authority) must NOT start, and the notice
    // explains why.
    final reconnected = await services.connectDevice('omi-1');
    expect(reconnected.id, 'omi-1');
    expect(services.deviceAudio.active, isFalse);
    expect(services.deviceAudioNotice.value, contains('Sign in'));
    services.dispose();
    await hub.close();
    await adapter.close();
  });

  test(
    'slow Firebase signout cannot delay native authority shutdown',
    () async {
      final gateway = _FakeAuthGateway(_session('user-a'))
        ..signOutBarrier = Completer<void>();
      final auth = AuthController(
        gateway,
        consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
      );
      await auth.restoreSession();
      final hub = _FakeHub();
      final adapter = _DeviceAdapter();
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.mobileOwner,
          adapter: adapter,
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      );
      await services.initialize();

      final revocation = auth.revokeProcessingConsent();
      expect(auth.snapshot.hasProcessingAuthority, isFalse);
      await _waitFor(() => hub.disposeCalls == 1);
      expect(gateway.didSignOut, isFalse);

      gateway.signOutBarrier!.complete();
      await revocation;
      expect(gateway.didSignOut, isTrue);
      services.dispose();
      await hub.close();
      await adapter.close();
    },
  );

  test('connect cannot outlive processing-consent revocation', () async {
    final gateway = _FakeAuthGateway(_session('user-a'));
    final auth = AuthController(
      gateway,
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final adapter = _DeviceAdapter()..connectBarrier = Completer<void>();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.mobileOwner,
        adapter: adapter,
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    await services.initialize();

    final connection = services.connectDevice('omi-1');
    await _waitFor(() => adapter.connectCalls == 1);
    final revocation = auth.revokeProcessingConsent();
    adapter.connectBarrier!.complete();

    await expectLater(connection, throwsA(isA<StateError>()));
    await revocation;
    expect(adapter.disconnectCalls, greaterThanOrEqualTo(1));
    expect(services.deviceAudio.active, isFalse);
    services.dispose();
    await hub.close();
    await adapter.close();
  });

  test(
    'disconnect queued during connect cannot leave device audio active',
    () async {
      final auth = AuthController(
        _FakeAuthGateway(_session('user-a')),
        consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
      );
      await auth.restoreSession();
      final hub = _FakeHub();
      final adapter = _DeviceAdapter()..connectBarrier = Completer<void>();
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.mobileOwner,
          adapter: adapter,
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
        managedStt: _FakeManagedStt(
          ManagedSttSession(
            websocketUrl:
                'wss://api.example.test/v1/stt/sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/stream',
            session: _session('user-a'),
          ),
        ),
      );
      await services.initialize();
      final disconnectsBeforeConnect = adapter.disconnectCalls;

      final connection = services.connectDevice('omi-1');
      await _waitFor(() => adapter.connectCalls == 1);
      final disconnection = services.disconnectDevice();
      adapter.connectBarrier!.complete();
      await connection;
      await disconnection;

      expect(adapter.disconnectCalls, disconnectsBeforeConnect + 1);
      expect(services.deviceAudio.active, isFalse);
      services.dispose();
      await hub.close();
      await adapter.close();
    },
  );

  test(
    'managed device connection mints typed STT auth and revocation aborts audio',
    () async {
      final gateway = _FakeAuthGateway(_session('user-a'));
      final auth = AuthController(
        gateway,
        consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
      );
      await auth.restoreSession();
      final hub = _FakeHub();
      final adapter = _DeviceAdapter(audioCodec: DeviceAudioCodec.pcm8);
      final managedStt = _FakeManagedStt(
        ManagedSttSession(
          websocketUrl:
              'wss://api.example.test/v1/stt/sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/stream',
          session: _session('user-a'),
        ),
      );
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.mobileOwner,
          adapter: adapter,
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
        managedStt: managedStt,
      );
      await services.initialize();

      await services.connectDevice('omi-managed');

      expect(managedStt.requests, hasLength(1));
      expect(managedStt.requests.single.language, 'multi');
      expect(managedStt.requests.single.encoding, ManagedSttEncoding.linear16);
      expect(managedStt.requests.single.sampleRate, 8000);
      expect(managedStt.requests.single.deviceId, hasLength(64));
      expect(hub.transcriptionAuth.single, isA<TranscriptionAuthManaged>());
      expect(hub.transcriptionEncoding.single, AudioEncoding.pcmU8);
      final nativeAuth =
          hub.transcriptionAuth.single as TranscriptionAuthManaged;
      expect(nativeAuth.firebaseToken, 'token-user-a');
      expect(nativeAuth.endpoint, managedStt.result.websocketUrl);
      expect(services.deviceAudio.active, isTrue);

      final revocation = auth.revokeProcessingConsent();
      await _waitFor(() => hub.stoppedAudioStreams == 1);
      await revocation;
      await _waitFor(() => !services.deviceAudio.active);

      services.dispose();
      await hub.close();
      await adapter.close();
    },
  );

  test(
    'managed Opus works and explicit local transcription fails before audio starts',
    () async {
      final auth = AuthController(
        _FakeAuthGateway(_session('user-a')),
        consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
      );
      await auth.restoreSession();
      final hub = _FakeHub();
      final adapter = _DeviceAdapter(audioCodec: DeviceAudioCodec.opusFs320);
      final managedStt = _FakeManagedStt(
        ManagedSttSession(
          websocketUrl:
              'wss://api.example.test/v1/stt/sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/stream',
          session: _session('user-a'),
        ),
      );
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.mobileOwner,
          adapter: adapter,
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
        managedStt: managedStt,
      );
      await services.initialize();

      await services.connectDevice('omi-managed-opus');
      expect(managedStt.requests.single.encoding, ManagedSttEncoding.opus);
      expect(managedStt.requests.single.sampleRate, 16000);
      await services.disconnectDevice();

      await expectLater(
        services.connectDevice(
          'omi-local',
          transcriptionAuth: const TranscriptionAuthLocal(),
        ),
        throwsA(isA<LocalTranscriptionUnavailable>()),
      );
      expect(hub.transcriptionAuth, hasLength(1));

      services.dispose();
      await hub.close();
      await adapter.close();
    },
  );

  test('desktop voice drains PCM and cancel stops before EOS', () async {
    final hub = _FakeHub()..terminalTranscript = '  plan the launch  ';
    var audio = StreamController<Uint8List>();
    var stopCalls = 0;
    final capture = DesktopVoiceCapture(
      hub: hub,
      startAudio: () async => audio.stream,
      stopAudio: () async {
        stopCalls += 1;
        await audio.close();
      },
    );

    await capture.start(
      auth: const TranscriptionAuthManaged(
        endpoint: 'wss://worker.example.test/stt',
        firebaseToken: 'token',
      ),
      authorityId: 'g1',
    );
    final firstStreamId = hub.transcriptionStartRequests.keys.single;
    hub.eventsController
      ..add(
        NativeEventTranscriptDelta(
          value: TranscriptDelta(
            requestId: hub.transcriptionStartRequests[firstStreamId]!,
            audioStreamId: firstStreamId,
            segmentId: '$firstStreamId:segment:1',
            segmentSequence: Uint64.fromBigInt(BigInt.one),
            sttEpoch: 0,
            deviceId: 'desktop-microphone',
            provider: 'managed',
            startMs: 1,
            endMs: 2,
            occurredAtMs: 2,
            text: 'second',
            finalSegment: true,
          ),
        ),
      )
      ..add(
        NativeEventTranscriptDelta(
          value: TranscriptDelta(
            requestId: hub.transcriptionStartRequests[firstStreamId]!,
            audioStreamId: firstStreamId,
            segmentId: '$firstStreamId:segment:0',
            segmentSequence: Uint64.fromBigInt(BigInt.zero),
            sttEpoch: 0,
            deviceId: 'desktop-microphone',
            provider: 'managed',
            startMs: 0,
            endMs: 1,
            occurredAtMs: 1,
            text: 'ignore interim',
            finalSegment: false,
          ),
        ),
      );
    audio.add(Uint8List.fromList([1, 2, 3, 4]));
    await Future<void>.delayed(Duration.zero);
    final transcript = await capture.stop();

    expect(transcript, 'plan the launch second');
    expect(hub.audio.map((chunk) => chunk.endOfStream), [false, true]);
    expect(hub.audio.first.encoding, AudioEncoding.pcmS16Le);
    expect(hub.audio.first.sampleRateHz, DesktopVoiceCapture.sampleRateHz);

    audio = StreamController<Uint8List>();
    await capture.start(
      auth: const TranscriptionAuthManaged(
        endpoint: 'wss://worker.example.test/stt',
        firebaseToken: 'token',
      ),
      authorityId: 'g1',
    );
    final eosBeforeCancel = hub.audio
        .where((chunk) => chunk.endOfStream)
        .length;
    await capture.cancel();

    expect(stopCalls, 2);
    expect(hub.stoppedAudioStreams, 1);
    expect(
      hub.audio.where((chunk) => chunk.endOfStream).length,
      eosBeforeCancel,
    );
    await capture.dispose();

    audio = StreamController<Uint8List>();
    final failedStop = DesktopVoiceCapture(
      hub: hub,
      startAudio: () async => audio.stream,
      stopAudio: () async => throw StateError('microphone failed'),
    );
    await failedStop.start(
      auth: const TranscriptionAuthManaged(
        endpoint: 'wss://worker.example.test/stt',
        firebaseToken: 'token',
      ),
      authorityId: 'g1',
    );
    await expectLater(failedStop.stop(), throwsStateError);
    expect(failedStop.active, isFalse);
    expect(hub.stoppedAudioStreams, 2);
    await failedStop.dispose();
    await audio.close();

    audio = StreamController<Uint8List>();
    final terminalCapture = DesktopVoiceCapture(
      hub: hub,
      startAudio: () async => audio.stream,
      stopAudio: () async {
        stopCalls += 1;
        await audio.close();
      },
    );
    await terminalCapture.start(
      auth: const TranscriptionAuthManaged(
        endpoint: 'wss://worker.example.test/stt',
        firebaseToken: 'token',
      ),
      authorityId: 'g1',
    );
    final terminalStreamId = hub.transcriptionStartRequests.keys.single;
    hub.eventsController.add(
      NativeEventError(
        value: NativeError(
          requestId: terminalStreamId,
          code: 'transcription_connection_lost',
          message: 'provider disconnected',
          retryable: false,
        ),
      ),
    );
    await _waitFor(() => !terminalCapture.active);
    expect(hub.stoppedAudioStreams, 3);
    await terminalCapture.dispose();

    audio = StreamController<Uint8List>();
    final cancelledCapture = DesktopVoiceCapture(
      hub: hub,
      startAudio: () async => audio.stream,
      stopAudio: audio.close,
    );
    await cancelledCapture.start(
      auth: const TranscriptionAuthManaged(
        endpoint: 'wss://worker.example.test/stt',
        firebaseToken: 'token',
      ),
      authorityId: 'g1',
    );
    final cancelledStreamId = hub.transcriptionStartRequests.keys.single;
    hub.eventsController.add(
      NativeEventTranscriptionStatus(
        value: TranscriptionStatus(
          requestId: hub.transcriptionStartRequests[cancelledStreamId]!,
          audioStreamId: cancelledStreamId,
          state: TranscriptionState.cancelled,
          sttEpoch: 0,
        ),
      ),
    );
    await _waitFor(() => !cancelledCapture.active);
    expect(hub.stoppedAudioStreams, 4);
    await cancelledCapture.dispose();
    await hub.close();
  });

  test('desktop voice permission and start-stop race stay fenced', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final auth = AuthController(
      _FakeAuthGateway(_session('user-a')),
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub()..terminalTranscript = 'voice request';
    final managedStt = _FakeManagedStt(_managedSession('user-a'));
    var permission = false;
    final audio = StreamController<Uint8List>();
    final voice = DesktopVoiceCapture(
      hub: hub,
      permissionCheck: () async => permission,
      startAudio: () async => audio.stream,
      stopAudio: audio.close,
    );
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      managedStt: managedStt,
      desktopVoice: voice,
    );
    await services.initialize();

    await expectLater(services.startDesktopVoice(), throwsStateError);
    expect(managedStt.requests, isEmpty);

    permission = true;
    managedStt.barrier = Completer<void>();
    final starting = services.startDesktopVoice();
    await _waitFor(() => managedStt.requests.length == 1);
    final stopping = services.stopDesktopVoice();
    managedStt.barrier!.complete();
    await starting;
    final submission = await stopping;

    expect(voice.active, isFalse);
    expect(submission?.text, 'voice request');
    expect(hub.messages.single.$2, 'voice request');
    expect(hub.captures, isEmpty);
    services.dispose();
    await hub.close();
  });

  test(
    'live voice start-stop drives the hub and discards output audio',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final auth = AuthController(
        _FakeAuthGateway(_session('user-a')),
        consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
      );
      await auth.restoreSession();
      final hub = _FakeHub();
      final tokens = _FakeLiveVoiceTokens();
      var permission = false;
      final audio = StreamController<Uint8List>();
      final voice = LiveVoiceCapture(
        hub: hub,
        permissionCheck: () async => permission,
        startAudio: () async => audio.stream,
        stopAudio: audio.close,
      );
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
        liveVoice: voice,
        liveVoiceTokens: tokens,
      );
      await services.initialize();

      await expectLater(services.startLiveVoice(), throwsStateError);
      expect(tokens.calls, 0);

      permission = true;
      await services.startLiveVoice();
      expect(voice.active, isTrue);
      expect(tokens.calls, 1);
      expect(hub.liveVoiceModels.single, 'gemini-live-test-model');
      expect(hub.liveVoiceTokens.single, 'auth_tokens/fake-live-token');
      final streamId = hub.liveVoiceStartRequests.keys.single;

      audio.add(Uint8List.fromList([1, 2, 3, 4]));
      await Future<void>.delayed(Duration.zero);
      expect(hub.audio.where((chunk) => chunk.requestId == streamId).length, 1);

      hub.eventsController.add(
        NativeEventLiveVoiceAudio(
          value: LiveVoiceAudio(
            liveStreamId: streamId,
            sequence: Uint64.fromBigInt(BigInt.zero),
            sampleRateHz: 24000,
            bytes: [9, 9, 9],
          ),
        ),
      );
      await _waitFor(() => voice.discardedOutputBytes == 3);

      await services.stopLiveVoice();
      expect(voice.active, isFalse);
      expect(
        hub.audio
            .where((chunk) => chunk.requestId == streamId && chunk.endOfStream)
            .length,
        1,
      );

      services.dispose();
      await hub.close();
    },
  );

  test('live voice fails closed without a worker token client', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final auth = AuthController(
      _FakeAuthGateway(_session('user-a')),
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final voice = LiveVoiceCapture(hub: hub, permissionCheck: () async => true);
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      liveVoice: voice,
    );
    await services.initialize();

    await expectLater(services.startLiveVoice(), throwsStateError);
    expect(hub.liveVoiceStartRequests, isEmpty);
    expect(voice.active, isFalse);

    services.dispose();
    await hub.close();
  });

  test(
    'live voice start races with authority changes and session end',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final auth = AuthController(
        _FakeAuthGateway(_session('user-a')),
        consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
      );
      await auth.restoreSession();
      final hub = _FakeHub();
      final tokens = _FakeLiveVoiceTokens();
      final audio = StreamController<Uint8List>();
      final voice = LiveVoiceCapture(
        hub: hub,
        permissionCheck: () async => true,
        startAudio: () async => audio.stream,
        stopAudio: audio.close,
      );
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
        liveVoice: voice,
        liveVoiceTokens: tokens,
      );
      await services.initialize();

      tokens.barrier = Completer<void>();
      final starting = services.startLiveVoice();
      await _waitFor(() => tokens.calls == 1);
      await services.cancelLiveVoice();
      tokens.barrier!.complete();
      await expectLater(starting, throwsStateError);
      expect(voice.active, isFalse);
      expect(hub.liveVoiceStartRequests, isEmpty);

      tokens.barrier = null;
      await services.startLiveVoice();
      final streamId = hub.liveVoiceStartRequests.keys.single;
      hub.eventsController.add(
        NativeEventLiveVoiceState(
          value: LiveVoiceState(
            liveStreamId: streamId,
            state: LiveVoicePhase.failed,
            detail: 'provider closed',
          ),
        ),
      );
      await _waitFor(() => !voice.active);
      expect(hub.stoppedLiveStreams, 1);

      services.dispose();
      await hub.close();
    },
  );

  test(
    'desktop voice prefers gemini live and submits accumulated finals',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final auth = AuthController(
        _FakeAuthGateway(_session('user-a')),
        consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
      );
      await auth.restoreSession();
      final hub = _FakeHub();
      final tokens = _FakeLiveVoiceTokens();
      final managedStt = _FakeManagedStt(_managedSession('user-a'));
      final audio = StreamController<Uint8List>();
      final liveVoice = LiveVoiceCapture(
        hub: hub,
        startAudio: () async => audio.stream,
        stopAudio: audio.close,
      );
      final desktopVoice = DesktopVoiceCapture(
        hub: hub,
        permissionCheck: () async => true,
      );
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
        managedStt: managedStt,
        desktopVoice: desktopVoice,
        liveVoice: liveVoice,
        liveVoiceTokens: tokens,
      );
      await services.initialize();

      await services.startDesktopVoice();
      expect(tokens.calls, 1);
      expect(managedStt.requests, isEmpty);
      expect(liveVoice.active, isTrue);
      expect(desktopVoice.active, isFalse);
      final streamId = hub.liveVoiceStartRequests.keys.single;

      await services.continueDesktopVoice();
      hub.eventsController
        ..add(
          NativeEventLiveVoiceTranscript(
            value: LiveVoiceTranscript(
              liveStreamId: streamId,
              text: 'plan the ',
              finalSegment: true,
              assistant: false,
            ),
          ),
        )
        ..add(
          NativeEventLiveVoiceTranscript(
            value: LiveVoiceTranscript(
              liveStreamId: streamId,
              text: 'interim noise',
              finalSegment: false,
              assistant: false,
            ),
          ),
        )
        ..add(
          NativeEventLiveVoiceTranscript(
            value: LiveVoiceTranscript(
              liveStreamId: streamId,
              text: 'launch',
              finalSegment: true,
              assistant: false,
            ),
          ),
        );
      await Future<void>.delayed(Duration.zero);

      final submission = await services.stopDesktopVoice();
      expect(submission?.text, 'plan the launch');
      expect(hub.messages.single.$2, 'plan the launch');
      expect(liveVoice.active, isFalse);
      expect(hub.transcriptionStartRequests, isEmpty);

      services.dispose();
      await hub.close();
    },
  );

  test(
    'desktop voice falls back to managed transcription when tokens fail',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final auth = AuthController(
        _FakeAuthGateway(_session('user-a')),
        consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
      );
      await auth.restoreSession();
      final hub = _FakeHub()..terminalTranscript = 'fallback request';
      final tokens = _FakeLiveVoiceTokens()
        ..failure = const WorkerResponseException(
          'Live voice is unavailable (503)',
        );
      final managedStt = _FakeManagedStt(_managedSession('user-a'));
      final audio = StreamController<Uint8List>();
      final desktopVoice = DesktopVoiceCapture(
        hub: hub,
        permissionCheck: () async => true,
        startAudio: () async => audio.stream,
        stopAudio: audio.close,
      );
      final liveVoice = LiveVoiceCapture(
        hub: hub,
        permissionCheck: () async => true,
      );
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
        managedStt: managedStt,
        desktopVoice: desktopVoice,
        liveVoice: liveVoice,
        liveVoiceTokens: tokens,
      );
      await services.initialize();

      await services.startDesktopVoice();
      expect(tokens.calls, 1);
      expect(hub.liveVoiceStartRequests, isEmpty);
      expect(managedStt.requests, hasLength(1));
      expect(desktopVoice.active, isTrue);
      expect(
        services.voiceNotice.value,
        'Live voice unavailable — using transcription only',
      );

      final submission = await services.stopDesktopVoice();
      expect(submission?.text, 'fallback request');
      expect(hub.messages.single.$2, 'fallback request');
      expect(desktopVoice.active, isFalse);

      services.dispose();
      await hub.close();
    },
  );

  test('a 403 from the token endpoint surfaces a Pro downgrade note while '
      'still falling back to managed transcription', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final auth = AuthController(
      _FakeAuthGateway(_session('user-a')),
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub()..terminalTranscript = 'fallback request';
    final tokens = _FakeLiveVoiceTokens()
      ..failure = const WorkerResponseException(
        'Managed Pro required',
        statusCode: 403,
      );
    final managedStt = _FakeManagedStt(_managedSession('user-a'));
    final audio = StreamController<Uint8List>();
    final desktopVoice = DesktopVoiceCapture(
      hub: hub,
      permissionCheck: () async => true,
      startAudio: () async => audio.stream,
      stopAudio: audio.close,
    );
    final liveVoice = LiveVoiceCapture(
      hub: hub,
      permissionCheck: () async => true,
    );
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      managedStt: managedStt,
      desktopVoice: desktopVoice,
      liveVoice: liveVoice,
      liveVoiceTokens: tokens,
    );
    await services.initialize();

    await services.startDesktopVoice();
    expect(hub.liveVoiceStartRequests, isEmpty);
    expect(desktopVoice.active, isTrue);
    expect(
      services.voiceNotice.value,
      'Live voice needs Pro — using transcription only',
    );

    await services.cancelDesktopVoice();
    services.dispose();
    await hub.close();
  });

  test('desktop voice falls back to managed transcription when the live '
      'session itself fails to start after a successful token mint', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final auth = AuthController(
      _FakeAuthGateway(_session('user-a')),
      consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
    );
    await auth.restoreSession();
    final hub = _FakeHub()
      ..terminalTranscript = 'fallback after live start failure'
      ..failLiveVoiceStart = true;
    final tokens = _FakeLiveVoiceTokens();
    final managedStt = _FakeManagedStt(_managedSession('user-a'));
    final audio = StreamController<Uint8List>();
    final desktopVoice = DesktopVoiceCapture(
      hub: hub,
      permissionCheck: () async => true,
      startAudio: () async => audio.stream,
      stopAudio: audio.close,
    );
    final liveVoice = LiveVoiceCapture(
      hub: hub,
      permissionCheck: () async => true,
    );
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      managedStt: managedStt,
      desktopVoice: desktopVoice,
      liveVoice: liveVoice,
      liveVoiceTokens: tokens,
    );
    await services.initialize();

    // The token mint succeeds (tokens.calls == 1), but liveVoice.start
    // itself throws. The call must not throw all the way out — it should
    // fall back to managed STT, the same as when the token mint fails.
    await services.startDesktopVoice();
    expect(tokens.calls, 1);
    expect(liveVoice.active, isFalse);
    expect(managedStt.requests, hasLength(1));
    expect(desktopVoice.active, isTrue);

    final submission = await services.stopDesktopVoice();
    expect(submission?.text, 'fallback after live start failure');
    expect(hub.messages.single.$2, 'fallback after live start failure');
    expect(desktopVoice.active, isFalse);

    services.dispose();
    await hub.close();
  });

  test(
    'desktop voice live route cancels when authority changes mid-start',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final auth = AuthController(
        _FakeAuthGateway(_session('user-a')),
        consentStore: VolatileConsentStore()..receipt = _receipt('user-a'),
      );
      await auth.restoreSession();
      final hub = _FakeHub();
      final tokens = _FakeLiveVoiceTokens();
      final audio = StreamController<Uint8List>();
      final liveVoice = LiveVoiceCapture(
        hub: hub,
        startAudio: () async => audio.stream,
        stopAudio: audio.close,
      );
      final desktopVoice = DesktopVoiceCapture(
        hub: hub,
        permissionCheck: () async => true,
      );
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
        desktopVoice: desktopVoice,
        liveVoice: liveVoice,
        liveVoiceTokens: tokens,
      );
      await services.initialize();

      tokens.barrier = Completer<void>();
      final starting = services.startDesktopVoice();
      await _waitFor(() => tokens.calls == 1);
      await services.cancelDesktopVoice();
      tokens.barrier!.complete();
      await expectLater(starting, throwsStateError);
      expect(liveVoice.active, isFalse);
      expect(desktopVoice.active, isFalse);
      expect(hub.liveVoiceStartRequests, isEmpty);
      expect(await services.stopDesktopVoice(), isNull);

      services.dispose();
      await hub.close();
    },
  );

  test('desktop voice signed out with a dev Gemini key routes through the '
      'direct live path instead of throwing signedOut', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    debugDevAssistantAccess = const DevAssistantAccess(
      credential: 'AIzaTestDevKey',
      liveModel: 'gemini-test-live',
      missingKeyHint: '',
    );
    addTearDown(() => debugDevAssistantAccess = DevAssistantAccess.none);
    final auth = AuthController(
      _FakeAuthGateway(null),
      consentStore: VolatileConsentStore(),
    );
    await auth.restoreSession();
    expect(auth.snapshot.phase, AuthPhase.signedOut);
    final hub = _FakeHub();
    final audio = StreamController<Uint8List>();
    final liveVoice = LiveVoiceCapture(
      hub: hub,
      startAudio: () async => audio.stream,
      stopAudio: audio.close,
    );
    final desktopVoice = DesktopVoiceCapture(
      hub: hub,
      permissionCheck: () async => true,
    );
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
      desktopVoice: desktopVoice,
      liveVoice: liveVoice,
    );
    await services.initialize();
    expect(services.localMode, isTrue);

    await services.startDesktopVoice();
    expect(liveVoice.active, isTrue);
    expect(desktopVoice.active, isFalse);
    expect(hub.liveVoiceStartRequests, isNotEmpty);

    final requestId = await services.sendChatMessage(text: 'hello');
    expect(requestId, isNotEmpty);

    await services.captureOnboardingProfile(name: 'Ada', languages: const []);
    expect(hub.captures, isNotEmpty);

    // Signed-out connect no longer throws an account StateError: pairing
    // proceeds without audio. This harness has no BLE adapter, so the call
    // reaches the relay itself and fails there instead — proving the account
    // gate no longer blocks pairing.
    await expectLater(
      services.connectDevice('device-1'),
      throwsA(isA<DeviceRelayUnavailable>()),
    );

    await services.cancelDesktopVoice();
    services.dispose();
    await hub.close();
  });

  test('local-mode chat history persists across a service relaunch with the '
      'same backing store', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    debugDevAssistantAccess = const DevAssistantAccess(
      credential: 'AIzaTestDevKey',
      liveModel: 'gemini-test-live',
      missingKeyHint: '',
    );
    addTearDown(() => debugDevAssistantAccess = DevAssistantAccess.none);
    final localConversations = VolatileLocalConversationStore();

    Future<AppServices> launch(NativeHub hub) async {
      final auth = AuthController(
        _FakeAuthGateway(null),
        consentStore: VolatileConsentStore(),
      );
      await auth.restoreSession();
      final services = AppServices.forTesting(
        auth: auth,
        nativeHub: hub,
        deviceRelay: DeviceRelayService(
          role: DeviceRelayRole.desktopObserver,
          adapter: const UnavailableDeviceRelayAdapter(),
        ),
        memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
        localConversations: localConversations,
      );
      await services.initialize();
      return services;
    }

    final firstHub = _FakeHub();
    final services = await launch(firstHub);
    expect(services.localMode, isTrue);

    final requestId = await services.sendChatMessage(text: 'remember me');
    await services.saveAssistantMessage(
      requestId: requestId,
      text: 'I will remember.',
    );
    services.dispose();
    await firstHub.close();

    final secondHub = _FakeHub();
    final relaunched = await launch(secondHub);
    expect(relaunched.localMode, isTrue);

    final replayed = await relaunched.replayConversation();
    expect(replayed, hasLength(2));
    expect(replayed.first.role, 'user');
    expect(replayed.first.text, 'remember me');
    expect(replayed.last.role, 'assistant');
    expect(replayed.last.text, 'I will remember.');

    relaunched.dispose();
    await secondHub.close();
  });

  test('desktop voice signed out without a dev Gemini key fails with an '
      'actionable message naming the key locations', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    // The hint text itself is the hub's (`dev_gemini.rs` composes it from the
    // candidate paths); what matters here is that the app relays it verbatim
    // instead of inventing its own.
    debugDevAssistantAccess = const DevAssistantAccess(
      liveModel: 'gemini-test-live',
      missingKeyHint:
          'No developer Gemini key found. Set GEMINI_API_KEY in one of: '
          '/home/dev/.config/omi/dev.env — then relaunch Omi.',
    );
    addTearDown(() => debugDevAssistantAccess = DevAssistantAccess.none);
    final auth = AuthController(
      _FakeAuthGateway(null),
      consentStore: VolatileConsentStore(),
    );
    await auth.restoreSession();
    final hub = _FakeHub();
    final services = AppServices.forTesting(
      auth: auth,
      nativeHub: hub,
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    await services.initialize();

    Object? failure;
    try {
      await services.startDesktopVoice();
    } catch (error) {
      failure = error;
    }
    expect(failure, isA<VoiceStartException>());
    final exception = failure as VoiceStartException;
    expect(exception.failure, VoiceStartFailure.signedOut);
    expect(exception.message, contains('GEMINI_API_KEY'));
    expect(exception.message, contains('dev.env'));
    expect(
      CursorPillController.voiceStartErrorMessage(exception),
      contains('GEMINI_API_KEY'),
    );

    services.dispose();
    await hub.close();
  });
}

final class _FakeConversationTransport implements ConversationTransport {
  final appended =
      <({String clientMessageId, String role, String source, String text})>[];
  final replayed = <ConversationMessage>[];
  final replayAfter = <int>[];
  Completer<List<ConversationMessage>>? replayBarrier;

  @override
  Future<ConversationMessage> append({
    required String clientMessageId,
    required String role,
    required String source,
    required String text,
  }) async {
    appended.add((
      clientMessageId: clientMessageId,
      role: role,
      source: source,
      text: text,
    ));
    return ConversationMessage(
      cursor: appended.length,
      clientMessageId: clientMessageId,
      role: role,
      source: source,
      text: text,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  Future<List<ConversationMessage>> replay({required int after}) async {
    replayAfter.add(after);
    final barrier = replayBarrier;
    if (barrier != null) return barrier.future;
    return replayed.where((message) => message.cursor > after).toList();
  }
}

final class _FakeConversationInboxTransport
    implements ConversationInboxTransport {
  final items = <ConversationInboxItem>[];
  final completed =
      <
        ({
          ConversationInboxItem item,
          ConversationInboxOutcome outcome,
          String? responseText,
          String? error,
        })
      >[];
  int claims = 0;
  int completionCalls = 0;
  int completionFailures = 0;

  @override
  Future<ConversationInboxItem?> claim() async {
    claims += 1;
    return items.isEmpty ? null : items.removeAt(0);
  }

  @override
  Future<void> complete(
    ConversationInboxItem item, {
    required ConversationInboxOutcome outcome,
    String? responseText,
    String? error,
  }) async {
    completionCalls += 1;
    if (completionFailures > 0) {
      completionFailures -= 1;
      throw StateError('completion unavailable');
    }
    completed.add((
      item: item,
      outcome: outcome,
      responseText: responseText,
      error: error,
    ));
  }
}

final class _FakeLiveVoiceTokens implements LiveVoiceTokenClient {
  int calls = 0;
  Completer<void>? barrier;
  Object? failure;

  @override
  Future<GeminiLiveToken> createGeminiToken() async {
    calls += 1;
    if (barrier != null) await barrier!.future;
    final failure = this.failure;
    if (failure != null) throw failure;
    return GeminiLiveToken(
      token: 'auth_tokens/fake-live-token',
      model: 'gemini-live-test-model',
      expireTime: DateTime.utc(2030),
      newSessionExpireTime: DateTime.utc(2030),
    );
  }
}

AuthSession _session(String uid) =>
    AuthSession(uid: uid, idToken: 'token-$uid', expiresAt: DateTime.utc(2030));

ManagedSttSession _managedSession(String uid) => ManagedSttSession(
  websocketUrl:
      'wss://worker.example.test/v1/stt/sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/stream',
  session: _session(uid),
);

ProcessingConsentReceipt _receipt(String uid) =>
    ProcessingConsentReceipt.current(
      subjectUid: uid,
      acceptedAt: DateTime.utc(2026, 7, 21),
    );

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt += 1) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue);
}

final class _FakeAuthGateway implements AuthGateway {
  _FakeAuthGateway(this._session);

  AuthSession? _session;
  final _changes = StreamController<AuthSession?>.broadcast();
  Completer<void>? signOutBarrier;
  bool didSignOut = false;
  final refreshResults = <AuthSession>[];

  void emit(AuthSession? session) {
    _session = session;
    _changes.add(session);
  }

  @override
  bool get isConfigured => true;

  @override
  AuthFailure? get configurationFailure => null;

  @override
  bool get supportsPhoneOtp => true;

  @override
  bool get supportsDesktopBrowserHandoff => false;

  @override
  AuthSession? get currentSession => _session;

  @override
  Stream<AuthSession?> get sessionChanges => _changes.stream;

  @override
  Future<AuthSession?> restoreSession() async => _session;

  @override
  Future<AuthSession?> refreshSession() async {
    if (refreshResults.isNotEmpty) _session = refreshResults.removeAt(0);
    return _session;
  }

  @override
  Future<void> signOut() async {
    await signOutBarrier?.future;
    didSignOut = true;
    emit(null);
  }

  @override
  Future<AuthSession> signIn(AuthProvider provider) async => _session!;

  @override
  Future<AuthSession> signInWithDesktopBrowser({
    required void Function(String code) onConfirmationCode,
  }) async => _session!;

  @override
  Future<PhoneOtpChallenge> requestPhoneOtp(String phoneNumber) async =>
      const PhoneOtpChallenge(verificationId: 'challenge');

  @override
  Future<AuthSession> confirmPhoneOtp({
    required PhoneOtpChallenge challenge,
    required String code,
  }) async => _session!;
}

final class _FakeHub implements NativeHub {
  @override
  void resolveDevAssistant(String requestId) {}
  final eventsController = StreamController<NativeEvent>.broadcast();
  final meetingAuth = <(TranscriptionAuth, String?)>[];
  final captureModes = <SystemAudioCaptureMode>[];
  int initializeCalls = 0;
  int disposeCalls = 0;
  final databasePaths = <String>[];
  final personIds = <String>[];
  final captures = <_Capture>[];
  final cancelled = <String>[];
  final messages = <(String, String)>[];
  final memoryContexts = <String?>[];
  final approvals = <(String, ApprovalDecision)>[];
  final approvalReceipts = <ComputerUseAuthorityReceipt?>[];
  final approvalRequests = <(String, String)>[];
  final executableProposals = <String>{};
  final executedProposals = <String>[];
  final assistantConfigurations =
      <(AssistantProvider, String, String?, String)>[];
  final trustedAssistantOrigins = <String>[];
  final assistantClears = <String>[];
  final transcriptionAuth = <TranscriptionAuth>[];
  final transcriptionEncoding = <AudioEncoding>[];
  final transcriptionStartRequests = <String, String>{};
  final scanRequests =
      <
        ({
          String requestId,
          List<String> roots,
          bool includeAppleNotes,
          bool includeAppleMail,
          int recordedAtMs,
        })
      >[];
  int stoppedAudioStreams = 0;
  int stoppedLiveStreams = 0;
  final liveVoiceStartRequests = <String, String>{};
  final liveVoiceModels = <String>[];
  final liveVoiceTokens = <String>[];
  String? terminalTranscript;
  final audio =
      <
        ({
          String requestId,
          int sequence,
          int sampleRateHz,
          AudioEncoding encoding,
          bool endOfStream,
        })
      >[];
  bool failCancel = false;
  bool failLiveVoiceStart = false;
  bool failAtomicApproval = false;
  bool rejectAtomicApproval = false;
  bool rejectAtomicApprovalWithoutFollowup = false;
  bool dropAtomicApproval = false;

  @override
  bool get available => true;

  @override
  Stream<NativeEvent> get events => eventsController.stream;

  @override
  Future<void> initialize() async => initializeCalls += 1;

  @override
  void provideMeetingAuth({
    required String requestId,
    required TranscriptionAuth auth,
    String? trustedWorkerOrigin,
  }) {
    meetingAuth.add((auth, trustedWorkerOrigin));
  }

  @override
  void composeBrief({
    required String requestId,
    required String nowLocal,
    required List<BriefItem> items,
  }) {}

  @override
  void joinCall({
    required String requestId,
    required String link,
    required String ephemeralToken,
    required String model,
    String? displayName,
    bool video = true,
  }) {}

  @override
  void setSystemAudioCaptureMode({
    required String requestId,
    required SystemAudioCaptureMode mode,
  }) {
    captureModes.add(mode);
  }

  @override
  void configureMemory({
    required String requestId,
    required String databasePath,
    required String tenantId,
    required String personId,
  }) {
    databasePaths.add(databasePath);
    personIds.add(personId);
  }

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
  void scanOnboarding({
    required String requestId,
    required List<String> roots,
    required bool includeAppleNotes,
    required bool includeAppleMail,
    required int recordedAtMs,
  }) {
    scanRequests.add((
      requestId: requestId,
      roots: roots,
      includeAppleNotes: includeAppleNotes,
      includeAppleMail: includeAppleMail,
      recordedAtMs: recordedAtMs,
    ));
  }

  @override
  void dispose() => disposeCalls += 1;

  Future<void> close() => eventsController.close();

  @override
  void cancel(String requestId) {
    cancelled.add(requestId);
    if (failCancel) throw StateError('cancel failed');
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
  }) {
    captures.add(
      _Capture(
        requestId: requestId,
        ingestionKey: ingestionKey,
        source: source,
        occurredAtMs: occurredAtMs,
        recordedAtMs: recordedAtMs,
        text: text,
        transcriptLocator: transcriptLocator,
      ),
    );
  }

  @override
  void search({
    required String requestId,
    required String query,
    int limit = 12,
    int? asOfValidAtMs,
    int? asOfRecordedAtMs,
  }) {}

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
    String? memoryContext,
    MessageOrigin? origin,
  }) {
    messages.add((requestId, text));
    memoryContexts.add(memoryContext);
  }

  @override
  void decideApproval({
    required String requestId,
    required String proposalId,
    required ApprovalDecision decision,
    ComputerUseAuthorityReceipt? authorityReceipt,
  }) {
    if (failAtomicApproval) throw StateError('command queue unavailable');
    approvals.add((proposalId, decision));
    approvalReceipts.add(authorityReceipt);
    if (dropAtomicApproval) return;
    if (rejectAtomicApprovalWithoutFollowup) {
      eventsController.add(
        NativeEventApprovalDecisionAcknowledged(
          value: ApprovalDecisionAcknowledgement(
            requestId: requestId,
            proposalId: proposalId,
            decision: decision,
            accepted: false,
            executionPending: false,
          ),
        ),
      );
      return;
    }
    if (rejectAtomicApproval) {
      eventsController
        ..add(
          NativeEventApprovalDecisionAcknowledged(
            value: ApprovalDecisionAcknowledgement(
              requestId: requestId,
              proposalId: proposalId,
              decision: decision,
              accepted: false,
              executionPending: false,
            ),
          ),
        )
        ..add(
          NativeEventError(
            value: NativeError(
              requestId: requestId,
              code: 'computer_use_unavailable',
              message: 'permissions unavailable',
              retryable: true,
            ),
          ),
        );
      return;
    }
    final executionPending =
        decision == ApprovalDecision.approveOnce &&
        executableProposals.contains(proposalId);
    approvalRequests.add((requestId, proposalId));
    if (executionPending) executedProposals.add(proposalId);
    eventsController.add(
      NativeEventApprovalDecisionAcknowledged(
        value: ApprovalDecisionAcknowledgement(
          requestId: requestId,
          proposalId: proposalId,
          decision: decision,
          accepted: true,
          executionPending: executionPending,
        ),
      ),
    );
  }

  @override
  void configureAssistant({
    required String requestId,
    required AssistantProvider provider,
    required String model,
    required String credential,
    String? endpoint,
  }) {
    assistantConfigurations.add((provider, model, endpoint, credential));
  }

  @override
  void configureTrustedAssistant({
    required String requestId,
    required String managedWorkerOrigin,
  }) {
    trustedAssistantOrigins.add(managedWorkerOrigin);
  }

  @override
  void clearAssistant(String requestId) {
    assistantClears.add(requestId);
  }

  @override
  void sendAudio({
    required String requestId,
    required int sequence,
    required int sampleRateHz,
    required int channels,
    required AudioEncoding encoding,
    required bool endOfStream,
    required Uint8List bytes,
  }) {
    audio.add((
      requestId: requestId,
      sequence: sequence,
      sampleRateHz: sampleRateHz,
      encoding: encoding,
      endOfStream: endOfStream,
    ));
    if (endOfStream && liveVoiceStartRequests.containsKey(requestId)) {
      liveVoiceStartRequests.remove(requestId);
      eventsController.add(
        NativeEventLiveVoiceState(
          value: LiveVoiceState(
            liveStreamId: requestId,
            state: LiveVoicePhase.ended,
          ),
        ),
      );
      return;
    }
    final text = terminalTranscript;
    if (!endOfStream || text == null) return;
    final startRequestId = transcriptionStartRequests.remove(requestId)!;
    eventsController
      ..add(
        NativeEventTranscriptDelta(
          value: TranscriptDelta(
            requestId: startRequestId,
            audioStreamId: requestId,
            segmentId: '$requestId:segment:0',
            segmentSequence: Uint64.fromBigInt(BigInt.zero),
            sttEpoch: 0,
            deviceId: 'desktop-microphone',
            provider: 'managed',
            startMs: 0,
            endMs: 1,
            occurredAtMs: 1,
            text: text,
            finalSegment: true,
          ),
        ),
      )
      ..add(
        NativeEventTranscriptionStatus(
          value: TranscriptionStatus(
            requestId: startRequestId,
            audioStreamId: requestId,
            state: TranscriptionState.finished,
            sttEpoch: 0,
          ),
        ),
      );
  }

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
  }) {
    transcriptionAuth.add(auth);
    transcriptionEncoding.add(encoding);
    transcriptionStartRequests[audioStreamId] = requestId;
    eventsController.add(
      NativeEventTranscriptionStatus(
        value: TranscriptionStatus(
          requestId: requestId,
          audioStreamId: audioStreamId,
          state: TranscriptionState.started,
          sttEpoch: 0,
        ),
      ),
    );
  }

  @override
  void startLiveVoice({
    required String requestId,
    required String liveStreamId,
    required String ephemeralToken,
    required String model,
    String? resumptionHandle,
  }) {
    liveVoiceModels.add(model);
    liveVoiceTokens.add(ephemeralToken);
    if (failLiveVoiceStart) {
      // Simulate the ephemeral token minting fine but the live session
      // itself failing to start (network blip, model rejection): no
      // "started" state ever arrives, only a failure.
      eventsController.add(
        NativeEventLiveVoiceState(
          value: LiveVoiceState(
            liveStreamId: liveStreamId,
            state: LiveVoicePhase.failed,
            detail: 'live session rejected',
          ),
        ),
      );
      return;
    }
    liveVoiceStartRequests[liveStreamId] = requestId;
    eventsController.add(
      NativeEventLiveVoiceState(
        value: LiveVoiceState(
          liveStreamId: liveStreamId,
          state: LiveVoicePhase.started,
        ),
      ),
    );
  }

  @override
  void stopLiveVoice({
    required String requestId,
    required String liveStreamId,
  }) {
    stoppedLiveStreams += 1;
    if (liveVoiceStartRequests.remove(liveStreamId) != null) {
      eventsController.add(
        NativeEventLiveVoiceState(
          value: LiveVoiceState(
            liveStreamId: liveStreamId,
            state: LiveVoicePhase.ended,
          ),
        ),
      );
    }
  }

  @override
  void stopTranscription({
    required String requestId,
    required String audioStreamId,
  }) {
    stoppedAudioStreams += 1;
    eventsController.add(
      NativeEventTranscriptionStopAcknowledged(
        value: TranscriptionStopAcknowledgement(
          requestId: requestId,
          audioStreamId: audioStreamId,
          accepted: true,
        ),
      ),
    );
    final startRequestId = transcriptionStartRequests.remove(audioStreamId);
    if (startRequestId != null) {
      eventsController.add(
        NativeEventTranscriptionStatus(
          value: TranscriptionStatus(
            requestId: startRequestId,
            audioStreamId: audioStreamId,
            state: TranscriptionState.cancelled,
            sttEpoch: 0,
          ),
        ),
      );
    }
  }

  @override
  void startMeeting({required String requestId, String? title}) {}

  @override
  void stopMeeting(String requestId) {}

  @override
  void jotMeetingNote({required String requestId, required String text}) {}
}

final class _Capture {
  const _Capture({
    required this.requestId,
    required this.ingestionKey,
    required this.source,
    required this.occurredAtMs,
    required this.recordedAtMs,
    required this.text,
    required this.transcriptLocator,
  });

  final String requestId;
  final String ingestionKey;
  final CaptureSource source;
  final int occurredAtMs;
  final int recordedAtMs;
  final String? text;
  final TranscriptLocator? transcriptLocator;
}

final class _CurrentApprovalTransport implements CurrentsTransport {
  _CurrentApprovalTransport(this.hub);

  final _FakeHub hub;
  final outcomes = <Map<String, Object?>>[];
  bool approvalObservedBeforeNative = false;

  @override
  Future<CurrentsResponse> send(CurrentsRequest request) async {
    if (request.path.endsWith('/approve')) {
      approvalObservedBeforeNative = hub.approvals.isEmpty;
      final body = request.body!;
      final issuedAtMs = DateTime.now().millisecondsSinceEpoch;
      return CurrentsResponse(
        statusCode: 200,
        body: {
          'receipt': {
            'version': 'omi-current-authority-v1',
            'receiptId': 'receipt-1',
            'receiptToken': '0123456789012345678901234567890123456789012',
            'subject': 'user-a',
            'policyGeneration': body['generation'],
            'operationId': body['operationId'],
            'proposalId': body['proposalId'],
            'actionHash': body['actionHash'],
            'risk': body['risk'],
            'issuedAtMs': issuedAtMs,
            'expiresAtMs': issuedAtMs + 60000,
          },
        },
      );
    }
    if (request.path.endsWith('/outcome')) {
      outcomes.add(request.body!);
      return const CurrentsResponse(statusCode: 200, body: {'ok': true});
    }
    if (request.path.endsWith('/reject')) {
      return const CurrentsResponse(statusCode: 200, body: {'ok': true});
    }
    return const CurrentsResponse(
      statusCode: 200,
      body: {'currents': <Object?>[]},
    );
  }
}

final class _DeviceAdapter implements DeviceRelayAdapter {
  _DeviceAdapter({this.audioCodec = DeviceAudioCodec.opus});

  final DeviceAudioCodec audioCodec;
  final audio = StreamController<List<int>>.broadcast();
  final connections = StreamController<bool>.broadcast();
  int disconnectCalls = 0;
  int connectCalls = 0;
  Completer<void>? connectBarrier;

  Future<void> close() async {
    await audio.close();
    await connections.close();
  }

  @override
  DeviceRelayCapabilities get capabilities => const DeviceRelayCapabilities(
    pairing: DeviceCapabilityState.available,
    metadata: DeviceCapabilityState.available,
    audioStreaming: DeviceCapabilityState.available,
  );

  @override
  Stream<DeviceRelaySnapshot> get snapshots => const Stream.empty();

  @override
  Future<List<RelayDevice>> scan() async => const [];

  @override
  Future<RelayDevice> connect(String deviceId) async {
    connectCalls += 1;
    await connectBarrier?.future;
    return RelayDevice(id: deviceId, name: 'Omi', audioCodec: audioCodec);
  }

  @override
  Future<void> disconnect() async => disconnectCalls += 1;

  @override
  Stream<List<int>> audioPackets(String deviceId) => audio.stream;

  @override
  Stream<bool> connectionState(String deviceId) => connections.stream;
}

typedef _ManagedSttRequest = ({
  String idempotencyKey,
  String deviceId,
  String language,
  ManagedSttEncoding encoding,
  int sampleRate,
  int channels,
});

final class _FakeManagedStt implements ManagedSttClient {
  _FakeManagedStt(this.result, {Uri? trustedWorkerOrigin})
    : trustedWorkerOrigin =
          trustedWorkerOrigin ?? Uri.parse('https://api.example.test/');

  final ManagedSttSession result;
  @override
  final Uri trustedWorkerOrigin;
  final requests = <_ManagedSttRequest>[];
  Completer<void>? barrier;

  @override
  Future<ManagedSttSession> createSession({
    required String idempotencyKey,
    required String deviceId,
    required String language,
    required ManagedSttEncoding encoding,
    required int sampleRate,
    required int channels,
  }) async {
    requests.add((
      idempotencyKey: idempotencyKey,
      deviceId: deviceId,
      language: language,
      encoding: encoding,
      sampleRate: sampleRate,
      channels: channels,
    ));
    await barrier?.future;
    return result;
  }
}
