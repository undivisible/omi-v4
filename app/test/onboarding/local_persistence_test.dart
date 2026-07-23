import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/main.dart';
import 'package:omi/native/native_hub.dart';
import 'package:omi/onboarding/hub_checklist.dart';
import 'package:omi/onboarding/onboarding_completion.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  AppServices makeServices() {
    final services = AppServices.forTesting(
      nativeHub: const UnavailableNativeHub('test'),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      auth: AuthController(const UnconfiguredAuthGateway()),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    addTearDown(services.dispose);
    return services;
  }

  testWidgets('fresh local launch starts at onboarding', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final services = makeServices();
    await services.initialize();
    await tester.pumpWidget(
      OmiApp(services: services, platformOverride: TargetPlatform.macOS),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('warm_paper_hub')), findsNothing);
    expect(find.textContaining('Hi, I’m Omi.'), findsOneWidget);
  });

  testWidgets(
    'completed local onboarding and starter tasks survive a relaunch',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final firstRun = makeServices();
      await firstRun.initialize();
      await firstRun.onboardingCompletion.complete(localOnboardingUid);
      final checklist = PreferencesHubChecklistStore();
      await checklist.setStarterTasks([
        'Pick omi back up',
        'Decide next step for tsc.hk',
      ]);
      await checklist.setSetupComplete(true);

      final relaunch = makeServices();
      await relaunch.initialize();
      await tester.pumpWidget(
        OmiApp(services: relaunch, platformOverride: TargetPlatform.macOS),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byKey(const Key('warm_paper_hub')), findsOneWidget);
      expect(find.text('Pick omi back up'), findsOneWidget);
      expect(find.text('Decide next step for tsc.hk'), findsOneWidget);
    },
  );

  testWidgets('deleting local data returns to onboarding', (tester) async {
    SharedPreferences.setMockInitialValues({
      'onboarding_complete_v1_local': true,
    });
    final services = makeServices();
    await services.initialize();
    await tester.pumpWidget(
      OmiApp(services: services, platformOverride: TargetPlatform.macOS),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const Key('warm_paper_hub')), findsOneWidget);

    await services.deleteAccount();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byKey(const Key('warm_paper_hub')), findsNothing);
    expect(find.textContaining('Hi, I’m Omi.'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('onboarding_complete_v1_local'), isNull);
  });
}
