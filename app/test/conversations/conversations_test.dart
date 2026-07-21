import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/api/worker_http.dart';
import 'package:omi/auth/auth.dart';
import 'package:omi/conversations/conversations.dart';

void main() {
  test('claims and completes a channel inbox lease', () async {
    final requests = <http.Request>[];
    final client = WorkerHttpClient(
      baseUri: Uri.parse('https://api.example.test'),
      sessionProvider: () async => AuthSession(
        uid: 'alpha',
        idToken: 'token',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      ),
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/claim')) {
          return http.Response(
            jsonEncode({
              'item': {
                'id': 'inbox-message-1',
                'channel': 'telegram',
                'text': 'Hello',
                'channelMessageId': 'provider-message-1',
                'receivedAt': 1,
                'attempt': 1,
                'leaseToken': 'lease-token-1',
                'leaseUntil': 300001,
              },
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'status': 'done'}), 200);
      }),
    );
    final transport = WorkerConversationTransport(client);

    final item = await transport.claim();
    await transport.complete(
      item!,
      outcome: ConversationInboxOutcome.done,
      responseText: 'Hi back',
    );

    expect(requests, hasLength(2));
    expect(requests.first.method, 'POST');
    expect(requests.last.method, 'POST');
    expect(jsonDecode(requests.last.body), {
      'leaseToken': 'lease-token-1',
      'outcome': 'done',
      'responseText': 'Hi back',
    });
    client.close();
  });

  test('replays every ordered conversation page', () async {
    final requestedAfter = <String?>[];
    final client = WorkerHttpClient(
      baseUri: Uri.parse('https://api.example.test'),
      sessionProvider: () async => AuthSession(
        uid: 'alpha',
        idToken: 'token',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      ),
      client: MockClient((request) async {
        requestedAfter.add(request.url.queryParameters['after']);
        final after = int.parse(request.url.queryParameters['after']!);
        final count = after == 0 ? 200 : 1;
        final messages = List.generate(count, (index) {
          final cursor = after + index + 1;
          return {
            'cursor': cursor,
            'clientMessageId': 'message-$cursor',
            'role': 'user',
            'source': 'app',
            'text': 'message $cursor',
            'createdAt': cursor,
          };
        });
        return http.Response(
          jsonEncode({
            'conversationId': 'default',
            'messages': messages,
            'nextCursor': after + count,
          }),
          200,
        );
      }),
    );

    final messages = await WorkerConversationTransport(client).replay(after: 0);

    expect(messages, hasLength(201));
    expect(messages.last.cursor, 201);
    expect(requestedAfter, ['0', '200']);
    client.close();
  });
}
