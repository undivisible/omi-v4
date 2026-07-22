import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/omi_shell.dart';
import 'package:omi/keyboard/keyboard.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  testWidgets('both Shift keeps the single chat surface usable', (
    tester,
  ) async {
    final events = StreamController<DesktopKeyboardEvent>();
    final gesture = DesktopGestureController(events: events.stream);
    final services = AppServices.forTesting(
      nativeHub: const UnavailableNativeHub('test'),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      auth: AuthController(const UnconfiguredAuthGateway()),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: OmiShell(services: services, desktopGesture: gesture),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat_input')), findsOne);

    events.add(const DesktopShiftEvent(key: PhysicalShift.left, pressed: true));
    events.add(
      const DesktopShiftEvent(key: PhysicalShift.right, pressed: true),
    );
    events.add(
      const DesktopShiftEvent(key: PhysicalShift.left, pressed: false),
    );
    await tester.pump();
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat_input')), findsOne);
    await tester.pumpWidget(const SizedBox());
  });
}
