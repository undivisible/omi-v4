import 'package:flutter_test/flutter_test.dart';
import 'package:omi/channels/channels.dart';

void main() {
  test('requests a short-lived Telegram link token', () async {
    final transport = _Transport(
      const ChannelResponse(
        statusCode: 201,
        body: {
          'channel': 'telegram',
          'token': 'one-time-token',
          'expiresAt': 2000,
        },
      ),
    );

    final token = await ChannelClient(
      transport,
    ).requestLink(ChannelProvider.telegram);

    expect(transport.lastRequest?.method, ChannelHttpMethod.post);
    expect(transport.lastRequest?.path, '/v1/channels/telegram/link');
    expect(token.token, 'one-time-token');
    expect(
      token.isExpiredAt(DateTime.fromMillisecondsSinceEpoch(1999)),
      isFalse,
    );
    expect(
      token.isExpiredAt(DateTime.fromMillisecondsSinceEpoch(2000)),
      isTrue,
    );
  });

  test('linked status discards provider identifiers', () async {
    final client = ChannelClient(
      _Transport(
        const ChannelResponse(
          statusCode: 200,
          body: {
            'uid': 'firebase-user',
            'channels': [
              {'channel': 'blooio', 'channel_user_id': '+15555550100'},
            ],
          },
        ),
      ),
    );

    expect(await client.isLinked(ChannelProvider.blooio), isTrue);
    expect(await client.isLinked(ChannelProvider.telegram), isFalse);
  });

  test('rejects malformed and mismatched responses', () async {
    final missingExpiry = ChannelClient(
      _Transport(
        const ChannelResponse(
          statusCode: 201,
          body: {'channel': 'telegram', 'token': 'token'},
        ),
      ),
    );
    final mismatch = ChannelClient(
      _Transport(
        const ChannelResponse(
          statusCode: 201,
          body: {'channel': 'blooio', 'token': 'token', 'expiresAt': 2000},
        ),
      ),
    );

    await expectLater(
      missingExpiry.requestLink(ChannelProvider.telegram),
      throwsA(isA<ChannelDecodingException>()),
    );
    await expectLater(
      mismatch.requestLink(ChannelProvider.telegram),
      throwsA(isA<ChannelDecodingException>()),
    );
  });

  test('unlink uses the authenticated provider route', () async {
    final transport = _Transport(const ChannelResponse(statusCode: 204));

    await ChannelClient(transport).unlink(ChannelProvider.blooio);

    expect(transport.lastRequest?.method, ChannelHttpMethod.delete);
    expect(transport.lastRequest?.path, '/v1/channels/blooio/link');
  });

  test('failure state can retry without pretending the channel linked', () {
    const state = ChannelLinkState.failed('Link expired');

    expect(state.phase, ChannelLinkPhase.failed);
    expect(state.canRetry, isTrue);
    expect(state.error, 'Link expired');
  });
}

final class _Transport implements AuthenticatedChannelTransport {
  _Transport(this.response);

  final ChannelResponse response;
  ChannelRequest? lastRequest;

  @override
  Future<ChannelResponse> sendAuthenticated(ChannelRequest request) async {
    lastRequest = request;
    return response;
  }
}
