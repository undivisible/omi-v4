import 'package:flutter_test/flutter_test.dart';
import 'package:omi/currents/crepus_url_policy.dart';

void main() {
  test('rejects private http hosts for open actions', () {
    expect(
      isPublicHttpUri(Uri.parse('http://127.0.0.1/admin')),
      isFalse,
    );
    expect(
      isPublicHttpUri(Uri.parse('http://192.168.1.1/')),
      isFalse,
    );
    expect(
      isPublicHttpUri(Uri.parse('https://example.com/path')),
      isTrue,
    );
  });
}
