import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/capabilities/desktop_capabilities.dart';
import 'package:omi/features/setup_account_screens.dart';

void main() {
  testWidgets('screen setup requests and refreshes the real capability', (
    tester,
  ) async {
    final gateway = _Gateway();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScreenCaptureSetupTile(gateway: gateway, previewMode: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Needs access'), findsOneWidget);
    await tester.tap(find.byTooltip('Review screen-capture access'));
    await tester.pumpAndSettle();

    expect(gateway.requests, [CoreCapability.screenCapture]);
    expect(find.text('Granted'), findsOneWidget);
  });
}

final class _Gateway implements DesktopCapabilityGateway {
  final requests = <CoreCapability>[];

  @override
  Future<Map<CoreCapability, CapabilityStatus>> check() async => {
    CoreCapability.screenCapture: CapabilityStatus(
      state: requests.isEmpty
          ? CapabilityState.actionRequired
          : CapabilityState.granted,
      detail: requests.isEmpty ? 'Needs access' : 'Access verified',
    ),
  };

  @override
  Future<void> request(CoreCapability capability) async {
    requests.add(capability);
  }

  @override
  Future<void> requestInputMonitoring() async {}

  @override
  Future<void> dismissOverlay() async {}
}
