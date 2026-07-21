import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'api/worker_http.dart';
import 'auth/auth.dart';
import 'auth/firebase_bootstrap.dart';
import 'capabilities/desktop_capabilities.dart';
import 'channels/channels.dart';
import 'device/device.dart';
import 'memory/memory.dart';
import 'native/native_hub.dart';
import 'settings/settings.dart';

final class TranscriptCaptureConflict implements Exception {
  const TranscriptCaptureConflict(this.requestId);

  final String requestId;
}

typedef _TranscriptCaptureFingerprint = ({
  CaptureSource source,
  int occurredAtMs,
  String text,
});

typedef _PendingTranscriptCapture = ({
  String requestId,
  _TranscriptCaptureFingerprint fingerprint,
});

enum _ChatRequestKind { message, approval }

typedef _ChatRequest = ({int generation, _ChatRequestKind kind});
typedef _ChatProposal = ({
  int generation,
  String parentRequestId,
  int? expiresAtMs,
});

const _completedTranscriptCapacity = 256;
const _managedAssistantModel = 'mimo-v2.5-pro';
const _defaultAssistantRefreshLead = Duration(minutes: 5);
const _defaultAssistantMinimumRefreshDelay = Duration(seconds: 30);

final class AppServices {
  AppServices._({
    required this.auth,
    required this.nativeHub,
    required this.deviceRelay,
    required this.memoryDatabasePath,
    required this.workspaceRoots,
    required this.configurationMessage,
    this.memory,
    this.settings,
    this.channels,
    this._worker,
    this._workerOrigin,
    DateTime Function()? now,
    this._assistantRefreshLead = _defaultAssistantRefreshLead,
    this._assistantMinimumRefreshDelay = _defaultAssistantMinimumRefreshDelay,
  }) : deviceAudio = DeviceAudioForwarder(relay: deviceRelay, hub: nativeHub),
       capabilities = PlatformDesktopCapabilityGateway(
         workspaceRoots: workspaceRoots,
       ),
       _now = now ?? DateTime.now;

  factory AppServices.fromEnvironment() {
    final auth = AuthController(const UnconfiguredAuthGateway());
    final nativeHub = createNativeHub();
    final deviceRelay = _createDeviceRelay();
    const origin = String.fromEnvironment('OMI_API_ORIGIN');
    const assistantOrigin = String.fromEnvironment('OMI_WORKER_ORIGIN');
    if (origin.isEmpty) {
      return AppServices._(
        auth: auth,
        nativeHub: nativeHub,
        deviceRelay: deviceRelay,
        memoryDatabasePath: _defaultMemoryDatabasePath,
        workspaceRoots: PreferencesWorkspaceRootStore(),
        configurationMessage:
            'Set OMI_API_ORIGIN and configure Firebase to connect.',
        workerOrigin: _parseWorkerOrigin(assistantOrigin),
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
      configurationMessage: 'Configure Firebase to sign in and connect.',
      memory: MemoryClient(WorkerMemoryTransport(worker)),
      settings: SettingsClient(WorkerSettingsTransport(worker)),
      channels: ChannelClient(WorkerChannelTransport(worker)),
      worker: worker,
      workerOrigin: _parseWorkerOrigin(assistantOrigin),
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
    const assistantOrigin = String.fromEnvironment('OMI_WORKER_ORIGIN');
    if (origin.isEmpty) {
      return AppServices._(
        auth: auth,
        nativeHub: nativeHub,
        deviceRelay: deviceRelay,
        memoryDatabasePath: _defaultMemoryDatabasePath,
        workspaceRoots: PreferencesWorkspaceRootStore(),
        configurationMessage: 'Set OMI_API_ORIGIN to connect.',
        workerOrigin: _parseWorkerOrigin(assistantOrigin),
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
      configurationMessage: gateway.isConfigured
          ? 'Sign in to connect.'
          : 'Configure Firebase to sign in and connect.',
      memory: MemoryClient(WorkerMemoryTransport(worker)),
      settings: SettingsClient(WorkerSettingsTransport(worker)),
      channels: ChannelClient(WorkerChannelTransport(worker)),
      worker: worker,
      workerOrigin: _parseWorkerOrigin(assistantOrigin),
    );
  }

  factory AppServices.forTesting({
    required NativeHub nativeHub,
    required DeviceRelayService deviceRelay,
    required AuthController auth,
    required String Function(String uid) memoryDatabasePath,
    WorkspaceRootStore? workspaceRoots,
    Uri? workerOrigin,
    DateTime Function()? now,
    Duration assistantRefreshLead = _defaultAssistantRefreshLead,
    Duration assistantMinimumRefreshDelay =
        _defaultAssistantMinimumRefreshDelay,
  }) => AppServices._(
    auth: auth,
    nativeHub: nativeHub,
    deviceRelay: deviceRelay,
    memoryDatabasePath: (uid) async => memoryDatabasePath(uid),
    workspaceRoots: workspaceRoots ?? VolatileWorkspaceRootStore(),
    configurationMessage: 'Test services are not connected.',
    workerOrigin: workerOrigin == null
        ? null
        : _validateWorkerOrigin(workerOrigin),
    now: now,
    assistantRefreshLead: assistantRefreshLead,
    assistantMinimumRefreshDelay: assistantMinimumRefreshDelay,
  );

  final AuthController auth;
  final NativeHub nativeHub;
  final DeviceRelayService deviceRelay;
  final DeviceAudioForwarder deviceAudio;
  final WorkspaceRootStore workspaceRoots;
  final PlatformDesktopCapabilityGateway capabilities;
  final String configurationMessage;
  final MemoryClient? memory;
  final SettingsClient? settings;
  final ChannelClient? channels;
  final WorkerHttpClient? _worker;
  final Uri? _workerOrigin;
  final DateTime Function() _now;
  final Duration _assistantRefreshLead;
  final Duration _assistantMinimumRefreshDelay;
  final Future<String> Function(String uid) memoryDatabasePath;
  final _nativeEvents = StreamController<NativeEvent>.broadcast();
  final _chatAuthorityChanges = StreamController<int>.broadcast(sync: true);
  StreamSubscription<NativeEvent>? _nativeEventSubscription;
  String? _configuredPersonId;
  final _pendingTranscriptCaptures = <String, _PendingTranscriptCapture>{};
  final _transcriptIngestionByRequest = <String, String>{};
  final _completedTranscriptCaptures =
      <String, _TranscriptCaptureFingerprint>{};
  int _authorityGeneration = 0;
  int _transcriptTransportSequence = 0;
  int _chatTransportSequence = 0;
  final _chatRequests = <String, _ChatRequest>{};
  final _chatProposals = <String, _ChatProposal>{};
  final _terminalChatRequests = <String>{};
  bool _nativeInitialized = false;
  bool _assistantConfigured = false;
  Timer? _assistantRefreshTimer;
  bool _disposed = false;
  Future<void> _lifecycle = Future.value();

  Stream<NativeEvent> get nativeEvents => _nativeEvents.stream;
  Stream<int> get chatAuthorityChanges => _chatAuthorityChanges.stream;

  Future<String?> get selectedWorkspaceRoot =>
      capabilities.verifiedWorkspaceRoot();

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
          'configure-assistant-g$_authorityGeneration-${_chatTransportSequence++}',
      provider: provider,
      model: model,
      credential: credential,
      endpoint: endpoint,
    );
    _assistantConfigured = true;
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
        'clear-assistant-g$_authorityGeneration-${_chatTransportSequence++}',
      );
    } catch (_) {}
    _assistantConfigured = false;
  }

  String sendChatMessage({required String text}) {
    if (!chatReady) {
      throw StateError(
        'Sign in, grant consent, and connect native services first.',
      );
    }
    final requestId = 'chat-g$_authorityGeneration-${_chatTransportSequence++}';
    _chatRequests[requestId] = (
      generation: _authorityGeneration,
      kind: _ChatRequestKind.message,
    );
    try {
      nativeHub.sendMessage(requestId: requestId, text: text);
      return requestId;
    } catch (_) {
      _chatRequests.remove(requestId);
      rethrow;
    }
  }

  String decideChatApproval({
    required String proposalId,
    required ApprovalDecision decision,
  }) {
    if (!chatReady) {
      throw StateError('Native services are not connected.');
    }
    final proposal = _chatProposals[proposalId];
    final now = DateTime.now().millisecondsSinceEpoch;
    if (proposal == null ||
        proposal.generation != _authorityGeneration ||
        (proposal.expiresAtMs != null && proposal.expiresAtMs! <= now)) {
      _chatProposals.remove(proposalId);
      throw StateError('This action proposal is unavailable or expired.');
    }
    final requestId =
        'approval-g$_authorityGeneration-${_chatTransportSequence++}';
    _chatRequests[requestId] = (
      generation: _authorityGeneration,
      kind: _ChatRequestKind.approval,
    );
    _chatProposals.remove(proposalId);
    try {
      nativeHub.decideApproval(
        requestId: requestId,
        proposalId: proposalId,
        decision: decision,
      );
      return requestId;
    } catch (_) {
      _chatRequests.remove(requestId);
      _chatProposals[proposalId] = proposal;
      rethrow;
    }
  }

  void cancelChatRequest(String requestId) {
    final request = _chatRequests.remove(requestId);
    if (request == null || request.generation != _authorityGeneration) return;
    _tombstoneChatRequest(requestId);
    _invalidateChatProposals(requestId);
    if (chatReady) nativeHub.cancel(requestId);
  }

  void _authChanged() {
    if (!productionReady || auth.snapshot.session?.uid != _configuredPersonId) {
      _fenceTranscriptCaptures();
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
      await _stopCapture();
      await _shutdownNative();
      return;
    }
    if (_configuredPersonId == session.uid && _nativeInitialized) {
      if (_workerOrigin != null && _assistantRefreshTimer == null) {
        await _configureManagedAssistant(session.uid);
      }
      return;
    }
    await _stopCapture();
    if (!_nativeInitialized) {
      await nativeHub.initialize();
      if (!nativeHub.available) return;
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
    }
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
    if (_workerOrigin != null) await _configureManagedAssistant(session.uid);
  }

  void _handleNativeEvent(NativeEvent event) {
    if (!_acceptChatEvent(event)) return;
    _nativeEvents.add(event);
    if (event case NativeEventMemoryCaptured(:final value)) {
      final ingestionKey = _transcriptIngestionByRequest.remove(
        value.requestId,
      );
      final pending = ingestionKey == null
          ? null
          : _pendingTranscriptCaptures[ingestionKey];
      if (ingestionKey != null && pending?.requestId == value.requestId) {
        _pendingTranscriptCaptures.remove(ingestionKey);
        _completedTranscriptCaptures[ingestionKey] = pending!.fingerprint;
        if (_completedTranscriptCaptures.length >
            _completedTranscriptCapacity) {
          _completedTranscriptCaptures.remove(
            _completedTranscriptCaptures.keys.first,
          );
        }
      }
      return;
    }
    if (event case NativeEventError(:final value)) {
      final requestId = value.requestId;
      if (requestId != null && value.code != 'idempotency_conflict') {
        final ingestionKey = _transcriptIngestionByRequest.remove(requestId);
        final pending = ingestionKey == null
            ? null
            : _pendingTranscriptCaptures[ingestionKey];
        if (ingestionKey != null && pending?.requestId == requestId) {
          _pendingTranscriptCaptures.remove(ingestionKey);
        }
      }
      return;
    }
    if (event case NativeEventTranscriptDelta(:final value)) {
      final uid = auth.snapshot.session?.uid;
      final text = value.text.trim();
      if (!value.finalSegment ||
          text.isEmpty ||
          !productionReady ||
          uid == null ||
          _configuredPersonId != uid) {
        return;
      }
      final generation = _authorityGeneration;
      final identity = [
        uid,
        value.requestId,
        value.segmentSequence,
      ].join('\u0000');
      final ingestionKey =
          'transcript-${sha256.convert(utf8.encode(identity))}';
      final fingerprint = (
        source: CaptureSource.omiDevice,
        occurredAtMs: value.occurredAtMs,
        text: text,
      );
      final pending = _pendingTranscriptCaptures[ingestionKey];
      final completed = _completedTranscriptCaptures[ingestionKey];
      if (pending != null || completed != null) {
        if ((pending?.fingerprint ?? completed) != fingerprint) {
          _nativeEvents.addError(TranscriptCaptureConflict(ingestionKey));
        }
        return;
      }
      final requestId =
          'transcript-g$_authorityGeneration-a${_transcriptTransportSequence++}-$ingestionKey';
      _pendingTranscriptCaptures[ingestionKey] = (
        requestId: requestId,
        fingerprint: fingerprint,
      );
      _transcriptIngestionByRequest[requestId] = ingestionKey;
      try {
        if (generation != _authorityGeneration) {
          _pendingTranscriptCaptures.remove(ingestionKey);
          _transcriptIngestionByRequest.remove(requestId);
          return;
        }
        nativeHub.capture(
          requestId: requestId,
          ingestionKey: ingestionKey,
          source: CaptureSource.omiDevice,
          occurredAtMs: value.occurredAtMs,
          text: text,
        );
      } catch (failure, stackTrace) {
        _pendingTranscriptCaptures.remove(ingestionKey);
        _transcriptIngestionByRequest.remove(requestId);
        _nativeEvents.addError(failure, stackTrace);
      }
    }
  }

  bool _acceptChatEvent(NativeEvent event) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (event case NativeEventActionProposal(:final value)) {
      final parent = _chatRequests[value.requestId];
      if (parent == null ||
          parent.kind != _ChatRequestKind.message ||
          parent.generation != _authorityGeneration ||
          _chatProposals.containsKey(value.proposalId) ||
          _terminalChatRequests.contains(value.requestId) ||
          (value.expiresAtMs != null && value.expiresAtMs! <= now)) {
        return false;
      }
      _chatProposals[value.proposalId] = (
        generation: _authorityGeneration,
        parentRequestId: value.requestId,
        expiresAtMs: value.expiresAtMs,
      );
      return true;
    }
    String? requestId;
    var terminal = false;
    var requiresMessage = false;
    if (event case NativeEventAssistantDelta(:final value)) {
      requestId = value.requestId;
      terminal = value.finalSegment;
      requiresMessage = true;
    } else if (event case NativeEventToolProgress(:final value)) {
      requestId = value.requestId;
      final request = _chatRequests[requestId];
      terminal =
          value.status == ToolStatus.failed ||
          value.status == ToolStatus.cancelled ||
          (request?.kind == _ChatRequestKind.approval &&
              value.status == ToolStatus.complete);
    } else if (event case NativeEventError(:final value)) {
      requestId = value.requestId;
      if (requestId == null ||
          (!requestId.startsWith('chat-') &&
              !requestId.startsWith('approval-'))) {
        return true;
      }
      terminal = true;
    } else {
      return true;
    }
    final request = _chatRequests[requestId];
    if (request == null ||
        request.generation != _authorityGeneration ||
        (requiresMessage && request.kind != _ChatRequestKind.message) ||
        _terminalChatRequests.contains(requestId)) {
      return false;
    }
    if (terminal) {
      _chatRequests.remove(requestId);
      _tombstoneChatRequest(requestId);
      final failedParent =
          event is NativeEventError ||
          (event is NativeEventToolProgress &&
              (event.value.status == ToolStatus.failed ||
                  event.value.status == ToolStatus.cancelled));
      if (failedParent) _invalidateChatProposals(requestId);
    }
    return true;
  }

  void _tombstoneChatRequest(String requestId) {
    _terminalChatRequests.add(requestId);
    if (_terminalChatRequests.length > _completedTranscriptCapacity) {
      _terminalChatRequests.remove(_terminalChatRequests.first);
    }
  }

  void _invalidateChatProposals(String parentRequestId) {
    _chatProposals.removeWhere(
      (_, proposal) => proposal.parentRequestId == parentRequestId,
    );
  }

  void _fenceTranscriptCaptures() {
    _authorityGeneration += 1;
    _clearAssistant();
    if (_nativeInitialized) {
      for (final pending in _pendingTranscriptCaptures.values) {
        try {
          nativeHub.cancel(pending.requestId);
        } catch (_) {}
      }
    }
    _pendingTranscriptCaptures.clear();
    _transcriptIngestionByRequest.clear();
    _completedTranscriptCaptures.clear();
    if (_nativeInitialized) {
      for (final requestId in _chatRequests.keys) {
        try {
          nativeHub.cancel(requestId);
        } catch (_) {}
      }
    }
    for (final requestId in _chatRequests.keys) {
      _tombstoneChatRequest(requestId);
    }
    _chatRequests.clear();
    _chatProposals.clear();
    _chatAuthorityChanges.add(_authorityGeneration);
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

  Future<RelayDevice> connectDevice(String deviceId) async {
    final operation = _lifecycle.then<void>((_) {}, onError: (_, _) {}).then((
      _,
    ) async {
      final uid = auth.snapshot.session?.uid;
      if (!productionReady || !_nativeInitialized || uid == null) {
        throw StateError('Sign in and grant current data consent first.');
      }
      final device = await deviceRelay.connect(deviceId);
      try {
        if (!productionReady || auth.snapshot.session?.uid != uid) {
          throw StateError('Account authority changed while connecting.');
        }
        await deviceAudio.start(device);
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

  Future<void> disconnectDevice() async {
    await deviceAudio.stop();
    await deviceRelay.disconnect();
  }

  void dispose() {
    _disposed = true;
    auth.removeListener(_authChanged);
    _clearAssistant();
    _lifecycle = _lifecycle
        .then<void>((_) {}, onError: (_, _) {})
        .then((_) => _stopCapture())
        .then((_) => _shutdownNative());
    unawaited(
      _lifecycle
          .then((_) async {
            await _nativeEvents.close();
            await _chatAuthorityChanges.close();
          })
          .onError((_, _) async {
            await _nativeEvents.close();
            await _chatAuthorityChanges.close();
          }),
    );
    _worker?.close();
    auth.dispose();
  }
}

Uri? _parseWorkerOrigin(String value) =>
    value.isEmpty ? null : _validateWorkerOrigin(Uri.parse(value));

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
