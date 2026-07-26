import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/demo/demo_mode.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/omi_shell.dart';
import 'package:omi/native/native_hub.dart';
import 'package:omi/ui/omi_orb.dart';

void main() {
  testWidgets('demo hub keeps its warm scene and rotating mark', (
    tester,
  ) async {
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

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: OmiShell(services: services, previewMode: true),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('demo_hub_backdrop')), findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      Colors.transparent,
    );
    final mark = tester.widget<OmiActivityOrb>(
      find.byKey(const Key('demo_rotating_mark')),
    );
    expect(mark.period, const Duration(seconds: 10));
  }, skip: !omiDemoMode);
}
