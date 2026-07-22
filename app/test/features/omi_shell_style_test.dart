import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/omi_shell.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  testWidgets('chat opens in the warm paper hub', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
      MaterialApp(home: OmiShell(services: services, previewMode: true)),
    );

    expect(find.byKey(const Key('warm_paper_hub')), findsOneWidget);
    expect(find.byKey(const Key('hub_greeting')), findsOneWidget);
    expect(find.text('WHAT MATTERS NEXT'), findsOneWidget);
    expect(find.text('Set up Omi.'), findsOneWidget);
    expect(
      find.text('By the way, if you bring your own keys, Omi becomes free.'),
      findsOneWidget,
    );
  });
}
