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
    if (name case final value?) 'name': value,
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

Future<void> syncUserProfileToMemory({
  required MemoryClient memory,
  required UserProfileDocument document,
}) async {
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
}

String userProfileSidecarPath(String databasePath) {
  final separator = databasePath.lastIndexOf('.');
  final slash = databasePath.lastIndexOf('/');
  if (separator <= slash) return '$databasePath.user_profile.json';
  return '${databasePath.substring(0, separator)}.user_profile.json';
}
