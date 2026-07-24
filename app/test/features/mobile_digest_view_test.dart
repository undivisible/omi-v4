import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/features/mobile_digest_view.dart';
import 'package:omi/memory/memory_models.dart';

MemoryDigest _digest({
  String id = 'd1',
  String localDate = '2026-07-24',
  DigestKind kind = DigestKind.daily,
  String body = '1. Call the plumber\n2. Ship the release\n3. Book the flight',
}) => MemoryDigest(id: id, localDate: localDate, kind: kind, body: body);

void main() {
  group('selectDigestForMoment', () {
    test('returns null when there are no digests', () {
      expect(selectDigestForMoment(const [], DateTime(2026, 7, 24, 9)), isNull);
    });

    test('prefers the daily brief in the morning', () {
      final chosen = selectDigestForMoment([
        _digest(kind: DigestKind.nightly),
        _digest(id: 'd2', kind: DigestKind.daily),
      ], DateTime(2026, 7, 24, 8));
      expect(chosen?.kind, DigestKind.daily);
    });

    test('prefers the nightly recap in the evening', () {
      final chosen = selectDigestForMoment([
        _digest(kind: DigestKind.daily),
        _digest(id: 'd2', kind: DigestKind.nightly),
      ], DateTime(2026, 7, 24, 21));
      expect(chosen?.kind, DigestKind.nightly);
    });

    test('picks the most recent local date', () {
      final chosen = selectDigestForMoment([
        _digest(id: 'old', localDate: '2026-07-20'),
        _digest(id: 'new', localDate: '2026-07-24'),
      ], DateTime(2026, 7, 24, 9));
      expect(chosen?.id, 'new');
    });

    test('falls back to the other kind when the preferred is absent', () {
      final chosen = selectDigestForMoment([
        _digest(kind: DigestKind.nightly),
      ], DateTime(2026, 7, 24, 8));
      expect(chosen?.kind, DigestKind.nightly);
    });
  });

  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('the base tile renders a recap card', (tester) async {
    await tester.pumpWidget(host(MobileDigestTile(digest: _digest())));
    expect(find.byKey(const Key('companion_digest_tile')), findsOneWidget);
    expect(find.text('Your day'), findsOneWidget);
  });

  testWidgets('tapping the tile opens the paged view', (tester) async {
    await tester.pumpWidget(host(MobileDigestTile(digest: _digest())));
    await tester.tap(find.byKey(const Key('companion_digest_tile_open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('companion_digest_view')), findsOneWidget);
    expect(find.byKey(const Key('companion_digest_pages')), findsOneWidget);
    // Hero standout comes from the first parsed item, enumerator stripped.
    expect(find.text('Call the plumber'), findsOneWidget);
  });

  testWidgets('the paged view closes', (tester) async {
    await tester.pumpWidget(host(MobileDigestView(digest: _digest())));
    expect(find.byKey(const Key('companion_digest_view')), findsOneWidget);
    await tester.tap(find.byKey(const Key('companion_digest_close')));
    await tester.pumpAndSettle();
  });

  testWidgets('degrades to a subtitle when the body has no items', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(MobileDigestTile(digest: _digest(body: '   '))),
    );
    expect(find.text("Here's what you need to do."), findsOneWidget);
  });
}
