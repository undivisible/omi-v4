import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../memory/memory_client.dart';

const userProfileSoulSections = [
  'Identity',
  'Goals',
  'Work',
  'Preferences',
  'Routines',
  'Beliefs',
  'Constraints',
  'People',
  'Health',
  'Context',
];

const _stableSoulSections = {
  'Identity',
  'Goals',
  'Preferences',
  'Beliefs',
  'Constraints',
};

final class UserProfileDocument {
  const UserProfileDocument({
    this.name,
    this.languages = const [],
    this.soul = const {},
    this.customPrompt = '',
  });

  final String? name;
  final List<String> languages;
  final Map<String, String> soul;
  final String customPrompt;

  UserProfileDocument copyWith({
    String? name,
    List<String>? languages,
    Map<String, String>? soul,
    String? customPrompt,
  }) => UserProfileDocument(
    name: name ?? this.name,
    languages: languages ?? this.languages,
    soul: soul ?? this.soul,
    customPrompt: customPrompt ?? this.customPrompt,
  );

  factory UserProfileDocument.fromJson(Map<String, Object?> json) {
    final soulRaw = json['soul'];
    final soul = <String, String>{};
    if (soulRaw is Map) {
      for (final entry in soulRaw.entries) {
        if (entry.key is String && entry.value is String) {
          soul[entry.key as String] = entry.value as String;
        }
      }
    }
    final languagesRaw = json['languages'];
    final languages = languagesRaw is List
        ? [
            for (final value in languagesRaw)
              if (value is String && value.trim().isNotEmpty) value.trim(),
          ]
        : const <String>[];
    return UserProfileDocument(
      name: json['name'] is String ? (json['name'] as String).trim() : null,
      languages: languages,
      soul: soul,
      customPrompt: json['customPrompt'] is String
          ? json['customPrompt'] as String
          : '',
    );
  }

  Map<String, Object?> toJson() => {
    'name': ?name,
    'languages': languages,
    'soul': soul,
    if (customPrompt.trim().isNotEmpty) 'customPrompt': customPrompt.trim(),
  };

  bool get isEmpty =>
      (name == null || name!.trim().isEmpty) &&
      languages.isEmpty &&
      soul.values.every((value) => value.trim().isEmpty) &&
      customPrompt.trim().isEmpty;
}

/// Patch applied from a profile-editor assistant turn.
final class UserProfilePatch {
  const UserProfilePatch({
    this.name,
    this.languages,
    this.soul = const {},
    this.customPrompt,
    this.unset = const [],
  });

  final String? name;
  final List<String>? languages;
  final Map<String, String> soul;
  final String? customPrompt;
  final List<String> unset;

  bool get isEmpty =>
      name == null &&
      languages == null &&
      soul.isEmpty &&
      customPrompt == null &&
      unset.isEmpty;
}

abstract interface class UserProfileStore {
  Future<UserProfileDocument> load(String uid);
  Future<void> save(String uid, UserProfileDocument document);
  Future<void> writeSidecar(String databasePath, UserProfileDocument document);
}

final class PreferencesUserProfileStore implements UserProfileStore {
  static String _prefsKey(String uid) => 'user-profile-v1-$uid';

  @override
  Future<UserProfileDocument> load(String uid) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      _prefsKey(uid),
    );
    if (raw == null) return const UserProfileDocument();
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return const UserProfileDocument();
      return UserProfileDocument.fromJson(json);
    } on FormatException {
      return const UserProfileDocument();
    }
  }

  @override
  Future<void> save(String uid, UserProfileDocument document) async {
    final saved = await (await SharedPreferences.getInstance()).setString(
      _prefsKey(uid),
      jsonEncode(document.toJson()),
    );
    if (!saved) throw StateError('Could not persist user profile');
  }

  @override
  Future<void> writeSidecar(
    String databasePath,
    UserProfileDocument document,
  ) async {
    final path = userProfileSidecarPath(databasePath);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(document.toJson()));
  }
}

String formatAboutUser(UserProfileDocument document) {
  final facts = <String>[];
  final name = document.name?.trim();
  if (name != null && name.isNotEmpty) {
    facts.add("The user's name is $name.");
  }
  if (document.languages.isNotEmpty) {
    facts.add(
      "The user's preferred languages: ${document.languages.join(', ')}.",
    );
  }
  for (final section in userProfileSoulSections) {
    final text = document.soul[section]?.trim() ?? '';
    if (text.isEmpty) continue;
    facts.add('User context — $section:\n$text');
  }
  if (facts.isEmpty) {
    return 'About the user:\n(nothing saved yet)';
  }
  return 'About the user:\n${facts.join('\n')}';
}

/// Full inventory for the settings chat opener — every soul section, even empty.
String formatProfileChatInventory(UserProfileDocument document) {
  final lines = <String>['About the user:'];
  final name = document.name?.trim();
  lines.add(name == null || name.isEmpty ? 'Name: (not set)' : "Name: $name");
  lines.add(
    document.languages.isEmpty
        ? 'Languages: (not set)'
        : 'Languages: ${document.languages.join(', ')}',
  );
  for (final section in userProfileSoulSections) {
    final text = document.soul[section]?.trim() ?? '';
    lines.add(text.isEmpty ? '$section: (empty)' : '$section:\n$text');
  }
  final custom = document.customPrompt.trim();
  lines.add(
    custom.isEmpty
        ? 'Standing instructions: (none)'
        : 'Standing instructions:\n$custom',
  );
  return lines.join('\n');
}

String formatPromptPreview(UserProfileDocument document) {
  final parts = <String>[formatAboutUser(document)];
  final custom = document.customPrompt.trim();
  if (custom.isNotEmpty) parts.add(custom);
  return parts.join('\n\n');
}

String openingProfileChatMessage(UserProfileDocument document) {
  final buffer = StringBuffer()
    ..writeln("Here's everything I currently keep about you for prompts.")
    ..writeln()
    ..writeln(formatProfileChatInventory(document))
    ..writeln()
    ..write(
      'Tell me what to change — any section above, your name, languages, '
      'or standing instructions — and I will update it and show you the '
      'new prompt.',
    );
  return buffer.toString();
}

UserProfileDocument applyUserProfilePatch(
  UserProfileDocument current,
  UserProfilePatch patch,
) {
  final soul = Map<String, String>.from(current.soul);
  for (final key in patch.unset) {
    if (key == 'name' || key == 'languages' || key == 'customPrompt') continue;
    soul.remove(key);
  }
  for (final entry in patch.soul.entries) {
    final trimmed = entry.value.trim();
    if (trimmed.isEmpty) {
      soul.remove(entry.key);
    } else {
      soul[entry.key] = trimmed;
    }
  }
  var name = current.name;
  if (patch.unset.contains('name')) {
    name = null;
  } else if (patch.name != null) {
    final trimmed = patch.name!.trim();
    name = trimmed.isEmpty ? null : trimmed;
  }
  var languages = current.languages;
  if (patch.unset.contains('languages')) {
    languages = const [];
  } else if (patch.languages != null) {
    languages = [
      for (final value in patch.languages!)
        if (value.trim().isNotEmpty) value.trim(),
    ];
  }
  var customPrompt = current.customPrompt;
  if (patch.unset.contains('customPrompt')) {
    customPrompt = '';
  } else if (patch.customPrompt != null) {
    customPrompt = patch.customPrompt!.trim();
  }
  return UserProfileDocument(
    name: name,
    languages: languages,
    soul: soul,
    customPrompt: customPrompt,
  );
}

UserProfilePatch? parseUserProfilePatch(String reply) {
  final match = RegExp(
    r'PROFILE_PATCH\s*:\s*```(?:json)?\s*([\s\S]*?)```',
    caseSensitive: false,
  ).firstMatch(reply);
  final raw = match?.group(1)?.trim();
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) return null;
    final soulRaw = decoded['soul'];
    final soul = <String, String>{};
    if (soulRaw is Map) {
      for (final entry in soulRaw.entries) {
        if (entry.key is! String || entry.value is! String) continue;
        final key = entry.key as String;
        if (!userProfileSoulSections.contains(key)) continue;
        soul[key] = entry.value as String;
      }
    }
    final languagesRaw = decoded['languages'];
    List<String>? languages;
    if (languagesRaw is List) {
      languages = [
        for (final value in languagesRaw)
          if (value is String && value.trim().isNotEmpty) value.trim(),
      ];
    }
    final unsetRaw = decoded['unset'];
    final unset = unsetRaw is List
        ? [
            for (final value in unsetRaw)
              if (value is String && value.trim().isNotEmpty) value.trim(),
          ]
        : const <String>[];
    final patch = UserProfilePatch(
      name: decoded['name'] is String ? decoded['name'] as String : null,
      languages: languages,
      soul: soul,
      customPrompt: decoded['customPrompt'] is String
          ? decoded['customPrompt'] as String
          : null,
      unset: unset,
    );
    return patch.isEmpty ? null : patch;
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}

String stripProfilePatchMarkup(String reply) {
  return reply
      .replaceAll(
        RegExp(
          r'PROFILE_PATCH\s*:\s*```(?:json)?\s*[\s\S]*?```',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
}

String profileEditorFraming(UserProfileDocument document) {
  return '''
You are editing the user's personal context for Omi assistant prompts.
Current prompt material:
${formatPromptPreview(document)}

Sections you may update: ${userProfileSoulSections.join(', ')}, plus name, languages, and customPrompt.
When the user asks for a change, reply briefly, then emit exactly one patch block:

PROFILE_PATCH:
```json
{"name":"...","languages":["..."],"soul":{"Beliefs":"..."},"customPrompt":"...","unset":["Work"]}
```

Rules:
- Only include fields that change.
- Use soul keys exactly as listed above.
- Put section names to clear in "unset".
- After the patch, quote the updated About-the-user prompt the user should see.
- If nothing should change, do not emit PROFILE_PATCH.
''';
}

Future<void> syncUserProfileToMemory({
  required MemoryClient memory,
  required UserProfileDocument document,
}) async {
  final name = document.name?.trim();
  if (name != null && name.isNotEmpty) {
    await memory.createProfileMemory(
      content: name,
      profileKey: 'name',
      profileKind: 'stable',
      predicate: 'name',
    );
  }
  if (document.languages.isNotEmpty) {
    await memory.createProfileMemory(
      content: document.languages.join(', '),
      profileKey: 'languages',
      profileKind: 'stable',
      predicate: 'languages',
    );
  }
  for (final section in userProfileSoulSections) {
    final content = document.soul[section]?.trim() ?? '';
    if (content.isEmpty) continue;
    await memory.createProfileMemory(
      content: content,
      profileKey: section,
      profileKind: _stableSoulSections.contains(section) ? 'stable' : 'current',
      predicate: section.toLowerCase(),
    );
  }
  final custom = document.customPrompt.trim();
  if (custom.isNotEmpty) {
    await memory.createProfileMemory(
      content: custom,
      profileKey: 'customPrompt',
      profileKind: 'stable',
      predicate: 'custom_prompt',
    );
  }
}

String userProfileSidecarPath(String databasePath) {
  final separator = databasePath.lastIndexOf('.');
  final slash = databasePath.lastIndexOf('/');
  if (separator <= slash) return '$databasePath.user_profile.json';
  return '${databasePath.substring(0, separator)}.user_profile.json';
}
