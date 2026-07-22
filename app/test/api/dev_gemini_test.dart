import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/api/dev_gemini.dart';

void main() {
  late Directory temp;
  late String home;
  late String repo;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('dev-gemini-test');
    home = '${temp.path}/home';
    repo = '${temp.path}/repo';
    Directory(home).createSync(recursive: true);
    Directory('$repo/worker').createSync(recursive: true);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Map<String, String> environment([String? key]) => {
    'HOME': home,
    'GEMINI_API_KEY': ?key,
  };

  void writeKey(String path, String key) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync('GEMINI_API_KEY=$key\n');

  test('environment variable wins over all files', () {
    writeKey('$home/.config/omi/dev.env', 'AIzaConfig');
    expect(
      DevGemini.resolve(
        environment: environment('AIzaEnv'),
        workingDirectory: repo,
        persist: false,
      ),
      'AIzaEnv',
    );
  });

  test('resolution order is config, stable app dir, then worker files', () {
    final stable = DevGemini.persistPath(environment())!;
    writeKey('$repo/worker/.dev.vars', 'AIzaWorker');
    expect(
      DevGemini.resolve(
        environment: environment(),
        workingDirectory: repo,
        persist: false,
      ),
      'AIzaWorker',
    );
    writeKey(stable, 'AIzaStable');
    expect(
      DevGemini.resolve(
        environment: environment(),
        workingDirectory: repo,
        persist: false,
      ),
      'AIzaStable',
    );
    writeKey('$home/.config/omi/dev.env', 'AIzaConfig');
    expect(
      DevGemini.resolve(
        environment: environment(),
        workingDirectory: repo,
        persist: false,
      ),
      'AIzaConfig',
    );
  });

  test(
    'a key found in the repo worker file is persisted to the stable '
    'per-user location so Finder launches (cwd=/, empty env) still find it',
    () {
      writeKey('$repo/worker/.dev.vars', 'AIzaWorker');
      expect(
        DevGemini.resolve(environment: environment(), workingDirectory: repo),
        'AIzaWorker',
      );
      final stable = DevGemini.persistPath(environment())!;
      expect(File(stable).readAsStringSync(), 'GEMINI_API_KEY=AIzaWorker\n');
      expect(
        DevGemini.resolve(
          environment: environment(),
          workingDirectory: '${temp.path}/nowhere',
        ),
        'AIzaWorker',
      );
    },
  );

  test('placeholder or malformed keys are rejected and never persisted', () {
    writeKey('$repo/worker/.dev.vars', 'your-gemini-api-key-here');
    expect(
      DevGemini.resolve(environment: environment(), workingDirectory: repo),
      isNull,
    );
    expect(File(DevGemini.persistPath(environment())!).existsSync(), isFalse);
  });

  test('quoted values are unwrapped', () {
    File('$repo/worker/.dev.vars')
      ..createSync(recursive: true)
      ..writeAsStringSync('# comment\nOTHER=1\nGEMINI_API_KEY="AIzaQuoted"\n');
    expect(
      DevGemini.resolve(
        environment: environment(),
        workingDirectory: repo,
        persist: false,
      ),
      'AIzaQuoted',
    );
  });

  test('missingKeyHint names the checked locations without key material', () {
    final hint = DevGemini.missingKeyHint;
    expect(hint, contains('GEMINI_API_KEY'));
    expect(hint, contains('dev.env'));
    expect(hint, contains('worker/.dev.vars'));
  });
}
