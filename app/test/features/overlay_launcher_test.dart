import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/overlay_launcher.dart';

void main() {
  test('bare open/launch phrases resolve to an app intent', () {
    for (final (phrase, query) in [
      ('open chrome', 'chrome'),
      ('launch spotify', 'spotify'),
      ('Open Google Chrome', 'Google Chrome'),
      ('open safari.', 'safari'),
      ('  launch   Visual Studio Code  ', 'Visual Studio Code'),
      ('open mail', 'mail'),
      ('OPEN FINDER', 'FINDER'),
    ]) {
      final intent = parseLauncherIntent(phrase);
      expect(
        intent,
        isA<LaunchAppIntent>(),
        reason: 'expected "$phrase" to be an app launch',
      );
      expect((intent! as LaunchAppIntent).query, query);
    }
  });

  test('URLs resolve to an open-url intent', () {
    for (final (phrase, url) in [
      ('open github.com', 'https://github.com'),
      ('github.com', 'https://github.com'),
      ('open https://example.com/a/b', 'https://example.com/a/b'),
      ('https://example.com', 'https://example.com'),
      ('launch docs.flutter.dev/testing', 'https://docs.flutter.dev/testing'),
    ]) {
      final intent = parseLauncherIntent(phrase);
      expect(
        intent,
        isA<OpenUrlIntent>(),
        reason: 'expected "$phrase" to be a URL open',
      );
      expect((intent! as OpenUrlIntent).url, Uri.parse(url));
    }
  });

  test('the URL display label is the host', () {
    final intent = parseLauncherIntent('open github.com/omi/omi');
    expect((intent! as OpenUrlIntent).display, 'github.com');
  });

  test('sentence-like input falls through to the agent', () {
    for (final phrase in [
      '',
      '   ',
      'open my tasks',
      'open the file I was editing yesterday',
      'launch a review of my inbox',
      'open chrome and search for flights',
      'what should I do today?',
      'openchrome',
      'open',
      'launch',
      'summarize github.com for me',
      'open one two three four',
      'email sam@example.com about the launch',
    ]) {
      expect(
        parseLauncherIntent(phrase),
        isNull,
        reason: 'expected "$phrase" to fall through',
      );
    }
  });
}
