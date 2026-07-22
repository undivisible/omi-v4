import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'api/worker_http.dart';
import 'auth/auth.dart';
import 'auth/firebase_bootstrap.dart';
import 'capabilities/desktop_capabilities.dart';
import 'channels/channels.dart';
import 'conversations/conversations.dart';
import 'currents/currents.dart';
import 'device/device.dart';
import 'keyboard/keyboard.dart';
import 'memory/memory.dart';
import 'memory/transcript_memory_ingestor.dart';
import 'native/native_hub.dart';
import 'providers/providers.dart';
import 'settings/settings.dart';

export 'memory/transcript_memory_ingestor.dart' show TranscriptCaptureConflict;

const _managedAssistantModel = 'mimo-v2.5-pro';
const _defaultAssistantRefreshLead = Duration(minutes: 5);
const _defaultAssistantMinimumRefreshDelay = Duration(seconds: 30);
const _defaultInboxPollInterval = Duration(seconds: 2);

String _randomId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

final class LocalTranscriptionUnavailable implements Exception {
  const LocalTranscriptionUnavailable();

  @override
  String toString() =>
      'LocalTranscriptionUnavailable: Local transcription is not available yet.';
}

final class AppServices {
  static const localTranscriptionAvailable = false;
  AppServices._({
    required this.auth,
    required this.nativeHub,
    required this.deviceRelay,
    required this.memoryDatabasePath,
    required this.workspaceRoots,
    required this.providerCredentials,
    required this.configurationMessage,
    this.memory,
    this.settings,
    this.channels,
    this.billing,
    this.conversations,
    ConversationInboxTransport? conversationInbox,
    CurrentsClient? currentsClient,
    this._worker,
    this.memorySyncPump,
    this._managedStt,
    this._workerOrigin,
    DateTime Function()? now,
    this._assistantRefreshLead = _defaultAssistantRefreshLead,
    this._assistantMinimumRefreshDelay = _defaultAssistantMinimumRefreshDelay,
    Duration inboxPollInterval = _defaultInboxPollInterval,
    DesktopVoiceCapture? desktopVoice,
  }) : currents = currentsClient == null
           ? null
           : CurrentsController(currentsClient),
       deviceAudio = DeviceAudioForwarder(relay: deviceRelay, hub: nativeHub),
       capabilities = PlatformDesktopCapabilityGateway(
         workspaceRoots: workspaceRoots,
       ),
       _now = now ?? DateTime.now {
    this.desktopVoice = desktopVoice ?? DesktopVoiceCapture(hub: nativeHub);
    _transcriptMemoryIngestor = TranscriptMemoryIngestor(
      nativeHub,
      _now,
      _nativeEvents.addError,
    );
    _conversationController = ConversationController(
      nativeHub: nativeHub,
      transport: conversations,
      inbox: conversationInbox,
      currents: currentsClient,
      source: _conversationSource,
      now: _now,
      isReady: () => chatReady,
      isDisposed: () => _disposed,
      currentUid: () => auth.snapshot.session?.uid,
      currentIdToken: () async => (await auth.validSession())?.idToken,
      canPollInbox:
          conversationInbox != null &&
          !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.macOS ||
              defaultTargetPlatform == TargetPlatform.windows),
      addError: (error, stackTrace) =>
          _nativeEvents.addError(error, stackTrace),
      inboxPollInterval: inboxPollInterval,
    );
  }

  factory AppServices.fromEnvironment() {
    final auth = AuthController(const UnconfiguredAuthGateway());
    final nativeHub = createNativeHub();
    final deviceRelay = _createDeviceRelay();
    const origin = String.fromEnvironment('OMI_API_ORIGIN');
    if (origin.isEmpty) {
      return AppServices._(
        auth: auth,
        nativeHub: nativeHub,
        deviceRelay: deviceRelay,
        memoryDatabasePath: _defaultMemoryDatabasePath,
        workspaceRoots: PreferencesWorkspaceRootStore(),
        providerCredentials: const SecureProviderCredentialStore(),
        configurationMessage:
            'Set OMI_API_ORIGIN and configure Firebase to connect.',
      );
    }
    final worker = WorkerHttpClient(
      baseUri: Uri.parse(origin),
      sessionProvider: auth.validSession,
    );
    return AppServices._(
      auth: auth,
      nativeHub: nativeHub,
      deviceRelay: deviceRelay,
      memoryDatabasePath: _defaultMemoryDatabasePath,
      workspaceRoots: PreferencesWorkspaceRootStore(),
      providerCredentials: const SecureProviderCredentialStore(),
      configurationMessage: 'Configure Firebase to sign in and connect.',
      memory: MemoryClient(WorkerMemoryTransport(worker)),
      settings: SettingsClient(WorkerSettingsTransport(worker)),
      channels: ChannelClient(WorkerChannelTransport(worker)),
      billing: WorkerBillingClient(worker),
      conversations: WorkerConversationTransport(worker),
      conversationInbox: WorkerConversationTransport(worker),
      currentsClient: CurrentsClient(WorkerCurrentsTransport(worker)),
      worker: worker,
      memorySyncPump: MemorySyncPump(
        hub: nativeHub,
        events: nativeHub.events,
        transport: WorkerMemorySyncTransport(worker),
        cursorStore: PreferencesMemorySyncCursorStore(),
      ),
      managedStt: WorkerManagedSttClient(worker),
      workerOrigin: worker.trustedOrigin,
    );
  }

  static Future<AppServices> initializeFromEnvironment() async {
    final gateway = await initializeFirebaseAuth();
    final auth = AuthController(
      gateway,
      consentStore: PreferencesConsentStore(),
    );
    await auth.restoreSession();
    final nativeHub = createNativeHub();
    final deviceRelay = _createDeviceRelay();
    const origin = String.fromEnvironment('OMI_API_ORIGIN');
    if (origin.isEmpty) {
      return AppServices._(
        auth: auth,
        nativeHub: nativeHub,
        deviceRelay: deviceRelay,
        memoryDatabasePath: _defaultMemoryDatabasePath,
        workspaceRoots: PreferencesWorkspaceRootStore(),
        providerCredentials: const SecureProviderCredentialStore(),
        configurationMessage: 'Set OMI_API_ORIGIN to connect.',
      );
    }
    final worker = WorkerHttpClient(
      baseUri: Uri.parse(origin),
      sessionProvider: auth.validSession,
    );
    return AppServices._(
      auth: auth,
      nativeHub: nativeHub,
      deviceRelay: deviceRelay,
      memoryDatabasePath: _defaultMemoryDatabasePath,
      workspaceRoots: PreferencesWorkspaceRootStore(),
      providerCredentials: const SecureProviderCredentialStore(),
      configurationMessage: gateway.isConfigured
          ? 'Sign in to connect.'
          : 'Configure Firebase to sign in and connect.',
      memory: MemoryClient(WorkerMemoryTransport(worker)),
      settings: SettingsClient(WorkerSettingsTransport(worker)),
      channels: ChannelClient(WorkerChannelTransport(worker)),
      billing: WorkerBillingClient(worker),
      conversations: WorkerConversationTransport(worker),
      conversationInbox: WorkerConversationTransport(worker),
      currentsClient: CurrentsClient(WorkerCurrentsTransport(worker)),
      worker: worker,
      memorySyncPump: MemorySyncPump(
        hub: nativeHub,
        events: nativeHub.events,
        transport: WorkerMemorySyncTransport(worker),
        cursorStore: PreferencesMemorySyncCursorStore(),
      ),
      managedStt: WorkerManagedSttClient(worker),
      workerOrigin: worker.trustedOrigin,
    );
  }

  factory AppServices.forTesting({
    required NativeHub nativeHub,
    required DeviceRelayService deviceRelay,
    required AuthController auth,
    required String Function(String uid) memoryDatabasePath,
    WorkspaceRootStore? workspaceRoots,
    ProviderCredentialStore? providerCredentials,
    ManagedSttClient? managedStt,
    ConversationTransport? conversations,
    ConversationInboxTransport? conversationInbox,
    CurrentsClient? currentsClient,
    DateTime Function()? now,
    Duration assistantRefreshLead = _defaultAssistantRefreshLead,
    Duration assistantMinimumRefreshDelay =
        _defaultAssistantMinimumRefreshDelay,
    Duration inboxPollInterval = _defaultInboxPollInterval,
    DesktopVoiceCapture? desktopVoice,
    MemorySyncPump? memorySync,
  }) => AppServices._(
    auth: auth,
    nativeHub: nativeHub,
    deviceRelay: deviceRelay,
    memoryDatabasePath: (uid) async => memoryDatabasePath(uid),
    workspaceRoots: workspaceRoots ?? VolatileWorkspaceRootStore(),
    providerCredentials:
        providerCredentials ?? VolatileProviderCredentialStore(),
    configurationMessage: 'Test services are not connected.',
    managedStt: managedStt,
    conversations: conversations,
    conversationInbox: conversationInbox,
    currentsClient: currentsClient,
    workerOrigin: managedStt == null
        ? null
        : _validateWorkerOrigin(managedStt.trustedWorkerOrigin),
    now: now,
    assistantRefreshLead: assistantRefreshLead,
    assistantMinimumRefreshDelay: assistantMinimumRefreshDelay,
    inboxPollInterval: inboxPollInterval,
    desktopVoice: desktopVoice,
    memorySyncPump: memorySync,
  );

  final AuthController auth;
  final NativeHub nativeHub;
  final DeviceRelayService deviceRelay;
  final DeviceAudioForwarder deviceAudio;
  late final DesktopVoiceCapture desktopVoice;
  final WorkspaceRootStore workspaceRoots;
  final ProviderCredentialStore providerCredentials;
  final PlatformDesktopCapabilityGateway capabilities;
  final String configurationMessage;
  final MemoryClient? memory;
  final SettingsClient? settings;
  final ChannelClient? channels;
  final WorkerBillingClient? billing;
  final ConversationTransport? conversations;
  final CurrentsController? currents;
  final WorkerHttpClient? _worker;
  final MemorySyncPump? memorySyncPump;
  final ManagedSttClient? _managedStt;
  final Uri? _workerOrigin;
  final DateTime Function() _now;
  final Duration _assistantRefreshLead;
  final Duration _assistantMinimumRefreshDelay;
  final Future<String> Function(String uid) memoryDatabasePath;
  final _nativeEvents = StreamController<NativeEvent>.broadcast();
  StreamSubscription<NativeEvent>? _nativeEventSubscription;
  String? _configuredPersonId;
  late final TranscriptMemoryIngestor _transcriptMemoryIngestor;
  late final ConversationController _conversationController;
  int _assistantTransportSequence = 0;
  bool _nativeInitialized = false;
  bool _assistantConfigured = false;
  Timer? _assistantRefreshTimer;
  bool _disposed = false;
  Future<void> _lifecycle = Future.value();
  Future<void> _desktopVoiceLifecycle = Future.value();
  int _desktopVoiceGeneration = 0;

  Stream<NativeEvent> get nativeEvents => _nativeEvents.stream;
  Stream<int> get chatAuthorityChanges =>
      _conversationController.authorityChanges;

  int get _authorityGeneration => _conversationController.authorityGeneration;

  Future<String?> get selectedWorkspaceRoot =>
      capabilities.verifiedWorkspaceRoot();

  Future<String> scanOnboardingSources() async {
    await _queueProductionSync();
    if (nativeHub is! OnboardingScanHub) {
      throw StateError('Native scanning is not connected.');
    }
    if (!await _ensureNativeInitialized()) {
      throw const NativeHubUnavailable(
        'Private scanning is unavailable on this platform.',
      );
    }
    final root = await selectedWorkspaceRoot;
    final requestId = 'onboarding-scan-${_randomId()}';
    (nativeHub as OnboardingScanHub).scanOnboarding(
      requestId: requestId,
      roots: [?root],
      includeAppleNotes: defaultTargetPlatform == TargetPlatform.macOS,
      includeAppleMail: defaultTargetPlatform == TargetPlatform.macOS,
      recordedAtMs: _now().millisecondsSinceEpoch,
    );
    return requestId;
  }

  bool get canUseApi => _worker != null && auth.snapshot.hasProcessingAuthority;

  Future<void> initialize() async {
    auth.addListener(_authChanged);
    await capabilities.verifiedWorkspaceRoot();
    await _queueProductionSync();
  }

  bool get productionReady {
    final snapshot = auth.snapshot;
    return snapshot.phase == AuthPhase.signedIn &&
        snapshot.hasProcessingAuthority;
  }

  bool get chatReady => productionReady && _nativeInitialized;

  Future<ProviderCredential?> get providerCredential async {
    final uid = auth.snapshot.session?.uid;
    return uid == null ? null : providerCredentials.read(uid);
  }

  Future<void> saveProviderCredential(ProviderCredential value) async {
    final uid = auth.snapshot.session?.uid;
    if (!productionReady || uid == null) {
      throw StateError('Sign in before configuring a provider.');
    }
    await providerCredentials.write(uid, value);
    await _queueProductionSync();
  }

  Future<void> clearProviderCredential() async {
    final uid = auth.snapshot.session?.uid;
    if (uid == null) return;
    await providerCredentials.delete(uid);
    await _queueProductionSync();
  }

  void configureAssistant({
    required AssistantProvider provider,
    required String model,
    required String credential,
    String? endpoint,
  }) {
    if (!chatReady) {
      throw StateError('Native services are not connected.');
    }
    nativeHub.configureAssistant(
      requestId:
          'configure-assistant-g$_authorityGeneration-${_assistantTransportSequence++}',
      provider: provider,
      model: model,
      credential: credential,
      endpoint: endpoint,
    );
    _assistantConfigured = true;
  }

  Future<void> _configureSelectedAssistant(String expectedUid) async {
    ProviderCredential? credential;
    try {
      credential = await providerCredentials.read(expectedUid);
    } catch (_) {
      _clearAssistant();
      return;
    }
    if (_disposed || auth.snapshot.session?.uid != expectedUid) return;
    if (credential != null) {
      configureAssistant(
        provider: credential.provider,
        model: credential.model,
        endpoint: credential.endpoint,
        credential: credential.credential,
      );
      return;
    }
    BillingEntitlement? entitlement;
    try {
      entitlement = billing == null ? null : await billing!.getEntitlement();
    } catch (_) {
      _clearAssistant();
      return;
    }
    if (billing != null &&
        (entitlement?.plan != OmiPlan.pro || entitlement?.active != true)) {
      _clearAssistant();
      return;
    }
    await _configureManagedAssistant(expectedUid);
  }

  Future<void> _configureManagedAssistant(String expectedUid) async {
    final origin = _workerOrigin;
    if (origin == null || !chatReady) return;
    final session = await auth.validSession();
    if (_disposed ||
        session == null ||
        session.uid != expectedUid ||
        !productionReady ||
        auth.snapshot.session?.uid != expectedUid) {
      _clearAssistant();
      return;
    }
    configureAssistant(
      provider: AssistantProvider.worker,
      model: _managedAssistantModel,
      endpoint: origin.resolve('/v1').toString(),
      credential: session.idToken,
    );
    _assistantRefreshTimer?.cancel();
    final untilRefresh = session.expiresAt
        .subtract(_assistantRefreshLead)
        .difference(_now());
    final delay = untilRefresh > _assistantMinimumRefreshDelay
        ? untilRefresh
        : _assistantMinimumRefreshDelay;
    _assistantRefreshTimer = Timer(delay, () {
      _assistantRefreshTimer = null;
      unawaited(_queueProductionSync().onError((_, _) {}));
    });
  }

  void _clearAssistant() {
    _assistantRefreshTimer?.cancel();
    _assistantRefreshTimer = null;
    if (!_nativeInitialized || !_assistantConfigured) return;
    try {
      nativeHub.clearAssistant(
        'clear-assistant-g$_authorityGeneration-${_assistantTransportSequence++}',
      );
    } catch (_) {}
    _assistantConfigured = false;
  }

  Future<String> sendChatMessage({required String text}) =>
      _sendChatMessage(text: text);

  Future<void> startDesktopVoice() {
    final voiceGeneration = ++_desktopVoiceGeneration;
    return _queueDesktopVoice(() => _startDesktopVoice(voiceGeneration));
  }

  Future<void> _startDesktopVoice(int voiceGeneration) async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.macOS &&
            defaultTargetPlatform != TargetPlatform.windows)) {
      throw StateError('Desktop voice is available on macOS and Windows only.');
    }
    final session = auth.snapshot.session;
    final generation = _authorityGeneration;
    if (!chatReady || session == null) {
      throw StateError('Sign in and connect native services first.');
    }
    if (!await desktopVoice.hasPermission()) {
      throw StateError('Microphone permission is required for desktop voice.');
    }
    if (voiceGeneration != _desktopVoiceGeneration) return;
    final transcriptionAuth = await _managedTranscriptionAuthFor(
      uid: session.uid,
      deviceId: 'desktop-microphone',
      encoding: ManagedSttEncoding.linear16,
      sampleRate: DesktopVoiceCapture.sampleRateHz,
    );
    if (generation != _authorityGeneration ||
        voiceGeneration != _desktopVoiceGeneration ||
        auth.snapshot.session?.uid != session.uid) {
      throw StateError('Account authority changed while starting voice.');
    }
    await desktopVoice.start(
      auth: transcriptionAuth,
      authorityId: 'g$generation',
    );
    if (generation != _authorityGeneration ||
        voiceGeneration != _desktopVoiceGeneration ||
        auth.snapshot.session?.uid != session.uid) {
      await desktopVoice.cancel();
      throw StateError('Account authority changed while starting voice.');
    }
  }

  Future<void> continueDesktopVoice() =>
      _queueDesktopVoice(() async => desktopVoice.continueCapture());

  Future<({String requestId, String text})?> stopDesktopVoice() =>
      _queueDesktopVoice(_stopDesktopVoice);

  Future<({String requestId, String text})?> _stopDesktopVoice() async {
    final uid = auth.snapshot.session?.uid;
    final generation = _authorityGeneration;
    final text = await desktopVoice.stop();
    if (text.isEmpty) return null;
    if (generation != _authorityGeneration ||
        uid == null ||
        auth.snapshot.session?.uid != uid) {
      return null;
    }
    final requestId = await _sendChatMessage(text: text);
    return (requestId: requestId, text: text);
  }

  Future<void> cancelDesktopVoice() {
    _desktopVoiceGeneration += 1;
    return desktopVoice.cancel();
  }

  Future<T> _queueDesktopVoice<T>(Future<T> Function() operation) {
    final result = _desktopVoiceLifecycle.then(
      (_) => operation(),
      onError: (_, _) => operation(),
    );
    _desktopVoiceLifecycle = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  Future<String> _sendChatMessage({
    required String text,
    CurrentActionHandoff? currentHandoff,
  }) =>
      _conversationController.send(text: text, currentHandoff: currentHandoff);

  Future<void> saveAssistantMessage({
    required String requestId,
    required String text,
  }) => _conversationController.saveAssistantMessage(
    requestId: requestId,
    text: text,
  );

  Future<List<ConversationMessage>> replayConversation({int after = 0}) =>
      _conversationController.replay(after: after);

  Future<String> handoffCurrentAction(CurrentActionHandoff handoff) =>
      _conversationController.handoff(handoff);

  String get _conversationSource => kIsWeb
      ? 'web'
      : switch (defaultTargetPlatform) {
          TargetPlatform.macOS ||
          TargetPlatform.windows ||
          TargetPlatform.linux => 'desktop',
          _ => 'app',
        };

  Future<String> decideChatApproval({
    required String proposalId,
    required ApprovalDecision decision,
  }) => _conversationController.decide(
    proposalId: proposalId,
    decision: decision,
  );

  void cancelChatRequest(String requestId) =>
      _conversationController.cancel(requestId);

  void _authChanged() {
    if (!productionReady || auth.snapshot.session?.uid != _configuredPersonId) {
      _fenceTranscriptCaptures();
      unawaited(deviceAudio.stop());
    }
    unawaited(_queueProductionSync().onError((_, _) {}));
  }

  Future<void> _queueProductionSync() {
    final operation = _lifecycle
        .then<void>((_) {}, onError: (_, _) {})
        .then((_) => _syncProductionState());
    _lifecycle = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> _syncProductionState() async {
    if (_disposed) return;
    final session = productionReady ? auth.snapshot.session : null;
    if (session == null) {
      memorySyncPump?.stop();
      await _stopCapture();
      await _shutdownNative();
      return;
    }
    if (_configuredPersonId == session.uid && _nativeInitialized) {
      memorySyncPump?.start(session.uid);
      if (_workerOrigin != null && _assistantRefreshTimer == null) {
        await _configureSelectedAssistant(session.uid);
      }
      _conversationController.scheduleInboxPoll();
      return;
    }
    await _stopCapture();
    if (!await _ensureNativeInitialized()) return;
    final databasePath = await memoryDatabasePath(session.uid);
    if (_disposed ||
        !productionReady ||
        auth.snapshot.session?.uid != session.uid) {
      return;
    }
    _configuredPersonId = session.uid;
    nativeHub.configureMemory(
      requestId: 'configure-memory-${session.uid}',
      databasePath: databasePath,
      tenantId: session.uid,
      personId: session.uid,
    );
    _transcriptMemoryIngestor.configure(
      personId: session.uid,
      authorityGeneration: _authorityGeneration,
    );
    memorySyncPump?.start(session.uid);
    if (_workerOrigin != null) await _configureSelectedAssistant(session.uid);
    _conversationController.scheduleInboxPoll(Duration.zero);
  }

  Future<bool> _ensureNativeInitialized() async {
    if (_nativeInitialized) return true;
    await nativeHub.initialize();
    if (!nativeHub.available) return false;
    _nativeEventSubscription = nativeHub.events.listen(
      _handleNativeEvent,
      onError: _nativeEvents.addError,
    );
    _nativeInitialized = true;
    if (_workerOrigin != null) {
      nativeHub.configureTrustedAssistant(
        requestId: 'configure-trusted-assistant',
        managedWorkerOrigin: _workerOrigin.toString(),
      );
    }
    return true;
  }

  void _handleNativeEvent(NativeEvent event) {
    if (!_conversationController.handleNativeEvent(event)) return;
    _nativeEvents.add(event);
    _transcriptMemoryIngestor.handle(event);
  }

  void _fenceTranscriptCaptures() {
    final generation = _conversationController.fence(
      cancelPending: _nativeInitialized,
    );
    unawaited(cancelDesktopVoice());
    _clearAssistant();
    _transcriptMemoryIngestor.fence(
      authorityGeneration: generation,
      cancelPending: _nativeInitialized,
    );
  }

  Future<void> _stopCapture() async {
    await deviceAudio.stop();
    if (deviceRelay.role == DeviceRelayRole.mobileOwner) {
      try {
        await deviceRelay.disconnect();
      } catch (_) {}
    }
  }

  Future<void> _shutdownNative() async {
    _fenceTranscriptCaptures();
    _configuredPersonId = null;
    if (!_nativeInitialized) return;
    await _nativeEventSubscription?.cancel();
    _nativeEventSubscription = null;
    nativeHub.dispose();
    _nativeInitialized = false;
  }

  Future<RelayDevice> connectDevice(
    String deviceId, {
    TranscriptionAuth? transcriptionAuth,
  }) async {
    final operation = _lifecycle.then<void>((_) {}, onError: (_, _) {}).then((
      _,
    ) async {
      if (transcriptionAuth is TranscriptionAuthLocal) {
        throw const LocalTranscriptionUnavailable();
      }
      final uid = auth.snapshot.session?.uid;
      if (!productionReady || !_nativeInitialized || uid == null) {
        throw StateError('Sign in and grant current data consent first.');
      }
      final device = await deviceRelay.connect(deviceId);
      try {
        if (!productionReady || auth.snapshot.session?.uid != uid) {
          throw StateError('Account authority changed while connecting.');
        }
        final selectedAuth =
            transcriptionAuth ?? await _managedTranscriptionAuth(device, uid);
        final selectedAuthIsCurrent = switch (selectedAuth) {
          TranscriptionAuthManaged(:final firebaseToken) =>
            auth.snapshot.session?.idToken == firebaseToken,
          _ => true,
        };
        if (!productionReady ||
            auth.snapshot.session?.uid != uid ||
            !selectedAuthIsCurrent) {
          throw StateError('Account authority changed while connecting.');
        }
        await deviceAudio.start(device, auth: selectedAuth);
        if (!productionReady || auth.snapshot.session?.uid != uid) {
          await deviceAudio.stop();
          throw StateError('Account authority changed while connecting.');
        }
        return device;
      } catch (_) {
        await deviceRelay.disconnect();
        rethrow;
      }
    });
    _lifecycle = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<TranscriptionAuthManaged> _managedTranscriptionAuth(
    RelayDevice device,
    String uid,
  ) {
    final encoding = switch (device.audioCodec) {
      DeviceAudioCodec.pcm8 ||
      DeviceAudioCodec.pcm16 => ManagedSttEncoding.linear16,
      DeviceAudioCodec.opus ||
      DeviceAudioCodec.opusFs320 => ManagedSttEncoding.opus,
      DeviceAudioCodec.unknown => null,
    };
    if (encoding == null) {
      throw StateError(
        'Managed transcription does not support this device audio format.',
      );
    }
    return _managedTranscriptionAuthFor(
      uid: uid,
      deviceId: device.id,
      encoding: encoding,
      sampleRate: device.audioCodec.sampleRate,
    );
  }

  Future<TranscriptionAuthManaged> _managedTranscriptionAuthFor({
    required String uid,
    required String deviceId,
    required ManagedSttEncoding encoding,
    required int sampleRate,
  }) async {
    final managedStt = _managedStt;
    if (managedStt == null) {
      throw StateError(
        'Managed transcription is not configured. Configure BYOK transcription instead.',
      );
    }
    final nonce = DateTime.now().microsecondsSinceEpoch;
    final idempotencyKey = sha256
        .convert(utf8.encode('$uid\u0000$deviceId\u0000$nonce'))
        .toString();
    final managedDeviceId = sha256.convert(utf8.encode(deviceId)).toString();
    final result = await managedStt.createSession(
      idempotencyKey: idempotencyKey,
      deviceId: managedDeviceId,
      language: 'multi',
      encoding: encoding,
      sampleRate: sampleRate,
      channels: 1,
    );
    if (result.session.uid != uid || result.session.idToken.isEmpty) {
      throw StateError(
        'Account authority changed while creating transcription session.',
      );
    }
    return TranscriptionAuthManaged(
      endpoint: result.websocketUrl,
      firebaseToken: result.session.idToken,
    );
  }

  Future<void> disconnectDevice() async {
    final operation = _lifecycle.then<void>((_) {}, onError: (_, _) {}).then((
      _,
    ) async {
      await deviceAudio.stop();
      await deviceRelay.disconnect();
    });
    _lifecycle = operation.then<void>((_) {}, onError: (_, _) {});
    await operation;
  }

  void dispose() {
    _disposed = true;
    memorySyncPump?.dispose();
    auth.removeListener(_authChanged);
    _clearAssistant();
    _lifecycle = _lifecycle
        .then<void>((_) {}, onError: (_, _) {})
        .then((_) => _stopCapture())
        .then((_) => _shutdownNative());
    unawaited(
      _lifecycle
          .then((_) async {
            await desktopVoice.dispose();
            await _nativeEvents.close();
            await _conversationController.dispose();
          })
          .onError((_, _) async {
            await desktopVoice.dispose();
            await _nativeEvents.close();
            await _conversationController.dispose();
          }),
    );
    _worker?.close();
    auth.dispose();
  }
}

Uri _validateWorkerOrigin(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw ArgumentError.value(
      uri,
      'OMI_WORKER_ORIGIN',
      'must be an HTTPS origin without credentials, path, query, or fragment',
    );
  }
  return uri.replace(path: '/');
}

DeviceRelayService _createDeviceRelay() {
  final mobile =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  return DeviceRelayService(
    role: mobile
        ? DeviceRelayRole.mobileOwner
        : DeviceRelayRole.desktopObserver,
    adapter: mobile
        ? UniversalBleDeviceRelayAdapter()
        : const UnavailableDeviceRelayAdapter(
            state: DeviceCapabilityState.unsupported,
          ),
  );
}

Future<String> _defaultMemoryDatabasePath(String uid) async {
  final digest = sha256.convert(utf8.encode(uid));
  return '${(await getApplicationSupportDirectory()).path}/omi-memory-$digest.sqlite3';
}
