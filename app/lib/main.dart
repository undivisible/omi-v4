import 'dart:async';

import 'package:flutter/material.dart';

import 'app_services.dart';
import 'features/desktop_auth_screen.dart';
import 'features/omi_shell.dart';
import 'features/onboarding_screen.dart';
import 'onboarding/onboarding_completion.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await AppServices.initializeFromEnvironment();
  await services.initialize();
  runApp(OmiApp(services: services));
}

class OmiApp extends StatefulWidget {
  const OmiApp({super.key, this.services, this.onboardingCompletionStore});

  final AppServices? services;
  final OnboardingCompletionStore? onboardingCompletionStore;

  @override
  State<OmiApp> createState() => _OmiAppState();
}

class _OmiAppState extends State<OmiApp> {
  late final services = widget.services ?? AppServices.fromEnvironment();
  late final onboardingCompletionStore =
      widget.onboardingCompletionStore ??
      PreferencesOnboardingCompletionStore();
  String? _checkedUid;
  bool _checkingCompletion = false;
  bool _onboardingComplete = false;
  int _completionGeneration = 0;

  @override
  void initState() {
    super.initState();
    services.auth.addListener(_authChanged);
    _refreshCompletion();
  }

  void _authChanged() => _refreshCompletion(notify: true);

  void _refreshCompletion({bool notify = false}) {
    final snapshot = services.auth.snapshot;
    final uid = snapshot.hasProcessingAuthority ? snapshot.session!.uid : null;
    if (uid == null) {
      _completionGeneration += 1;
      _checkedUid = null;
      _checkingCompletion = false;
      _onboardingComplete = false;
      if (notify && mounted) setState(() {});
      return;
    }
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
    final snapshot = services.auth.snapshot;
    if (!snapshot.hasProcessingAuthority) {
      throw StateError('Processing authority is required');
    }
    final uid = snapshot.session!.uid;
    await onboardingCompletionStore.complete(uid);
    if (!mounted ||
        !services.auth.snapshot.hasProcessingAuthority ||
        services.auth.snapshot.session!.uid != uid) {
      return;
    }
    setState(() {
      _checkedUid = uid;
      _checkingCompletion = false;
      _onboardingComplete = true;
    });
  }

  @override
  void dispose() {
    services.auth.removeListener(_authChanged);
    if (widget.services == null) services.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const background = Color(0xff0b1013);
    const surface = Color(0xff151c20);
    const accent = Color(0xff73d5c4);
    return MaterialApp(
      title: 'Omi',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          surface: surface,
          onSurface: Color(0xfff4f7f6),
        ),
        fontFamily: 'SF Pro Display',
        textTheme: const TextTheme(
          displaySmall: TextStyle(
            fontWeight: FontWeight.w600,
            letterSpacing: -1,
          ),
          headlineMedium: TextStyle(
            fontWeight: FontWeight.w600,
            letterSpacing: -.5,
          ),
          titleMedium: TextStyle(fontWeight: FontWeight.w600),
          bodyLarge: TextStyle(height: 1.45),
        ),
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
          ? OmiShell(services: services)
          : OnboardingScreen(services: services, onFinish: _completeOnboarding),
    );
  }
}
