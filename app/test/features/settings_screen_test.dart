import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/features/setup_account_screens.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(AppServices services, {ThemeMode mode = ThemeMode.light}) =>
      MaterialApp(
        themeMode: mode,
        theme: ThemeData(brightness: Brightness.light),
        darkTheme: ThemeData(brightness: Brightness.dark),
        home: SettingsScreen(services: services, previewMode: true),
      );

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('settings renders without Material errors in $mode', (
      tester,
    ) async {
      final services = AppServices.fromEnvironment();
      addTearDown(services.dispose);
      await tester.pumpWidget(host(services, mode: mode));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
      expect(
        find.text('Account access is disabled in the interface preview.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('sections navigate between panes', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final services = AppServices.fromEnvironment();
    addTearDown(services.dispose);
    await tester.pumpWidget(host(services));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings_section_account')), findsOneWidget);
    expect(find.byKey(const Key('settings_section_calendar')), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings_section_plan')));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to manage your plan.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings_section_providers')));
    await tester.pumpAndSettle();
    expect(
      find.text('Configure BYOK securely from a native Omi app.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('settings_section_permissions')));
    await tester.pumpAndSettle();
    expect(find.text('Allow screen understanding'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings_section_advanced')));
    await tester.pumpAndSettle();
    expect(find.text('Agent control unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('settings route pushed without a scaffold still renders', (
    tester,
  ) async {
    final services = AppServices.fromEnvironment();
    addTearDown(services.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                fullscreenDialog: true,
                builder: (context) =>
                    SettingsScreen(services: services, previewMode: true),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.byKey(const Key('settings_close')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('settings_close')));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('delete account requires confirmation', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final services = AppServices.fromEnvironment();
    addTearDown(services.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DeleteAccountTile(services: services)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('delete_account')));
    await tester.pumpAndSettle();
    expect(find.text('Delete account?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete_account_cancel')));
    await tester.pumpAndSettle();
    expect(find.text('Delete account?'), findsNothing);

    await tester.tap(find.byKey(const Key('delete_account')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete_account_confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Delete account?'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
