import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omi/features/mobile_update_check.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('compares versions component by component', () {
    expect(compareVersions('1.2.3', '1.2.3'), 0);
    expect(compareVersions('1.2.4', '1.2.3'), 1);
    expect(compareVersions('1.3.0', '1.2.9'), 1);
    expect(compareVersions('2.0.0', '1.9.9'), 1);
    expect(compareVersions('1.2.3', '1.10.0'), -1);
    // Build metadata and a leading v are not part of the comparison.
    expect(compareVersions('v1.2.0', '1.2.0+7'), 0);
    expect(compareVersions('1.2', '1.2.0'), 0);
    expect(compareVersions('1.2.1', '1.2'), 1);
  });

  test('reports the newest mobile release', () async {
    final release = await MobileUpdateChecker(
      currentVersion: '1.0.0',
      endpoint: 'https://example.test/releases',
      client: MockClient(
        (request) async => http.Response(
          jsonEncode([
            _release('mobile-v1.0.1'),
            // Desktop releases share the repository and must be ignored.
            _release('desktop-v9.9.9'),
            _release('mobile-v1.2.0'),
            _release('mobile-v1.3.0', draft: true),
            _release('mobile-v1.4.0', prerelease: true),
          ]),
          200,
        ),
      ),
    ).check();

    expect(release?.version, '1.2.0');
    expect(release?.url, 'https://example.test/mobile-v1.2.0');
  });

  test('stays quiet when the running build is current or newer', () async {
    Future<MobileRelease?> checkAgainst(String current) => MobileUpdateChecker(
      currentVersion: current,
      endpoint: 'https://example.test/releases',
      client: MockClient(
        (request) async =>
            http.Response(jsonEncode([_release('mobile-v1.2.0')]), 200),
      ),
    ).check();

    expect(await checkAgainst('1.2.0'), isNull);
    expect(await checkAgainst('1.3.0'), isNull);
  });

  test('degrades silently when the endpoint 404s', () async {
    final release = await MobileUpdateChecker(
      currentVersion: '1.0.0',
      endpoint: 'https://example.test/releases',
      client: MockClient((request) async => http.Response('not found', 404)),
    ).check();

    expect(release, isNull);
  });

  test('degrades silently when offline', () async {
    final release = await MobileUpdateChecker(
      currentVersion: '1.0.0',
      endpoint: 'https://example.test/releases',
      client: MockClient(
        (request) async => throw http.ClientException('offline'),
      ),
    ).check();

    expect(release, isNull);
  });

  test('degrades silently on malformed payloads', () async {
    for (final body in const ['not json', '{}', '[{"tag_name": 7}]', '[]']) {
      final release = await MobileUpdateChecker(
        currentVersion: '1.0.0',
        endpoint: 'https://example.test/releases',
        client: MockClient((request) async => http.Response(body, 200)),
      ).check();
      expect(release, isNull, reason: body);
    }
  });

  test(
    'a dismissed version stays dismissed until something newer ships',
    () async {
      MobileUpdateChecker checker(String latest) => MobileUpdateChecker(
        currentVersion: '1.0.0',
        endpoint: 'https://example.test/releases',
        client: MockClient(
          (request) async => http.Response(jsonEncode([_release(latest)]), 200),
        ),
      );

      final first = await checker('mobile-v1.2.0').check();
      expect(first, isNotNull);
      await checker('mobile-v1.2.0').dismiss(first!);

      expect(await checker('mobile-v1.2.0').check(), isNull);
      expect((await checker('mobile-v1.3.0').check())?.version, '1.3.0');
    },
  );

  test('an unusable endpoint never reaches the network', () async {
    var requests = 0;
    final release = await MobileUpdateChecker(
      currentVersion: '1.0.0',
      endpoint: 'not a url',
      client: MockClient((request) async {
        requests += 1;
        return http.Response('[]', 200);
      }),
    ).check();

    expect(release, isNull);
    expect(requests, 0);
  });
}

Map<String, Object?> _release(
  String tag, {
  bool draft = false,
  bool prerelease = false,
}) => {
  'tag_name': tag,
  'html_url': 'https://example.test/$tag',
  'draft': draft,
  'prerelease': prerelease,
};
