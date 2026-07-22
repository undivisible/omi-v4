import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/app_services.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/device/device.dart';
import 'package:omi/features/omi_shell.dart';
import 'package:omi/native/native_hub.dart';

void main() {
  AppServices makeServices() {
    return AppServices.forTesting(
      nativeHub: const UnavailableNativeHub('test'),
      deviceRelay: DeviceRelayService(
        role: DeviceRelayRole.desktopObserver,
        adapter: const UnavailableDeviceRelayAdapter(),
      ),
      auth: AuthController(const UnconfiguredAuthGateway()),
      memoryDatabasePath: (uid) => '/tmp/$uid.sqlite3',
    );
  }

  Future<void> pumpShell(
    WidgetTester tester,
    AppServices services, {
    required Brightness brightness,
    Size size = const Size(900, 700),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: OmiShell(services: services, previewMode: true),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
  }

  Color greetingColor(WidgetTester tester) {
    final text = tester.widget<Text>(find.byKey(const Key('hub_greeting')));
    return text.style!.color!;
  }

  Color hubBackground(WidgetTester tester) {
    final box = tester.widget<ColoredBox>(
      find.byKey(const Key('warm_paper_hub')),
    );
    return box.color;
  }

  testWidgets('chat opens in the warm paper hub', (tester) async {
    final services = makeServices();
    addTearDown(services.dispose);
    await pumpShell(tester, services, brightness: Brightness.light);

    expect(find.byKey(const Key('warm_paper_hub')), findsOneWidget);
    expect(find.byKey(const Key('hub_greeting')), findsOneWidget);
    expect(find.text('WHAT MATTERS NEXT'), findsOneWidget);
    expect(find.text('Set up Omi.'), findsOneWidget);
    expect(
      find.text('By the way, if you bring your own keys, Omi becomes free.'),
      findsOneWidget,
    );
    expect(hubBackground(tester), const Color(0xfff7f6f1));
    expect(greetingColor(tester), const Color(0xff171716));
  });

  testWidgets('hub adapts to dark mode with readable contrast', (tester) async {
    final services = makeServices();
    addTearDown(services.dispose);
    await pumpShell(tester, services, brightness: Brightness.dark);

    final background = hubBackground(tester);
    final ink = greetingColor(tester);
    expect(background, const Color(0xff1c1c1a));
    expect(ink, const Color(0xfff4f2ea));
    expect(
      ink.computeLuminance() - background.computeLuminance(),
      greaterThan(.5),
    );

    final input = tester.widget<Container>(
      find
          .ancestor(
            of: find.byKey(const Key('chat_input')),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = input.decoration! as BoxDecoration;
    expect(decoration.color, const Color(0xff232321));
    expect((decoration.border! as Border).top.color, const Color(0x1affffff));
  });

  for (final size in const [Size(1400, 900), Size(900, 700)]) {
    testWidgets('hub column is centered at ${size.width}x${size.height}', (
      tester,
    ) async {
      final services = makeServices();
      addTearDown(services.dispose);
      await pumpShell(
        tester,
        services,
        brightness: Brightness.light,
        size: size,
      );

      final greetingCenter = tester.getCenter(
        find.byKey(const Key('hub_greeting')),
      );
      expect(greetingCenter.dx, closeTo(size.width / 2, 1));

      final inputRect = tester.getRect(
        find
            .ancestor(
              of: find.byKey(const Key('chat_input')),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(inputRect.width, lessThanOrEqualTo(680));
      expect(
        (inputRect.left + inputRect.right) / 2,
        closeTo(size.width / 2, 1),
      );

      final hubRect = tester.getRect(find.byKey(const Key('warm_paper_hub')));
      final contentTop = tester
          .getRect(find.byKey(const Key('hub_greeting')))
          .top;
      final contentBottom = inputRect.bottom;
      final topGap = contentTop - hubRect.top;
      final bottomGap = hubRect.bottom - contentBottom;
      expect(topGap, greaterThan(0));
      expect(bottomGap, greaterThan(0));
      expect((topGap - bottomGap).abs(), lessThan(120));
    });
  }
}
