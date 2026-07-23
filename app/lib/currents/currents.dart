export 'currents_client.dart';
export 'currents_controller.dart';
export 'worker_currents_transport.dart';

enum CurrentStatus {
  candidate,
  surfaced,
  accepted,
  snoozed,
  dismissed,
  completed,
  expired,
}

class CurrentEvidence {
  CurrentEvidence({required this.sourceId, required this.reason}) {
    _requireText(sourceId, 'sourceId');
    _requireText(reason, 'reason');
  }

  factory CurrentEvidence.fromJson(Map<String, Object?> json) =>
      CurrentEvidence(
        sourceId: _string(json, 'sourceId'),
        reason: _string(json, 'reason'),
      );

  final String sourceId;
  final String reason;

  Map<String, Object?> toJson() => {'sourceId': sourceId, 'reason': reason};
}

class CurrentTiming {
  CurrentTiming({required this.surfaceAt, this.expiresAt, this.snoozedUntil}) {
    if (expiresAt != null && !expiresAt!.isAfter(surfaceAt)) {
      throw ArgumentError.value(
        expiresAt,
        'expiresAt',
        'must be after surfaceAt',
      );
    }
    if (snoozedUntil != null && !snoozedUntil!.isAfter(surfaceAt)) {
      throw ArgumentError.value(
        snoozedUntil,
        'snoozedUntil',
        'must be after surfaceAt',
      );
    }
  }

  factory CurrentTiming.fromJson(Map<String, Object?> json) => CurrentTiming(
    surfaceAt: _dateTime(json, 'surfaceAt'),
    expiresAt: _optionalDateTime(json, 'expiresAt'),
    snoozedUntil: _optionalDateTime(json, 'snoozedUntil'),
  );

  final DateTime surfaceAt;
  final DateTime? expiresAt;
  final DateTime? snoozedUntil;

  Map<String, Object?> toJson() => {
    'surfaceAt': surfaceAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'snoozedUntil': snoozedUntil?.toUtc().toIso8601String(),
  };

  CurrentTiming snoozeUntil(DateTime value) => CurrentTiming(
    surfaceAt: surfaceAt,
    expiresAt: expiresAt,
    snoozedUntil: value,
  );

  CurrentTiming wake() =>
      CurrentTiming(surfaceAt: surfaceAt, expiresAt: expiresAt);
}

class CurrentItem {
  CurrentItem({
    required this.id,
    required this.status,
    required List<CurrentEvidence> evidence,
    required this.reason,
    required this.timing,
    required this.confidence,
    required this.proposedNextStep,
    required this.createdAt,
    required this.updatedAt,
    this.feedbackReference,
    this.executionReference,
    this.metadata,
  }) : evidence = List.unmodifiable(evidence) {
    _requireText(id, 'id');
    _requireText(reason, 'reason');
    _requireText(proposedNextStep, 'proposedNextStep');
    if (evidence.isEmpty) {
      throw ArgumentError.value(evidence, 'evidence', 'must not be empty');
    }
    if (!confidence.isFinite || confidence < 0 || confidence > 1) {
      throw ArgumentError.value(
        confidence,
        'confidence',
        'must be between 0 and 1',
      );
    }
    if (updatedAt.isBefore(createdAt)) {
      throw ArgumentError.value(
        updatedAt,
        'updatedAt',
        'must not be before createdAt',
      );
    }
    if (status == CurrentStatus.snoozed && timing.snoozedUntil == null) {
      throw ArgumentError('snoozed currents require snoozedUntil');
    }
    if (status != CurrentStatus.snoozed && timing.snoozedUntil != null) {
      throw ArgumentError('only snoozed currents may have snoozedUntil');
    }
    if ({CurrentStatus.accepted, CurrentStatus.completed}.contains(status) &&
        executionReference == null) {
      throw ArgumentError('$status currents require an executionReference');
    }
    if ({CurrentStatus.snoozed, CurrentStatus.dismissed}.contains(status) &&
        feedbackReference == null) {
      throw ArgumentError('$status currents require a feedbackReference');
    }
  }

  factory CurrentItem.candidate({
    required String id,
    required List<CurrentEvidence> evidence,
    required String reason,
    required CurrentTiming timing,
    required double confidence,
    required String proposedNextStep,
    required DateTime createdAt,
  }) => CurrentItem(
    id: id,
    status: CurrentStatus.candidate,
    evidence: evidence,
    reason: reason,
    timing: timing,
    confidence: confidence,
    proposedNextStep: proposedNextStep,
    createdAt: createdAt,
    updatedAt: createdAt,
  );

  factory CurrentItem.fromJson(Map<String, Object?> json) {
    final status = CurrentStatus.values.byName(_string(json, 'status'));
    final evidence = _list(json, 'evidence')
        .map((item) => CurrentEvidence.fromJson(_map(item, 'evidence item')))
        .toList();
    return CurrentItem(
      id: _string(json, 'id'),
      status: status,
      evidence: evidence,
      reason: _string(json, 'reason'),
      timing: CurrentTiming.fromJson(_map(json['timing'], 'timing')),
      confidence: _number(json, 'confidence').toDouble(),
      proposedNextStep: _string(json, 'proposedNextStep'),
      createdAt: _dateTime(json, 'createdAt'),
      updatedAt: _dateTime(json, 'updatedAt'),
      feedbackReference: _optionalString(json, 'feedbackReference'),
      executionReference: _optionalString(json, 'executionReference'),
      metadata: switch (json['metadata']) {
        final Map<String, Object?> value => Map.unmodifiable(value),
        _ => null,
      },
    );
  }

  final String id;
  final CurrentStatus status;
  final List<CurrentEvidence> evidence;
  final String reason;
  final CurrentTiming timing;
  final double confidence;
  final String proposedNextStep;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? feedbackReference;
  final String? executionReference;
  final Map<String, Object?>? metadata;

  bool get isTerminal => {
    CurrentStatus.dismissed,
    CurrentStatus.completed,
    CurrentStatus.expired,
  }.contains(status);

  CurrentItem transitionTo(
    CurrentStatus next, {
    required DateTime at,
    String? feedbackReference,
    String? executionReference,
    DateTime? snoozedUntil,
  }) {
    if (!_transitions[status]!.contains(next)) {
      throw StateError('cannot transition ${status.name} to ${next.name}');
    }
    final nextTiming = switch (next) {
      CurrentStatus.snoozed when snoozedUntil != null => timing.snoozeUntil(
        snoozedUntil,
      ),
      CurrentStatus.snoozed => throw ArgumentError.notNull('snoozedUntil'),
      _ => timing.wake(),
    };
    return CurrentItem(
      id: id,
      status: next,
      evidence: evidence,
      reason: reason,
      timing: nextTiming,
      confidence: confidence,
      proposedNextStep: proposedNextStep,
      createdAt: createdAt,
      updatedAt: at,
      feedbackReference: feedbackReference ?? this.feedbackReference,
      executionReference: executionReference ?? this.executionReference,
      metadata: metadata,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'status': status.name,
    'evidence': evidence.map((item) => item.toJson()).toList(),
    'reason': reason,
    'timing': timing.toJson(),
    'confidence': confidence,
    'proposedNextStep': proposedNextStep,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'feedbackReference': feedbackReference,
    'executionReference': executionReference,
    if (metadata != null) 'metadata': metadata,
  };
}

const _transitions = <CurrentStatus, Set<CurrentStatus>>{
  CurrentStatus.candidate: {CurrentStatus.surfaced, CurrentStatus.expired},
  CurrentStatus.surfaced: {
    CurrentStatus.accepted,
    CurrentStatus.snoozed,
    CurrentStatus.dismissed,
    CurrentStatus.expired,
  },
  CurrentStatus.accepted: {CurrentStatus.completed, CurrentStatus.expired},
  CurrentStatus.snoozed: {
    CurrentStatus.surfaced,
    CurrentStatus.dismissed,
    CurrentStatus.expired,
  },
  CurrentStatus.dismissed: {},
  CurrentStatus.completed: {},
  CurrentStatus.expired: {},
};

void _requireText(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string or null');
  }
  return value;
}

num _number(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num) {
    throw FormatException('$key must be a number');
  }
  return value;
}

List<Object?> _list(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List<Object?>) {
    throw FormatException('$key must be a list');
  }
  return value;
}

Map<String, Object?> _map(Object? value, String name) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$name must be an object');
  }
  return value;
}

DateTime _dateTime(Map<String, Object?> json, String key) =>
    DateTime.parse(_string(json, key));

DateTime? _optionalDateTime(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('$key must be an ISO-8601 string or null');
  }
  return DateTime.parse(value);
}
