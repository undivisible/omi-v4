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

  test('opening chat message lists current prompt material', () {
    const document = UserProfileDocument(
      name: 'Ada',
      soul: {'Beliefs': 'Honesty over comfort.'},
    );
    final opening = openingProfileChatMessage(document);
    expect(opening, contains('About the user:'));
    expect(opening, contains("The user's name is Ada."));
    expect(opening, contains('User context — Beliefs:'));
    expect(opening, contains('Tell me what to change'));
  });

  test('profile patch parser applies soul and unset updates', () {
    const current = UserProfileDocument(
      name: 'Ada',
      soul: {'Beliefs': 'Old', 'Work': 'Keep'},
    );
    final patch = parseUserProfilePatch('''
Sure — updated Beliefs and cleared Work.

PROFILE_PATCH:
```json
{"soul":{"Beliefs":"Honesty first."},"unset":["Work"]}
```

Updated prompt:
About the user:
The user's name is Ada.
User context — Beliefs:
Honesty first.
''');
    expect(patch, isNotNull);
    final next = applyUserProfilePatch(current, patch!);
    expect(next.soul['Beliefs'], 'Honesty first.');
    expect(next.soul.containsKey('Work'), isFalse);
    expect(
      stripProfilePatchMarkup('''
Sure.

PROFILE_PATCH:
```json
{"soul":{"Beliefs":"x"}}
```
'''),
      'Sure.',
    );
  });
}
