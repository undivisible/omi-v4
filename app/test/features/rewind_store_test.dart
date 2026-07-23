import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/rewind/rewind_dhash.dart';
import 'package:omi/features/rewind/rewind_models.dart';
import 'package:omi/features/rewind/rewind_privacy.dart';
import 'package:omi/features/rewind/rewind_store.dart';

Uint8List _bytes(int length) =>
    Uint8List.fromList(List<int>.filled(length, 0x42));

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rewind_store_test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<RewindStore> open() async {
    final store = RewindStore(root);
    await store.load();
    return store;
  }

  test('writes a frame and reads it back from the index', () async {
    final store = await open();
    final at = DateTime(2026, 7, 23, 10);
    await store.write(
      jpeg: _bytes(64),
      capturedAt: at,
      hash: '0123456789abcdef',
      retention: const RewindRetention(),
      appName: 'Terminal',
      bundleId: 'com.apple.Terminal',
      windowTitle: 'zsh',
      ocrText: 'flutter analyze',
    );
    final reopened = RewindStore(root);
    await reopened.load();
    expect(reopened.frames, hasLength(1));
    expect(reopened.frames.single.ocrText, 'flutter analyze');
    expect(reopened.totalBytes, 64);
    expect(await reopened.fileFor(reopened.frames.single).exists(), isTrue);
  });

  test('evicts oldest first once the byte bound is exceeded', () async {
    final store = await open();
    const retention = RewindRetention(
      maxAge: Duration(days: 365),
      maxBytes: 200,
    );
    final base = DateTime(2026, 7, 23, 10);
    final paths = <String>[];
    for (var index = 0; index < 4; index++) {
      final frame = await store.write(
        jpeg: _bytes(100),
        capturedAt: base.add(Duration(minutes: index)),
        hash: '$index',
        retention: retention,
      );
      paths.add(store.fileFor(frame).path);
    }
    expect(store.frames, hasLength(2));
    expect(store.totalBytes, lessThanOrEqualTo(200));
    // Eviction is real deletion, not an index edit.
    expect(await File(paths.first).exists(), isFalse);
    expect(await File(paths.last).exists(), isTrue);
  });

  test('evicts anything older than the age bound', () async {
    final store = await open();
    const retention = RewindRetention(
      maxAge: Duration(days: 1),
      maxBytes: 1 << 30,
    );
    final now = DateTime(2026, 7, 23, 10);
    await store.write(
      jpeg: _bytes(10),
      capturedAt: now.subtract(const Duration(days: 3)),
      hash: 'old',
      retention: const RewindRetention(maxAge: Duration(days: 365)),
    );
    await store.write(
      jpeg: _bytes(10),
      capturedAt: now,
      hash: 'new',
      retention: retention,
    );
    expect(store.frames, hasLength(1));
    expect(store.frames.single.hash, 'new');
  });

  test('deleteAll removes every file and the index', () async {
    final store = await open();
    await store.write(
      jpeg: _bytes(10),
      capturedAt: DateTime(2026, 7, 23, 10),
      hash: 'a',
      retention: const RewindRetention(),
    );
    await store.deleteAll();
    expect(store.frames, isEmpty);
    expect(store.totalBytes, 0);
    expect(await store.framesDirectory.exists(), isFalse);
    expect(await store.indexFile.exists(), isFalse);
  });

  test('deleteRange forgets a window of time', () async {
    final store = await open();
    final base = DateTime(2026, 7, 23, 10);
    for (var index = 0; index < 3; index++) {
      await store.write(
        jpeg: _bytes(10),
        capturedAt: base.add(Duration(hours: index)),
        hash: '$index',
        retention: const RewindRetention(),
      );
    }
    final removed = await store.deleteRange(
      base.add(const Duration(minutes: 30)),
      base.add(const Duration(hours: 2, minutes: 30)),
    );
    expect(removed, 2);
    expect(store.frames, hasLength(1));
    expect(store.frames.single.hash, '0');
  });

  test('search reads the on-device text, newest first', () async {
    final store = await open();
    final base = DateTime(2026, 7, 23, 10);
    await store.write(
      jpeg: _bytes(10),
      capturedAt: base,
      hash: 'a',
      retention: const RewindRetention(),
      ocrText: 'deploy the worker',
    );
    await store.write(
      jpeg: _bytes(10),
      capturedAt: base.add(const Duration(minutes: 5)),
      hash: 'b',
      retention: const RewindRetention(),
      ocrText: 'DEPLOY failed',
    );
    final results = store.search('deploy');
    expect(results, hasLength(2));
    expect(results.first.hash, 'b');
    expect(store.search('nothing here'), isEmpty);
  });

  test('a corrupt index line is skipped rather than losing the rest', () async {
    final store = await open();
    await store.write(
      jpeg: _bytes(10),
      capturedAt: DateTime(2026, 7, 23, 10),
      hash: 'a',
      retention: const RewindRetention(),
    );
    await store.indexFile.writeAsString(
      'not json\n',
      mode: FileMode.append,
      flush: true,
    );
    final reopened = RewindStore(root);
    await reopened.load();
    expect(reopened.frames, hasLength(1));
  });

  test('the default exclusion list covers password managers', () {
    const privacy = RewindPrivacySettings();
    expect(
      privacy.denialFor(
        const RewindWindowContext(bundleId: 'com.1password.1password'),
      ),
      RewindSkipReason.deniedApp,
    );
    expect(
      privacy.denialFor(
        const RewindWindowContext(bundleId: 'org.keepassxc.keepassxc'),
      ),
      RewindSkipReason.deniedApp,
    );
    expect(
      privacy.denialFor(
        const RewindWindowContext(bundleId: 'com.apple.Terminal'),
      ),
      isNull,
    );
  });

  test('a user cannot silently lose the default exclusions', () {
    final restored = RewindPrivacySettings.fromJson({
      'deniedBundleIds': ['com.example.app'],
    });
    expect(restored.deniedBundleIds, contains('com.example.app'));
    expect(restored.deniedBundleIds, contains('com.1password.1password'));
  });

  test('the difference hash is stable, and sensitive to real change', () {
    final flat = Uint8List(kRewindPreviewLength);
    final ramp = Uint8List.fromList([
      for (var index = 0; index < kRewindPreviewLength; index++)
        (index * 37) % 251,
    ]);
    final a = RewindPreviewHash.fromLuma(flat)!;
    final b = RewindPreviewHash.fromLuma(flat)!;
    final c = RewindPreviewHash.fromLuma(ramp)!;
    expect(a.distanceTo(b), 0);
    expect(a.distanceTo(c), greaterThan(3));
    expect(RewindPreviewHash.tryParse(c.toHex()), c);
    expect(RewindPreviewHash.fromLuma(Uint8List(4)), isNull);
  });
}
