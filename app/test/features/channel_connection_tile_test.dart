import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/channels/channels.dart';
import 'package:omi/features/setup_account_screens.dart';

void main() {
  testWidgets('rechecks Telegram after external linking and clears the code', (
    tester,
  ) async {
    final transport = _LinkTransport(ChannelProvider.telegram);
    await tester.pumpWidget(_tile(transport, ChannelProvider.telegram));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Connect Telegram'));
    await tester.pumpAndSettle();
    expect(find.text('Link code: link-code'), findsOneWidget);

    transport.linked = true;
    await tester.tap(find.byTooltip('Check Telegram connection'));
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsNWidgets(2));
    expect(find.textContaining('link-code'), findsNothing);
    expect(transport.statusChecks, 2);
  });

  testWidgets('unsuccessful Blooio recheck clears the obsolete code', (
    tester,
  ) async {
    final transport = _LinkTransport(ChannelProvider.blooio);
    await tester.pumpWidget(_tile(transport, ChannelProvider.blooio));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Connect Blooio'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Check Blooio connection'));
    await tester.pumpAndSettle();

    expect(find.textContaining('link-code'), findsNothing);
    expect(find.byTooltip('Connect Blooio'), findsOneWidget);
    expect(find.text('Use the same assistant from any device'), findsOneWidget);
    expect(transport.statusChecks, 2);
  });
}

Widget _tile(_LinkTransport transport, ChannelProvider provider) => MaterialApp(
  home: Scaffold(
    body: ChannelConnectionTile(
      client: ChannelClient(transport),
      provider: provider,
      previewMode: false,
      unavailableMessage: 'Unavailable',
    ),
  ),
);

final class _LinkTransport implements AuthenticatedChannelTransport {
  _LinkTransport(this.provider);

  final ChannelProvider provider;
  bool linked = false;
  int statusChecks = 0;

  @override
  Future<ChannelResponse> sendAuthenticated(ChannelRequest request) async {
    if (request.method == ChannelHttpMethod.get) {
      statusChecks += 1;
      return ChannelResponse(
        statusCode: 200,
        body: {
          'channels': linked
              ? [
                  {'channel': provider.name},
                ]
              : <Object?>[],
        },
      );
    }
    return ChannelResponse(
      statusCode: 201,
      body: {
        'channel': provider.name,
        'token': 'link-code',
        'expiresAt': DateTime.now()
            .add(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
      },
    );
  }
}
