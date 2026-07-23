import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_services.dart';
import 'features/desktop_auth_screen.dart';
import 'features/mobile_companion_shell.dart';
import 'features/mobile_onboarding_screen.dart';
import 'features/omi_shell.dart';
import 'features/onboarding_screen.dart';
import 'features/pill_panel.dart';
import 'features/setup_account_screens.dart';
import 'onboarding/hub_checklist.dart';
import 'onboarding/onboarding_completion.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await AppServices.initializeFromEnvironment();
  await services.initialize();
  runApp(OmiApp(services: services));
}

/// Entrypoint for the dedicated settings window on macOS. A second
/// FlutterEngine in the Runner (SettingsWindowController) runs this instead
/// of [main]; it renders only the settings screen inside its own native
/// titled window.
@pragma('vm:entry-point')
Future<void> settingsMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await AppServices.initializeFromEnvironment();
  await services.initialize();
  runApp(SettingsWindowApp(services: services));
}

/// Entrypoint for the floating text-input overlay on macOS. A third
/// FlutterEngine in the Runner (PillPanelController) runs this inside its own
/// non-activating panel; it renders only the pill — input field, suggestions,
/// and the inline completion ghost — and relays every action back to the
/// primary engine, so summoning it never disturbs the hub window.
@pragma('vm:entry-point')
Future<void> pillMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PillPanelApp());
}

/// The channel the settings engine shares with the Runner. Opening settings
/// can name a section, and the window may already be up when that happens, so
/// the Runner both answers `pendingSection` while this engine boots and calls
/// `showSection` on it afterwards.
const settingsRouteChannel = MethodChannel('omi/settings_route');

class SettingsWindowApp extends StatefulWidget {
  const SettingsWindowApp({required this.services, super.key});

  final AppServices services;

  @override
  State<SettingsWindowApp> createState() => _SettingsWindowAppState();
}

class _SettingsWindowAppState extends State<SettingsWindowApp> {
  SettingsSection? _section;

  @override
  void initState() {
    super.initState();
    settingsRouteChannel.setMethodCallHandler(_handle);
    unawaited(_readPendingSection());
  }

  @override
  void dispose() {
    settingsRouteChannel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _readPendingSection() async {
    String? name;
    try {
      name = await settingsRouteChannel.invokeMethod<String>('pendingSection');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
    _select(SettingsSection.tryParse(name));
  }

  Future<Object?> _handle(MethodCall call) async {
    if (call.method != 'showSection') return null;
    _select(SettingsSection.tryParse(call.arguments as String?));
    return null;
  }

  void _select(SettingsSection? section) {
    if (section == null || !mounted || section == _section) return;
    setState(() => _section = section);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Omi Settings',
    debugShowCheckedModeBanner: false,
    themeMode: ThemeMode.system,
    theme: ThemeData(
      brightness: Brightness.light,
      fontFamily: 'SF Pro Display',
      scaffoldBackgroundColor: const Color(0xfff7f6f1),
      colorScheme: const ColorScheme.light(
        primary: Color(0xff171716),
        surface: Color(0xfffffefa),
        onSurface: Color(0xff171716),
        onSurfaceVariant: Color(0xff706e68),
      ),
    ),
    darkTheme: ThemeData(
      brightness: Brightness.dark,
      fontFamily: 'SF Pro Display',
      scaffoldBackgroundColor: const Color(0xff171716),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xfffffcec),
        surface: Color(0xff232321),
        onSurface: Color(0xfff4f2ea),
        onSurfaceVariant: Color(0xffa6a49c),
      ),
    ),
    home: SettingsScreen(services: widget.services, initialSection: _section),
  );
}

class OmiApp extends StatefulWidget {
  const OmiApp({
    super.key,
    this.services,
    this.onboardingCompletionStore,
    this.platformOverride,
  });

  final AppServices? services;
  final OnboardingCompletionStore? onboardingCompletionStore;
  final TargetPlatform? platformOverride;

  @override
  State<OmiApp> createState() => _OmiAppState();
}

class _OmiAppState extends State<OmiApp> {
  late final services = widget.services ?? AppServices.fromEnvironment();
  late final onboardingCompletionStore =
      widget.onboardingCompletionStore ?? services.onboardingCompletion;
  String? _checkedUid;
  bool _checkingCompletion = false;
  bool _onboardingComplete = false;
  int _completionGeneration = 0;

  @override
  void initState() {
    super.initState();
    services.auth.addListener(_authChanged);
    services.dataWipes.addListener(_dataWiped);
    _refreshCompletion();
  }

  void _authChanged() => _refreshCompletion(notify: true);

  void _dataWiped() {
    _checkedUid = null;
    _refreshCompletion(notify: true);
  }

  bool get _mobileCompanion {
    if (kIsWeb) return false;
    final platform = widget.platformOverride ?? defaultTargetPlatform;
    return platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  }

  String get _completionUid {
    final snapshot = services.auth.snapshot;
    return snapshot.hasProcessingAuthority
        ? snapshot.session!.uid
        : localOnboardingUid;
  }

  void _refreshCompletion({bool notify = false}) {
    final uid = _completionUid;
    if (_checkedUid == uid) return;
    final generation = ++_completionGeneration;
    _checkedUid = uid;
    _checkingCompletion = true;
    _onboardingComplete = false;
    if (notify && mounted) setState(() {});
    unawaited(_loadCompletion(uid, generation));
  }

  Future<void> _loadCompletion(String uid, int generation) async {
    var complete = false;
    try {
      complete = await onboardingCompletionStore.isComplete(uid);
    } catch (_) {
      complete = false;
    }
    if (!mounted || generation != _completionGeneration) return;
    setState(() {
      _checkingCompletion = false;
      _onboardingComplete = complete;
    });
  }

  Future<void> _completeOnboarding() async {
    try {
      await PreferencesHubChecklistStore().setSetupComplete(true);
    } catch (_) {}
    final uid = _completionUid;
    await onboardingCompletionStore.complete(uid);
    if (!mounted || _completionUid != uid) return;
    setState(() {
      _checkedUid = uid;
      _checkingCompletion = false;
      _onboardingComplete = true;
    });
  }

  @override
  void dispose() {
    services.auth.removeListener(_authChanged);
    services.dataWipes.removeListener(_dataWiped);
    if (widget.services == null) services.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const background = Color(0xff0b1013);
    const surface = Color(0xff151c20);
    const accent = Color(0xfffffcec);
    const paper = Color(0xfff7f6f1);
    const paperSurface = Color(0xfffffefa);
    const ink = Color(0xff171716);
    const textTheme = TextTheme(
      displaySmall: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -1),
      headlineMedium: TextStyle(
        fontWeight: FontWeight.w600,
        letterSpacing: -.5,
      ),
      titleMedium: TextStyle(fontWeight: FontWeight.w600),
      bodyLarge: TextStyle(height: 1.45),
    );
    return MaterialApp(
      title: 'Omi',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: paper,
        colorScheme: const ColorScheme.light(
          primary: ink,
          surface: paperSurface,
          onSurface: ink,
          onSurfaceVariant: Color(0xff706e68),
          secondary: Color(0xff2f9d8a),
        ),
        fontFamily: 'SF Pro Display',
        textTheme: textTheme,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.black.withValues(alpha: .05),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          surface: surface,
          onSurface: Color(0xfff4f7f6),
        ),
        fontFamily: 'SF Pro Display',
        textTheme: textTheme,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withValues(alpha: .06),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: Uri.base.queryParameters['desktop_auth'] != null
          ? DesktopAuthScreen(
              services: services,
              sessionId: Uri.base.queryParameters['desktop_auth']!,
            )
          : _checkingCompletion
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _onboardingComplete
          ? _mobileCompanion
                ? MobileCompanionShell(services: services)
                : OmiShell(services: services)
          : _mobileCompanion
          ? MobileOnboardingScreen(
              services: services,
              onFinish: _completeOnboarding,
            )
          : OnboardingScreen(services: services, onFinish: _completeOnboarding),
    );
  }
}
