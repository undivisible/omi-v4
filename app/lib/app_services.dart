import 'api/worker_http.dart';
import 'auth/auth.dart';
import 'channels/channels.dart';
import 'memory/memory.dart';
import 'native/native_hub.dart';
import 'settings/settings.dart';

final class AppServices {
  AppServices._({
    required this.auth,
    required this.nativeHub,
    required this.configurationMessage,
    this.memory,
    this.settings,
    this.channels,
    this._worker,
  });

  factory AppServices.fromEnvironment() {
    final auth = AuthController(const UnconfiguredAuthGateway());
    final nativeHub = createNativeHub();
    const origin = String.fromEnvironment('OMI_API_ORIGIN');
    if (origin.isEmpty) {
      return AppServices._(
        auth: auth,
        nativeHub: nativeHub,
        configurationMessage:
            'Set OMI_API_ORIGIN and configure Firebase to connect.',
      );
    }
    final worker = WorkerHttpClient(
      baseUri: Uri.parse(origin),
      sessionProvider: () => auth.snapshot.session,
    );
    return AppServices._(
      auth: auth,
      nativeHub: nativeHub,
      configurationMessage: 'Configure Firebase to sign in and connect.',
      memory: MemoryClient(WorkerMemoryTransport(worker)),
      settings: SettingsClient(WorkerSettingsTransport(worker)),
      channels: ChannelClient(WorkerChannelTransport(worker)),
      worker: worker,
    );
  }

  final AuthController auth;
  final NativeHub nativeHub;
  final String configurationMessage;
  final MemoryClient? memory;
  final SettingsClient? settings;
  final ChannelClient? channels;
  final WorkerHttpClient? _worker;

  bool get canUseApi =>
      _worker != null && auth.snapshot.phase == AuthPhase.signedIn;

  Future<void> initialize() => nativeHub.initialize();

  void dispose() {
    auth.dispose();
    nativeHub.dispose();
    _worker?.close();
  }
}
