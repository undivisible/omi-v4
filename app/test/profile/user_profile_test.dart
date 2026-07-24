import 'package:flutter_test/flutter_test.dart';
import 'package:omi/profile/user_profile.dart';

void main() {
  test('user profile sidecar path replaces the database extension', () {
    expect(
      userProfileSidecarPath('/tmp/omi/user.sqlite3'),
      '/tmp/omi/user.user_profile.json',
    );
  });

  test('user profile document round-trips json', () {
    const document = UserProfileDocument(
      name: 'Alex',
      languages: ['English'],
      soul: {'Beliefs': 'Stay curious.'},
      customPrompt: 'Be direct.',
    );
    final restored = UserProfileDocument.fromJson(document.toJson());
    expect(restored.name, 'Alex');
    expect(restored.soul['Beliefs'], 'Stay curious.');
    expect(restored.customPrompt, 'Be direct.');
  });
}
