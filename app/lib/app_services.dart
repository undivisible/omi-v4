import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'api/worker_http.dart';
import 'auth/auth.dart';
import 'auth/firebase_bootstrap.dart';
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

const _completedTranscriptCapacity = 256;

final class AppServices {
  AppServices._({
    required this.auth,
    required this.nativeHub,
    required this.deviceRelay,
    required this.memoryDatabasePath,
    required this.configurationMessage,
    this.memory,
    this.settings,
    this.channels,
    this._worker,
  }) : deviceAudio = DeviceAudioForwarder(relay: deviceRelay, hub: nativeHub);

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
      configurationMessage: 'Configure Firebase to sign in and connect.',
      memory: MemoryClient(WorkerMemoryTransport(worker)),
      settings: SettingsClient(WorkerSettingsTransport(worker)),
      channels: ChannelClient(WorkerChannelTransport(worker)),
      worker: worker,
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
      configurationMessage: gateway.isConfigured
          ? 'Sign in to connect.'
          : 'Configure Firebase to sign in and connect.',
      memory: MemoryClient(WorkerMemoryTransport(worker)),
      settings: SettingsClient(WorkerSettingsTransport(worker)),
      channels: ChannelClient(WorkerChannelTransport(worker)),
      worker: worker,
    );
  }

  factory AppServices.forTesting({
    required NativeHub nativeHub,
    required DeviceRelayService deviceRelay,
    required AuthController auth,
    required String Function(String uid) memoryDatabasePath,
  }) => AppServices._(
    auth: auth,
    nativeHub: nativeHub,
    deviceRelay: deviceRelay,
    memoryDatabasePath: (uid) async => memoryDatabasePath(uid),
    configurationMessage: 'Test services are not connected.',
  );

  final AuthController auth;
  final NativeHub nativeHub;
  final DeviceRelayService deviceRelay;
  final DeviceAudioForwarder deviceAudio;
  final String configurationMessage;
  final MemoryClient? memory;
  final SettingsClient? settings;
  final ChannelClient? channels;
  final WorkerHttpClient? _worker;
  final Future<String> Function(String uid) memoryDatabasePath;
  final _nativeEvents = StreamController<NativeEvent>.broadcast();
  StreamSubscription<NativeEvent>? _nativeEventSubscription;
  String? _configuredPersonId;
  final _pendingTranscriptCaptures = <String, _PendingTranscriptCapture>{};
  final _transcriptIngestionByRequest = <String, String>{};
  final _completedTranscriptCaptures =
      <String, _TranscriptCaptureFingerprint>{};
  int _authorityGeneration = 0;
  int _transcriptTransportSequence = 0;
  bool _nativeInitialized = false;
  bool _disposed = false;
  Future<void> _lifecycle = Future.value();

  Stream<NativeEvent> get nativeEvents => _nativeEvents.stream;

  bool get canUseApi => _worker != null && auth.snapshot.hasProcessingAuthority;

  Future<void> initialize() async {
    auth.addListener(_authChanged);
    await _queueProductionSync();
  }

  bool get productionReady {
    final snapshot = auth.snapshot;
    return snapshot.phase == AuthPhase.signedIn &&
        snapshot.hasProcessingAuthority;
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
    if (_configuredPersonId == session.uid && _nativeInitialized) return;
    await _stopCapture();
    if (!_nativeInitialized) {
      await nativeHub.initialize();
      if (!nativeHub.available) return;
      _nativeEventSubscription = nativeHub.events.listen(
        _handleNativeEvent,
        onError: _nativeEvents.addError,
      );
      _nativeInitialized = true;
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
  }

  void _handleNativeEvent(NativeEvent event) {
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

  void _fenceTranscriptCaptures() {
    _authorityGeneration += 1;
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
    _lifecycle = _lifecycle
        .then<void>((_) {}, onError: (_, _) {})
        .then((_) => _stopCapture())
        .then((_) => _shutdownNative());
    unawaited(
      _lifecycle
          .then((_) => _nativeEvents.close())
          .onError((_, _) => _nativeEvents.close()),
    );
    _worker?.close();
    auth.dispose();
  }
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
