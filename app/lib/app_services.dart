import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/dev_gemini.dart';
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
import 'onboarding/onboarding_completion.dart';
import 'providers/providers.dart';
import 'settings/settings.dart';

export 'memory/transcript_memory_ingestor.dart' show TranscriptCaptureConflict;

const _managedAssistantModel = 'mimo-v2.5-pro';
const _localOfflinePersonId = 'local-offline';
const _localProfileNameKey = 'omi_local_profile_name';
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

enum VoiceStartFailure {
  unsupportedPlatform,
  signedOut,
  microphonePermission,
  backendNotConfigured,
  network,
}

final class VoiceStartException extends StateError {
  VoiceStartException(this.failure, String message) : super(message);

  final VoiceStartFailure failure;
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
    LiveVoiceCapture? liveVoice,
    this.liveVoiceTokens,
    SystemAudioCaptureModeStore? captureModeStore,
    this._meetingMic,
  }) : _captureModeStore =
           captureModeStore ?? PreferencesSystemAudioCaptureModeStore(),
       currents = currentsClient == null
           ? null
           : CurrentsController(currentsClient),
       deviceAudio = DeviceAudioForwarder(relay: deviceRelay, hub: nativeHub),
       capabilities = PlatformDesktopCapabilityGateway(
         workspaceRoots: workspaceRoots,
       ),
       _now = now ?? DateTime.now {
    this.desktopVoice = desktopVoice ?? DesktopVoiceCapture(hub: nativeHub);
    this.liveVoice = liveVoice ?? LiveVoiceCapture(hub: nativeHub);
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
      isReady: () => chatReady || localMode,
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
    final origin = apiOrigin();
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
      liveVoiceTokens: WorkerVoiceClient(worker),
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
    final origin = apiOrigin();
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
      liveVoiceTokens: WorkerVoiceClient(worker),
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
    LiveVoiceCapture? liveVoice,
    LiveVoiceTokenClient? liveVoiceTokens,
    MemorySyncPump? memorySync,
    SystemAudioCaptureModeStore? captureModeStore,
    MeetingMicCapture? meetingMic,
    WorkerHttpClient? worker,
  }) => AppServices._(
    auth: auth,
    worker: worker,
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
    liveVoice: liveVoice,
    liveVoiceTokens: liveVoiceTokens,
    memorySyncPump: memorySync,
    captureModeStore: captureModeStore ?? VolatileSystemAudioCaptureModeStore(),
    meetingMic: meetingMic,
  );

  final AuthController auth;
  final LiveVoiceTokenClient? liveVoiceTokens;
  final NativeHub nativeHub;
  final DeviceRelayService deviceRelay;
  final DeviceAudioForwarder deviceAudio;
  late final DesktopVoiceCapture desktopVoice;
  late final LiveVoiceCapture liveVoice;
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

  WorkerOAuthClient? get oauthConnections =>
      _worker == null ? null : WorkerOAuthClient(_worker);

  late final OnboardingCompletionStore onboardingCompletion = _worker == null
      ? PreferencesOnboardingCompletionStore()
      : LayeredOnboardingCompletionStore(
          local: PreferencesOnboardingCompletionStore(),
          remote: WorkerOnboardingCompletionStore(_worker),
        );

  Future<void> deleteAccount() async {
    final worker = _worker;
    final uid = auth.snapshot.session?.uid;
    // Signed in with a backend: delete server-side first, then wipe locally.
    // Signed out (or no backend configured): deleting the account degrades to
    // wiping everything local instead of failing.
    if (worker != null && uid != null) {
      final response = await worker.send(method: 'DELETE', path: '/v1/account');
      if (response.statusCode != 204 && response.statusCode != 200) {
        final body = response.body;
        throw WorkerResponseException(
          body is Map<String, Object?> && body['error'] is String
              ? body['error']! as String
              : 'Account deletion failed (${response.statusCode})',
        );
      }
    }
    if (uid != null) {
      try {
        await providerCredentials.delete(uid);
      } catch (_) {}
    }
    try {
      await (await SharedPreferences.getInstance()).clear();
    } catch (_) {}
    if (uid != null) await auth.signOut();
  }

  final MemorySyncPump? memorySyncPump;
  final ManagedSttClient? _managedStt;
  final Uri? _workerOrigin;
  final DateTime Function() _now;
  final Duration _assistantRefreshLead;
  final Duration _assistantMinimumRefreshDelay;
  final Future<String> Function(String uid) memoryDatabasePath;

  /// The deployed worker is the default backend; OMI_API_ORIGIN overrides it
  /// (e.g. http://127.0.0.1:8787 against `wrangler dev`).
  static const defaultApiOrigin = 'https://omi.tsc.hk';

  static String apiOrigin() {
    const origin = String.fromEnvironment('OMI_API_ORIGIN');
    return origin.isEmpty ? defaultApiOrigin : origin;
  }

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
  bool _desktopVoiceRouteIsLive = false;
  bool Function(String text)? desktopVoiceIntentInterceptor;
  Future<void> _liveVoiceLifecycle = Future.value();
  int _liveVoiceGeneration = 0;
  final SystemAudioCaptureModeStore _captureModeStore;
  MeetingMicCapture? _meetingMic;
  bool _meetingActive = false;
  int _meetingAuthSequence = 0;

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

  /// Eagerly resyncs the signed-in account's existing memory/profile from
  /// the backend, for returning users who already have an account and skip
  /// the fresh on-device scan step during onboarding. This reuses the same
  /// production-sync path that normally runs lazily on auth changes and
  /// after sign-in.
  Future<void> resyncAccount() => _queueProductionSync();

  Future<void> captureOnboardingProfile({
    String? name,
    required List<String> languages,
  }) async {
    final snapshot = auth.snapshot;
    if (!_localFallbackEligible && !snapshot.hasProcessingAuthority) {
      return;
    }
    if (name == null && languages.isEmpty) return;
    if (name != null && name.trim().isNotEmpty) {
      try {
        await (await SharedPreferences.getInstance()).setString(
          _localProfileNameKey,
          name.trim(),
        );
      } catch (_) {}
    }
    // Ensure memory (production or local/offline) is configured before the
    // native hub is asked to capture — otherwise this can race ahead of
    // configureMemory, especially on a cold start or when auth is
    // unavailable, and land the capture nowhere.
    await _queueProductionSync();
    try {
      if (!await _ensureNativeInitialized()) return;
    } catch (_) {
      return;
    }
    final spoken = languages.join(', ');
    final text = name == null
        ? 'The user speaks $spoken.'
        : languages.isEmpty
        ? 'The user’s name is $name.'
        : 'The user’s name is $name. They speak $spoken.';
    final occurredAtMs = _now().millisecondsSinceEpoch;
    try {
      nativeHub.capture(
        requestId: 'onboarding-profile-${_randomId()}',
        ingestionKey: 'onboarding-profile-$occurredAtMs',
        source: CaptureSource.chat,
        occurredAtMs: occurredAtMs,
        recordedAtMs: occurredAtMs,
        text: text,
      );
    } catch (_) {}
  }

  /// Name captured during onboarding, used to greet the user when there is
  /// no signed-in session (or the session lacks a display name).
  Future<String?> localProfileName() async {
    try {
      final value = (await SharedPreferences.getInstance()).getString(
        _localProfileNameKey,
      );
      final trimmed = value?.trim();
      return trimmed == null || trimmed.isEmpty ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

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

  /// Dev/no-account mode: the native hub is configured against the
  /// local/offline memory store and a developer Gemini key is available, so
  /// chat and live voice can run directly without a signed-in session.
  bool get localMode =>
      _nativeInitialized &&
      _configuredPersonId == _localOfflinePersonId &&
      DevGemini.apiKey != null;

  /// Whether the local/offline memory store should back the app instead of a
  /// production session: auth is entirely unconfigured, or the user is signed
  /// out but a developer Gemini key is available for direct local use.
  bool get _localFallbackEligible =>
      auth.snapshot.phase == AuthPhase.unavailable ||
      (auth.snapshot.phase == AuthPhase.signedOut && DevGemini.apiKey != null);

  Future<ProviderCredential?> get providerCredential async {
    final uid = auth.snapshot.session?.uid;
    return uid == null ? null : providerCredentials.read(uid);
  }

  Future<List<ProviderCredential>> get allProviderCredentials async {
    final uid = auth.snapshot.session?.uid;
    return uid == null ? const [] : providerCredentials.readAll(uid);
  }

  Future<void> removeProviderCredential(AssistantProvider provider) async {
    final uid = auth.snapshot.session?.uid;
    if (uid == null) return;
    await providerCredentials.remove(uid, provider);
    await _queueProductionSync();
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

  void startMeeting({String? title}) {
    if (!chatReady || nativeHub is! MeetingHub) {
      throw StateError('Native services are not connected.');
    }
    (nativeHub as MeetingHub).startMeeting(
      requestId: 'meeting-start-${_randomId()}',
      title: title,
    );
  }

  void stopMeeting() {
    if (!chatReady || nativeHub is! MeetingHub) {
      throw StateError('Native services are not connected.');
    }
    (nativeHub as MeetingHub).stopMeeting('meeting-stop-${_randomId()}');
  }

  /// One-shot assistant completion outside the conversation flow, used for
  /// quick drafts (e.g. pre-filling an email body from the cursor pill).
  /// Returns null on timeout or failure — callers must degrade gracefully.
  Future<String?> generateDraft(String prompt, Duration timeout) async {
    if (!_nativeInitialized) return null;
    final requestId = 'draft-${_randomId()}';
    final buffer = StringBuffer();
    final completer = Completer<String?>();
    final subscription = nativeEvents.listen((event) {
      if (event case NativeEventAssistantDelta(
        :final value,
      ) when value.requestId == requestId) {
        buffer.write(value.text);
        if (value.finalSegment && !completer.isCompleted) {
          completer.complete(buffer.toString().trim());
        }
      } else if (event case NativeEventError(
        :final value,
      ) when value.requestId == requestId) {
        if (!completer.isCompleted) completer.complete(null);
      }
    });
    try {
      nativeHub.sendMessage(requestId: requestId, text: prompt);
    } catch (_) {
      await subscription.cancel();
      return null;
    }
    try {
      final value = await completer.future.timeout(timeout);
      return value == null || value.isEmpty ? null : value;
    } on TimeoutException {
      try {
        nativeHub.cancel(requestId);
      } catch (_) {}
      return null;
    } finally {
      await subscription.cancel();
    }
  }

  Future<String> sendChatMessage({required String text}) =>
      _sendChatMessage(text: text);

  Future<void> startDesktopVoice() {
    final voiceGeneration = ++_desktopVoiceGeneration;
    return _queueDesktopVoice(() => _startDesktopVoice(voiceGeneration));
  }

  bool _voiceAuthorityChanged({
    required int generation,
    required int voiceGeneration,
    required int currentVoiceGeneration,
    required String uid,
  }) =>
      generation != _authorityGeneration ||
      voiceGeneration != currentVoiceGeneration ||
      auth.snapshot.session?.uid != uid;

  Future<void> _startDesktopVoice(int voiceGeneration) async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.macOS &&
            defaultTargetPlatform != TargetPlatform.windows)) {
      throw VoiceStartException(
        VoiceStartFailure.unsupportedPlatform,
        'Desktop voice is available on macOS and Windows only.',
      );
    }
    final session = auth.snapshot.session;
    final generation = _authorityGeneration;
    if (!chatReady || session == null) {
      if (localMode && nativeHub is LiveVoiceHub) {
        await _startDesktopVoiceLocal(voiceGeneration);
        return;
      }
      throw VoiceStartException(
        VoiceStartFailure.signedOut,
        DevGemini.apiKey == null
            ? 'Voice needs a signed-in session. ${DevGemini.missingKeyHint}'
            : 'Sign in and connect native services first.',
      );
    }
    if (!await desktopVoice.hasPermission()) {
      throw VoiceStartException(
        VoiceStartFailure.microphonePermission,
        'Microphone permission is required for desktop voice.',
      );
    }
    if (voiceGeneration != _desktopVoiceGeneration) return;
    _desktopVoiceRouteIsLive = false;
    final tokens = liveVoiceTokens;
    if (tokens != null && nativeHub is LiveVoiceHub) {
      GeminiLiveToken? grant;
      try {
        grant = await tokens.createGeminiToken();
      } catch (_) {
        grant = null;
      }
      if (grant != null) {
        if (_voiceAuthorityChanged(
          generation: generation,
          voiceGeneration: voiceGeneration,
          currentVoiceGeneration: _desktopVoiceGeneration,
          uid: session.uid,
        )) {
          throw StateError('Account authority changed while starting voice.');
        }
        // Minting the ephemeral token is not the only way this route can
        // fail — liveVoice.start itself can throw (network blip, model
        // rejection). Fall back to managed STT in that case too, the same
        // as when the token mint fails above.
        var liveStarted = false;
        try {
          await liveVoice.start(
            ephemeralToken: grant.token,
            model: grant.model,
            authorityId: 'g$generation',
          );
          liveStarted = true;
        } catch (_) {
          await liveVoice.cancel();
        }
        if (liveStarted) {
          if (_voiceAuthorityChanged(
            generation: generation,
            voiceGeneration: voiceGeneration,
            currentVoiceGeneration: _desktopVoiceGeneration,
            uid: session.uid,
          )) {
            await liveVoice.cancel();
            throw StateError('Account authority changed while starting voice.');
          }
          _desktopVoiceRouteIsLive = true;
          return;
        }
      }
    }
    if (_managedStt == null) {
      throw VoiceStartException(
        VoiceStartFailure.backendNotConfigured,
        'No voice backend is configured: live voice is unavailable and '
        'managed transcription is not set up.',
      );
    }
    final TranscriptionAuthManaged transcriptionAuth;
    try {
      transcriptionAuth = await _managedTranscriptionAuthFor(
        uid: session.uid,
        deviceId: 'desktop-microphone',
        encoding: ManagedSttEncoding.linear16,
        sampleRate: DesktopVoiceCapture.sampleRateHz,
      );
    } on StateError {
      rethrow;
    } catch (error) {
      throw VoiceStartException(
        VoiceStartFailure.network,
        'Could not reach the managed transcription service: $error',
      );
    }
    if (_voiceAuthorityChanged(
      generation: generation,
      voiceGeneration: voiceGeneration,
      currentVoiceGeneration: _desktopVoiceGeneration,
      uid: session.uid,
    )) {
      throw StateError('Account authority changed while starting voice.');
    }
    await desktopVoice.start(
      auth: transcriptionAuth,
      authorityId: 'g$generation',
    );
    if (_voiceAuthorityChanged(
      generation: generation,
      voiceGeneration: voiceGeneration,
      currentVoiceGeneration: _desktopVoiceGeneration,
      uid: session.uid,
    )) {
      await desktopVoice.cancel();
      throw StateError('Account authority changed while starting voice.');
    }
  }

  /// Dev/no-account live voice: connect straight to the Gemini Live API
  /// with the developer key instead of a Worker-minted ephemeral token.
  Future<void> _startDesktopVoiceLocal(int voiceGeneration) async {
    final key = DevGemini.apiKey;
    if (key == null) {
      throw VoiceStartException(
        VoiceStartFailure.signedOut,
        'Voice needs a signed-in session. ${DevGemini.missingKeyHint}',
      );
    }
    if (!await desktopVoice.hasPermission()) {
      throw VoiceStartException(
        VoiceStartFailure.microphonePermission,
        'Microphone permission is required for desktop voice.',
      );
    }
    if (voiceGeneration != _desktopVoiceGeneration) return;
    _desktopVoiceRouteIsLive = false;
    await liveVoice.start(
      ephemeralToken: key,
      model: DevGemini.liveModel,
      authorityId: 'g$_authorityGeneration',
    );
    if (voiceGeneration != _desktopVoiceGeneration) {
      await liveVoice.cancel();
      return;
    }
    _desktopVoiceRouteIsLive = true;
  }

  Future<void> continueDesktopVoice() => _queueDesktopVoice(() async {
    if (_desktopVoiceRouteIsLive) {
      if (!liveVoice.active) throw StateError('Desktop voice is not active.');
      return;
    }
    desktopVoice.continueCapture();
  });

  Future<({String requestId, String text})?> stopDesktopVoice() =>
      _queueDesktopVoice(_stopDesktopVoice);

  Future<({String requestId, String text})?> _stopDesktopVoice() async {
    final uid = auth.snapshot.session?.uid;
    final generation = _authorityGeneration;
    final text = _desktopVoiceRouteIsLive
        ? await liveVoice.stop()
        : await desktopVoice.stop();
    _desktopVoiceRouteIsLive = false;
    if (text.isEmpty) return null;
    if (desktopVoiceIntentInterceptor?.call(text) ?? false) {
      return (requestId: '', text: text);
    }
    if (generation != _authorityGeneration ||
        (!localMode && (uid == null || auth.snapshot.session?.uid != uid))) {
      return null;
    }
    final requestId = await _sendChatMessage(text: text);
    return (requestId: requestId, text: text);
  }

  Future<void> cancelDesktopVoice() {
    _desktopVoiceGeneration += 1;
    if (_desktopVoiceRouteIsLive) {
      _desktopVoiceRouteIsLive = false;
      return Future.wait([
        liveVoice.cancel(),
        desktopVoice.cancel(),
      ]).then((_) {});
    }
    return desktopVoice.cancel();
  }

  Future<void> startLiveVoice() {
    final voiceGeneration = ++_liveVoiceGeneration;
    return _queueLiveVoice(() => _startLiveVoice(voiceGeneration));
  }

  Future<void> _startLiveVoice(int voiceGeneration) async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.macOS &&
            defaultTargetPlatform != TargetPlatform.windows)) {
      throw StateError('Live voice is available on macOS and Windows only.');
    }
    final session = auth.snapshot.session;
    final generation = _authorityGeneration;
    if (!chatReady || session == null) {
      throw StateError('Sign in and connect native services first.');
    }
    final tokens = liveVoiceTokens;
    if (tokens == null) {
      throw StateError('Live voice requires the managed Worker.');
    }
    if (!await liveVoice.hasPermission()) {
      throw StateError('Microphone permission is required for live voice.');
    }
    if (voiceGeneration != _liveVoiceGeneration) return;
    final grant = await tokens.createGeminiToken();
    if (_voiceAuthorityChanged(
      generation: generation,
      voiceGeneration: voiceGeneration,
      currentVoiceGeneration: _liveVoiceGeneration,
      uid: session.uid,
    )) {
      throw StateError('Account authority changed while starting live voice.');
    }
    await liveVoice.start(
      ephemeralToken: grant.token,
      model: grant.model,
      authorityId: 'g$generation',
    );
    if (_voiceAuthorityChanged(
      generation: generation,
      voiceGeneration: voiceGeneration,
      currentVoiceGeneration: _liveVoiceGeneration,
      uid: session.uid,
    )) {
      await liveVoice.cancel();
      throw StateError('Account authority changed while starting live voice.');
    }
  }

  Future<void> stopLiveVoice() => _queueLiveVoice(() => liveVoice.stop());

  Future<void> cancelLiveVoice() {
    _liveVoiceGeneration += 1;
    return liveVoice.cancel();
  }

  Future<T> _queueLiveVoice<T>(Future<T> Function() operation) {
    final result = _liveVoiceLifecycle.then(
      (_) => operation(),
      onError: (_, _) => operation(),
    );
    _liveVoiceLifecycle = result.then<void>((_) {}, onError: (_, _) {});
    return result;
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
    // Auth can be entirely unconfigured (local/testing builds with no
    // backend). There is no production session to configure memory for in
    // that case, but onboarding capture still needs somewhere to land, so
    // configure a local/offline memory store keyed by a stable local id
    // instead of skipping memory configuration outright.
    if (_localFallbackEligible) {
      memorySyncPump?.stop();
      if (_configuredPersonId == _localOfflinePersonId && _nativeInitialized) {
        _conversationController.scheduleInboxPoll();
        return;
      }
      await _stopCapture();
      if (!await _ensureNativeInitialized()) return;
      if (_disposed || !_localFallbackEligible) return;
      final databasePath = await memoryDatabasePath(_localOfflinePersonId);
      if (_disposed || !_localFallbackEligible) return;
      _configuredPersonId = _localOfflinePersonId;
      nativeHub.configureMemory(
        requestId: 'configure-memory-$_localOfflinePersonId',
        databasePath: databasePath,
        tenantId: _localOfflinePersonId,
        personId: _localOfflinePersonId,
      );
      _transcriptMemoryIngestor.configure(
        personId: _localOfflinePersonId,
        authorityGeneration: _authorityGeneration,
      );
      _conversationController.scheduleInboxPoll(Duration.zero);
      return;
    }
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
    final hub = nativeHub;
    if (hub is MeetingCaptureHub) {
      final mode = await _captureModeStore.read();
      (hub as MeetingCaptureHub).setSystemAudioCaptureMode(
        requestId: 'set-system-audio-capture-mode-${_meetingAuthSequence++}',
        mode: mode,
      );
    }
    return true;
  }

  Future<SystemAudioCaptureMode> get systemAudioCaptureMode =>
      _captureModeStore.read();

  Future<void> setSystemAudioCaptureMode(SystemAudioCaptureMode mode) async {
    await _captureModeStore.write(mode);
    final hub = nativeHub;
    if (_nativeInitialized && hub is MeetingCaptureHub) {
      (hub as MeetingCaptureHub).setSystemAudioCaptureMode(
        requestId: 'set-system-audio-capture-mode-${_meetingAuthSequence++}',
        mode: mode,
      );
    }
  }

  Future<void> _provideMeetingAuth() async {
    final session = auth.snapshot.session;
    final hub = nativeHub;
    if (!chatReady ||
        session == null ||
        hub is! MeetingCaptureHub ||
        _managedStt == null) {
      return;
    }
    final transcriptionAuth = await _managedTranscriptionAuthFor(
      uid: session.uid,
      deviceId: 'meeting-capture',
      encoding: ManagedSttEncoding.linear16,
      sampleRate: 16000,
    );
    if (_disposed ||
        !_meetingActive ||
        auth.snapshot.session?.uid != session.uid) {
      return;
    }
    (hub as MeetingCaptureHub).provideMeetingAuth(
      requestId: 'provide-meeting-auth-${_meetingAuthSequence++}',
      auth: transcriptionAuth,
      trustedWorkerOrigin: _workerOrigin?.toString(),
    );
  }

  Future<void> _startMeetingMicFallback() async {
    final session = auth.snapshot.session;
    if (!chatReady || session == null || _managedStt == null) return;
    final mic = _meetingMic ??= MeetingMicCapture(hub: nativeHub);
    if (mic.active || !await mic.hasPermission()) return;
    final transcriptionAuth = await _managedTranscriptionAuthFor(
      uid: session.uid,
      deviceId: 'meeting-capture',
      encoding: ManagedSttEncoding.linear16,
      sampleRate: MeetingMicCapture.sampleRateHz,
    );
    if (_disposed ||
        !_meetingActive ||
        auth.snapshot.session?.uid != session.uid) {
      return;
    }
    await mic.start(auth: transcriptionAuth);
  }

  void _handleMeetingEvent(NativeEvent event) {
    if (event case NativeEventMeetingStateChanged(:final value)) {
      _meetingActive = value.active;
      if (value.active) {
        unawaited(_provideMeetingAuth().onError((_, _) {}));
      } else {
        final mic = _meetingMic;
        if (mic != null) unawaited(mic.stop());
      }
    } else if (event case NativeEventError(:final value) when _meetingActive) {
      if (value.code == 'meeting_capture_session_lost') {
        unawaited(_provideMeetingAuth().onError((_, _) {}));
      } else if (value.code == 'meeting_system_audio_unavailable') {
        unawaited(_startMeetingMicFallback().onError((_, _) {}));
      }
    }
  }

  void _handleNativeEvent(NativeEvent event) {
    if (!_conversationController.handleNativeEvent(event)) return;
    _handleMeetingEvent(event);
    _nativeEvents.add(event);
    _transcriptMemoryIngestor.handle(event);
  }

  void _fenceTranscriptCaptures() {
    final generation = _conversationController.fence(
      cancelPending: _nativeInitialized,
    );
    unawaited(cancelDesktopVoice());
    unawaited(cancelLiveVoice());
    _meetingActive = false;
    final meetingMic = _meetingMic;
    if (meetingMic != null) unawaited(meetingMic.stop());
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
        throw StateError(
          _localFallbackEligible
              ? 'Device audio streaming needs a connected account. Local '
                    'mode covers chat and voice; sign in to stream from a '
                    'device.'
              : 'Sign in and grant current data consent first.',
        );
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
            await _meetingMic?.dispose();
            await desktopVoice.dispose();
            await liveVoice.dispose();
            await _nativeEvents.close();
            await _conversationController.dispose();
          })
          .onError((_, _) async {
            await _meetingMic?.dispose();
            await desktopVoice.dispose();
            await liveVoice.dispose();
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
