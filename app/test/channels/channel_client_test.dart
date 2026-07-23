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

  test('redeems a typed code and returns the bound channel', () async {
    final transport = _Transport(
      const ChannelResponse(
        statusCode: 201,
        body: {'channel': 'telegram', 'linked': true},
      ),
    );

    final channel = await ChannelClient(transport).redeemCode('K7QP2RM');

    expect(transport.lastRequest?.method, ChannelHttpMethod.post);
    expect(transport.lastRequest?.path, '/v1/channels/link');
    expect(transport.lastRequest?.body, {'code': 'K7QP2RM'});
    expect(channel, ChannelProvider.telegram);
  });

  test('a redemption error surfaces its status for the caller', () async {
    final client = ChannelClient(
      _Transport(
        const ChannelResponse(
          statusCode: 404,
          body: {'error': 'Unknown or expired code'},
        ),
      ),
    );

    await expectLater(
      client.redeemCode('K7QP2RM'),
      throwsA(
        isA<ChannelApiException>().having((e) => e.statusCode, 'status', 404),
      ),
    );
  });

  group('ChannelLinkCode.tryParse', () {
    test('accepts the code case-insensitively with separators', () {
      expect(ChannelLinkCode.tryParse('k7qp2rm'), 'K7QP2RM');
      expect(ChannelLinkCode.tryParse('K7Q-P2RM'), 'K7QP2RM');
      expect(ChannelLinkCode.tryParse(' K7QP2RM '), 'K7QP2RM');
    });

    test('rejects the ambiguous alphabet and wrong lengths', () {
      expect(ChannelLinkCode.tryParse('O0I1LAB'), isNull);
      expect(ChannelLinkCode.tryParse('K7QP2R'), isNull);
      expect(ChannelLinkCode.tryParse('hello there'), isNull);
    });
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
