typedef SettingsJson = Map<String, Object?>;

enum ApprovalMode { ask, once, auto }

enum SettingsDuration { task, session, persistent }

final class SettingsFormatException implements Exception {
  const SettingsFormatException(this.message);

  final String message;

  @override
  String toString() => 'SettingsFormatException: $message';
}

final class AgentSettings {
  const AgentSettings({
    required this.approvalMode,
    required this.proactiveRecommendations,
  });

  final ApprovalMode approvalMode;
  final bool proactiveRecommendations;

  factory AgentSettings.fromJson(SettingsJson json) {
    _onlyKeys(json, const {'approvalMode', 'proactiveRecommendations'});
    return AgentSettings(
      approvalMode: _enumValue(
        ApprovalMode.values,
        _string(json, 'approvalMode'),
      ),
      proactiveRecommendations: _boolean(json, 'proactiveRecommendations'),
    );
  }

  SettingsJson toJson() => {
    'approvalMode': approvalMode.name,
    'proactiveRecommendations': proactiveRecommendations,
  };
}

final class SettingsPatch {
  const SettingsPatch({this.approvalMode, this.proactiveRecommendations});

  final ApprovalMode? approvalMode;
  final bool? proactiveRecommendations;

  bool get isEmpty => approvalMode == null && proactiveRecommendations == null;

  SettingsJson toJson() => {
    if (approvalMode case final value?) 'approvalMode': value.name,
    'proactiveRecommendations': ?proactiveRecommendations,
  };
}

final class SettingsScope {
  const SettingsScope._({required this.duration, this.scopeId, this.expiresAt});

  const SettingsScope.task(String taskId, {int? expiresAt})
    : this._(
        duration: SettingsDuration.task,
        scopeId: taskId,
        expiresAt: expiresAt,
      );

  const SettingsScope.session(String sessionId, {int? expiresAt})
    : this._(
        duration: SettingsDuration.session,
        scopeId: sessionId,
        expiresAt: expiresAt,
      );

  const SettingsScope.persistent()
    : this._(duration: SettingsDuration.persistent);

  final SettingsDuration duration;
  final String? scopeId;
  final int? expiresAt;

  SettingsJson toJson() {
    final id = scopeId;
    if (duration != SettingsDuration.persistent &&
        (id == null || id.trim().isEmpty)) {
      throw const SettingsFormatException('scope id must not be empty');
    }
    return {
      'duration': duration.name,
      if (duration == SettingsDuration.task) 'taskId': id,
      if (duration == SettingsDuration.session) 'sessionId': id,
      'expiresAt': ?expiresAt,
    };
  }
}

final class SettingChange<T> {
  const SettingChange({required this.from, required this.to});

  final T from;
  final T to;
}

final class SettingsDiff {
  const SettingsDiff({this.approvalMode, this.proactiveRecommendations});

  final SettingChange<ApprovalMode>? approvalMode;
  final SettingChange<bool>? proactiveRecommendations;

  bool get isEmpty => approvalMode == null && proactiveRecommendations == null;

  factory SettingsDiff.fromJson(SettingsJson json) {
    _onlyKeys(json, const {'approvalMode', 'proactiveRecommendations'});
    return SettingsDiff(
      approvalMode: _optionalChange(json, 'approvalMode', (value) {
        if (value is! String) {
          throw const SettingsFormatException('change value must be a string');
        }
        return _enumValue(ApprovalMode.values, value);
      }),
      proactiveRecommendations: _optionalChange(
        json,
        'proactiveRecommendations',
        (value) {
          if (value is! bool) {
            throw const SettingsFormatException('change value must be boolean');
          }
          return value;
        },
      ),
    );
  }
}

final class SettingsSnapshot {
  const SettingsSnapshot({
    required this.settings,
    required this.revision,
    required this.effectivePolicy,
  });

  final AgentSettings settings;
  final int revision;
  final AgentSettings effectivePolicy;

  factory SettingsSnapshot.fromJson(SettingsJson json) {
    _onlyKeys(json, const {'settings', 'revision', 'effectivePolicy'});
    return SettingsSnapshot(
      settings: AgentSettings.fromJson(_map(json, 'settings')),
      revision: _nonNegativeInteger(json, 'revision'),
      effectivePolicy: AgentSettings.fromJson(_map(json, 'effectivePolicy')),
    );
  }
}

final class SettingsChangeResult {
  const SettingsChangeResult({
    required this.settings,
    required this.revision,
    required this.duration,
    required this.diff,
    required this.effectivePolicy,
    required this.restartRequired,
    this.scopeId,
  });

  final AgentSettings settings;
  final int revision;
  final SettingsDuration duration;
  final String? scopeId;
  final SettingsDiff diff;
  final AgentSettings effectivePolicy;
  final bool restartRequired;

  factory SettingsChangeResult.fromJson(SettingsJson json) {
    _onlyKeys(json, const {
      'settings',
      'revision',
      'duration',
      'scopeId',
      'diff',
      'effectivePolicy',
      'restartRequired',
    });
    final duration = _enumValue(
      SettingsDuration.values,
      _string(json, 'duration'),
    );
    final scopeId = _optionalString(json, 'scopeId');
    if (duration != SettingsDuration.persistent && scopeId == null) {
      throw const SettingsFormatException('scoped result requires scopeId');
    }
    if (duration == SettingsDuration.persistent && scopeId != null) {
      throw const SettingsFormatException(
        'persistent result cannot have scopeId',
      );
    }
    return SettingsChangeResult(
      settings: AgentSettings.fromJson(_map(json, 'settings')),
      revision: _nonNegativeInteger(json, 'revision'),
      duration: duration,
      scopeId: scopeId,
      diff: SettingsDiff.fromJson(_map(json, 'diff')),
      effectivePolicy: AgentSettings.fromJson(_map(json, 'effectivePolicy')),
      restartRequired: _boolean(json, 'restartRequired'),
    );
  }
}

SettingChange<T>? _optionalChange<T>(
  SettingsJson json,
  String key,
  T Function(Object? value) decode,
) {
  final value = json[key];
  if (value == null) return null;
  if (value is! Map<String, Object?>) {
    throw SettingsFormatException('$key must be an object');
  }
  _onlyKeys(value, const {'from', 'to'});
  if (!value.containsKey('from') || !value.containsKey('to')) {
    throw SettingsFormatException('$key must include from and to');
  }
  return SettingChange(from: decode(value['from']), to: decode(value['to']));
}

SettingsJson _map(SettingsJson json, String key) {
  final value = json[key];
  if (value is! Map<String, Object?>) {
    throw SettingsFormatException('$key must be an object');
  }
  return value;
}

String _string(SettingsJson json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw SettingsFormatException('$key must be a non-empty string');
  }
  return value;
}

String? _optionalString(SettingsJson json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.isEmpty) {
    throw SettingsFormatException('$key must be a non-empty string');
  }
  return value;
}

bool _boolean(SettingsJson json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw SettingsFormatException('$key must be a boolean');
  }
  return value;
}

int _nonNegativeInteger(SettingsJson json, String key) {
  final value = json[key];
  if (value is! int || value < 0) {
    throw SettingsFormatException('$key must be a non-negative integer');
  }
  return value;
}

T _enumValue<T extends Enum>(Iterable<T> values, String wireValue) {
  for (final value in values) {
    if (value.name == wireValue) return value;
  }
  throw SettingsFormatException('unknown enum value: $wireValue');
}

void _onlyKeys(SettingsJson json, Set<String> allowed) {
  final unknown = json.keys.where((key) => !allowed.contains(key));
  if (unknown.isNotEmpty) {
    throw SettingsFormatException('unknown field: ${unknown.first}');
  }
}
