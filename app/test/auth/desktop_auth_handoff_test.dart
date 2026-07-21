import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/auth/auth.dart';

void main() {
  test(
    'desktop handoff opens browser and exchanges only after completion',
    () async {
      var requests = 0;
      Uri? opened;
      final handoff = DesktopAuthHandoff(
        apiOrigin: Uri.parse('https://api.example.test'),
        appOrigin: Uri.parse('https://app.example.test'),
        launchBrowser: (uri) async {
          opened = uri;
          return true;
        },
        clientFactory: () => MockClient((request) async {
          requests += 1;
          final body = jsonDecode(request.body) as Map<String, Object?>;
          expect(body['sessionId'], isA<String>());
          if (request.url.path.endsWith('/start')) {
            expect(body['challenge'], isA<String>());
            expect(body['confirmationChallenge'], isA<String>());
            return http.Response(
              jsonEncode({
                'browserUrl': 'https://app.example.test/?desktop_auth=session',
              }),
              201,
            );
          }
          expect(body['verifier'], isA<String>());
          return requests == 2
              ? http.Response(jsonEncode({'status': 'pending'}), 409)
              : http.Response(
                  jsonEncode({'customToken': 'firebase-custom'}),
                  200,
                );
        }),
        pollInterval: Duration.zero,
      );

      String? code;
      final credential = await handoff.authenticate(
        onConfirmationCode: (value) => code = value,
      );
      expect(credential.customToken, 'firebase-custom');
      expect(handoff.isCurrent(credential), isTrue);
      expect(code, matches(RegExp(r'^\d{6}$')));
      expect(
        opened,
        Uri.parse('https://app.example.test/?desktop_auth=session'),
      );
      expect(requests, 3);
    },
  );

  test('desktop handoff fails closed when the browser cannot open', () async {
    final handoff = DesktopAuthHandoff(
      apiOrigin: Uri.parse('https://api.example.test'),
      appOrigin: Uri.parse('https://app.example.test'),
      launchBrowser: (_) async => false,
      clientFactory: () => MockClient(
        (_) async => http.Response(
          jsonEncode({'browserUrl': 'https://app.example.test'}),
          201,
        ),
      ),
    );

    await expectLater(
      handoff.authenticate(onConfirmationCode: (_) {}),
      throwsA(
        isA<AuthOperationException>().having(
          (error) => error.failure.code,
          'code',
          AuthErrorCode.cancelled,
        ),
      ),
    );
  });

  test('cancellation wins over a delayed successful exchange', () async {
    final exchangeStarted = Completer<void>();
    final exchangeResponse = Completer<http.Response>();
    final handoff = DesktopAuthHandoff(
      apiOrigin: Uri.parse('https://api.example.test'),
      appOrigin: Uri.parse('https://app.example.test'),
      launchBrowser: (_) async => true,
      clientFactory: () => MockClient((request) async {
        if (request.url.path.endsWith('/start')) {
          return http.Response(
            jsonEncode({'browserUrl': 'https://app.example.test'}),
            201,
          );
        }
        exchangeStarted.complete();
        return exchangeResponse.future;
      }),
      pollInterval: Duration.zero,
    );

    final authentication = handoff.authenticate(onConfirmationCode: (_) {});
    await exchangeStarted.future;
    handoff.cancel();
    exchangeResponse.complete(
      http.Response(jsonEncode({'customToken': 'too-late'}), 200),
    );

    await expectLater(
      authentication,
      throwsA(
        isA<AuthOperationException>().having(
          (error) => error.failure.code,
          'code',
          AuthErrorCode.cancelled,
        ),
      ),
    );
  });
}
