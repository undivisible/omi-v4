import 'package:flutter/material.dart';

import 'app_services.dart';
import 'features/onboarding_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = AppServices.fromEnvironment();
  await services.initialize();
  runApp(OmiApp(services: services));
}

class OmiApp extends StatefulWidget {
  const OmiApp({super.key, this.services});

  final AppServices? services;

  @override
  State<OmiApp> createState() => _OmiAppState();
}

class _OmiAppState extends State<OmiApp> {
  late final services = widget.services ?? AppServices.fromEnvironment();

  @override
  void dispose() {
    services.dispose();
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
      home: OnboardingScreen(services: services),
    );
  }
}
