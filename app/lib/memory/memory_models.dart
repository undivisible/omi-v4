typedef JsonMap = Map<String, Object?>;

enum SourceKind {
  conversation,
  screen,
  audio,
  document,
  integration,
  userCorrection,
}

enum ClaimStatus { proposed, accepted, superseded, rejected }

enum EvidenceRelation { supports, contradicts }

enum ProfileStability { stable, current }

enum MemoryKind { claim, profileEntry, dailyReview }

final class MemoryFormatException implements Exception {
  const MemoryFormatException(this.message);

  final String message;

  @override
  String toString() => 'MemoryFormatException: $message';
}

final class TimeRange {
  const TimeRange({required this.from, this.until});

  final int from;
  final int? until;

  factory TimeRange.fromJson(JsonMap json) {
    final from = _integer(json, 'from');
    final until = _optionalInteger(json, 'until');
    if (until != null && until <= from) {
      throw const MemoryFormatException('until must be greater than from');
    }
    return TimeRange(from: from, until: until);
  }

  JsonMap toJson() => {'from': from, 'until': until};
}

final class MemorySource {
  const MemorySource({
    required this.id,
    required this.tenantId,
    required this.personId,
    required this.revision,
    required this.kind,
    required this.content,
    required this.capturedAt,
    required this.recordedAt,
    this.deletedAt,
  });

  final String id;
  final String tenantId;
  final String personId;
  final int revision;
  final SourceKind kind;
  final String content;
  final int capturedAt;
  final int recordedAt;
  final int? deletedAt;

  factory MemorySource.fromJson(JsonMap json) => MemorySource(
    id: _string(json, 'id'),
    tenantId: _string(json, 'tenant_id'),
    personId: _string(json, 'person_id'),
    revision: _integer(json, 'revision'),
    kind: _enumValue(SourceKind.values, _string(json, 'kind')),
    content: _string(json, 'content'),
    capturedAt: _integer(json, 'captured_at'),
    recordedAt: _integer(json, 'recorded_at'),
    deletedAt: _optionalInteger(json, 'deleted_at'),
  );

  JsonMap toJson() => {
    'id': id,
    'tenant_id': tenantId,
    'person_id': personId,
    'revision': revision,
    'kind': _wireName(kind),
    'content': content,
    'captured_at': capturedAt,
    'recorded_at': recordedAt,
    'deleted_at': deletedAt,
  };
}

final class ByteRange {
  const ByteRange({required this.start, required this.end});

  final int start;
  final int end;

  factory ByteRange.fromJson(JsonMap json) {
    final start = _integer(json, 'start');
    final end = _integer(json, 'end');
    if (start < 0 || end <= start) {
      throw const MemoryFormatException('byte range must be non-empty');
    }
    return ByteRange(start: start, end: end);
  }

  JsonMap toJson() => {'start': start, 'end': end};
}

final class Evidence {
  const Evidence({
    required this.id,
    required this.tenantId,
    required this.personId,
    required this.sourceId,
    required this.sourceRevision,
    required this.quote,
    required this.recordedAt,
    this.byteRange,
  });

  final String id;
  final String tenantId;
  final String personId;
  final String sourceId;
  final int sourceRevision;
  final String quote;
  final ByteRange? byteRange;
  final int recordedAt;

  factory Evidence.fromJson(JsonMap json) => Evidence(
    id: _string(json, 'id'),
    tenantId: _string(json, 'tenant_id'),
    personId: _string(json, 'person_id'),
    sourceId: _string(json, 'source_id'),
    sourceRevision: _integer(json, 'source_revision'),
    quote: _string(json, 'quote'),
    byteRange: _optionalByteRange(json),
    recordedAt: _integer(json, 'recorded_at'),
  );

  JsonMap toJson() => {
    'id': id,
    'tenant_id': tenantId,
    'person_id': personId,
    'source_id': sourceId,
    'source_revision': sourceRevision,
    'quote': quote,
    'byte_range': byteRange?.toJson(),
    'recorded_at': recordedAt,
  };
}

final class TemporalClaim {
  const TemporalClaim({
    required this.id,
    required this.tenantId,
    required this.personId,
    required this.subject,
    required this.predicate,
    required this.value,
    required this.validTime,
    required this.recordedTime,
    required this.status,
  });

  final String id;
  final String tenantId;
  final String personId;
  final String subject;
  final String predicate;
  final String value;
  final TimeRange validTime;
  final TimeRange recordedTime;
  final ClaimStatus status;

  factory TemporalClaim.fromJson(JsonMap json) => TemporalClaim(
    id: _string(json, 'id'),
    tenantId: _string(json, 'tenant_id'),
    personId: _string(json, 'person_id'),
    subject: _string(json, 'subject'),
    predicate: _string(json, 'predicate'),
    value: _string(json, 'value'),
    validTime: TimeRange.fromJson(_map(json, 'valid_time')),
    recordedTime: TimeRange.fromJson(_map(json, 'recorded_time')),
    status: _enumValue(ClaimStatus.values, _string(json, 'status')),
  );

  JsonMap toJson() => {
    'id': id,
    'tenant_id': tenantId,
    'person_id': personId,
    'subject': subject,
    'predicate': predicate,
    'value': value,
    'valid_time': validTime.toJson(),
    'recorded_time': recordedTime.toJson(),
    'status': _wireName(status),
  };
}

final class ClaimEvidence {
  const ClaimEvidence({
    required this.tenantId,
    required this.personId,
    required this.claimId,
    required this.evidenceId,
    required this.relation,
    required this.confidenceBasisPoints,
  });

  final String tenantId;
  final String personId;
  final String claimId;
  final String evidenceId;
  final EvidenceRelation relation;
  final int confidenceBasisPoints;

  factory ClaimEvidence.fromJson(JsonMap json) => ClaimEvidence(
    tenantId: _string(json, 'tenant_id'),
    personId: _string(json, 'person_id'),
    claimId: _string(json, 'claim_id'),
    evidenceId: _string(json, 'evidence_id'),
    relation: _enumValue(EvidenceRelation.values, _string(json, 'relation')),
    confidenceBasisPoints: _integer(json, 'confidence_basis_points'),
  );

  JsonMap toJson() => {
    'tenant_id': tenantId,
    'person_id': personId,
    'claim_id': claimId,
    'evidence_id': evidenceId,
    'relation': _wireName(relation),
    'confidence_basis_points': confidenceBasisPoints,
  };
}

final class ProfileEntry {
  const ProfileEntry({
    required this.id,
    required this.tenantId,
    required this.personId,
    required this.key,
    required this.value,
    required this.stability,
    required this.claimId,
    required this.recordedAt,
  });

  final String id;
  final String tenantId;
  final String personId;
  final String key;
  final String value;
  final ProfileStability stability;
  final String claimId;
  final int recordedAt;

  factory ProfileEntry.fromJson(JsonMap json) => ProfileEntry(
    id: _string(json, 'id'),
    tenantId: _string(json, 'tenant_id'),
    personId: _string(json, 'person_id'),
    key: _string(json, 'key'),
    value: _string(json, 'value'),
    stability: _enumValue(ProfileStability.values, _string(json, 'stability')),
    claimId: _string(json, 'claim_id'),
    recordedAt: _integer(json, 'recorded_at'),
  );

  JsonMap toJson() => {
    'id': id,
    'tenant_id': tenantId,
    'person_id': personId,
    'key': key,
    'value': value,
    'stability': _wireName(stability),
    'claim_id': claimId,
    'recorded_at': recordedAt,
  };
}

final class DailyReview {
  const DailyReview({
    required this.id,
    required this.tenantId,
    required this.personId,
    required this.day,
    required this.summary,
    required this.evidenceIds,
    required this.recordedAt,
  });

  final String id;
  final String tenantId;
  final String personId;
  final String day;
  final String summary;
  final List<String> evidenceIds;
  final int recordedAt;

  factory DailyReview.fromJson(JsonMap json) => DailyReview(
    id: _string(json, 'id'),
    tenantId: _string(json, 'tenant_id'),
    personId: _string(json, 'person_id'),
    day: _string(json, 'day'),
    summary: _string(json, 'summary'),
    evidenceIds: _nonEmptyStrings(json, 'evidence_ids'),
    recordedAt: _integer(json, 'recorded_at'),
  );

  JsonMap toJson() => {
    'id': id,
    'tenant_id': tenantId,
    'person_id': personId,
    'day': day,
    'summary': summary,
    'evidence_ids': evidenceIds,
    'recorded_at': recordedAt,
  };
}

final class MemoryReference {
  const MemoryReference({required this.kind, required this.id});

  final MemoryKind kind;
  final String id;

  factory MemoryReference.fromJson(JsonMap json) => MemoryReference(
    kind: _enumValue(MemoryKind.values, _string(json, 'kind')),
    id: _string(json, 'id'),
  );

  JsonMap toJson() => {'kind': _wireName(kind), 'id': id};
}

final class RetrievalItem {
  const RetrievalItem({
    required this.memory,
    required this.excerpt,
    required this.relevanceBasisPoints,
    required this.evidenceIds,
  });

  final MemoryReference memory;
  final String excerpt;
  final int relevanceBasisPoints;
  final List<String> evidenceIds;

  factory RetrievalItem.fromJson(JsonMap json) => RetrievalItem(
    memory: MemoryReference.fromJson(_map(json, 'memory')),
    excerpt: _string(json, 'excerpt'),
    relevanceBasisPoints: _basisPoints(json, 'relevance_basis_points'),
    evidenceIds: _nonEmptyStrings(json, 'evidence_ids'),
  );

  JsonMap toJson() => {
    'memory': memory.toJson(),
    'excerpt': excerpt,
    'relevance_basis_points': relevanceBasisPoints,
    'evidence_ids': evidenceIds,
  };
}

final class CreatedMemory {
  const CreatedMemory({
    required this.id,
    required this.sourceId,
    required this.claimId,
  });

  final String id;
  final String sourceId;
  final String claimId;

  factory CreatedMemory.fromJson(JsonMap json) => CreatedMemory(
    id: _string(json, 'id'),
    sourceId: _string(json, 'sourceId'),
    claimId: _string(json, 'claimId'),
  );

  JsonMap toJson() => {'id': id, 'sourceId': sourceId, 'claimId': claimId};
}

final class RetrievalPack {
  const RetrievalPack({
    required this.query,
    required this.items,
    required this.gaps,
  });

  final String query;
  final List<RetrievalItem> items;
  final List<String> gaps;

  factory RetrievalPack.fromJson(JsonMap json) => RetrievalPack(
    query: _string(json, 'query'),
    items: _maps(json, 'items').map(RetrievalItem.fromJson).toList(),
    gaps: _strings(json, 'gaps'),
  );

  JsonMap toJson() => {
    'query': query,
    'items': items.map((item) => item.toJson()).toList(),
    'gaps': gaps,
  };
}

String _wireName(Enum value) {
  final name = value.name;
  return name.replaceAllMapped(
    RegExp('[A-Z]'),
    (match) => '_${match.group(0)!.toLowerCase()}',
  );
}

T _enumValue<T extends Enum>(List<T> values, String wireName) {
  for (final value in values) {
    if (_wireName(value) == wireName) return value;
  }
  throw MemoryFormatException('Unknown enum value: $wireName');
}

String _string(JsonMap json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw MemoryFormatException('$key must be a string');
}

int _integer(JsonMap json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw MemoryFormatException('$key must be an integer');
}

int? _optionalInteger(JsonMap json, String key) {
  final value = json[key];
  if (value == null || value is int) return value as int?;
  throw MemoryFormatException('$key must be an integer or null');
}

JsonMap _map(JsonMap json, String key) {
  final value = json[key];
  if (value is Map<String, Object?>) return value;
  throw MemoryFormatException('$key must be an object');
}

JsonMap? _optionalMap(JsonMap json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is Map<String, Object?>) return value;
  throw MemoryFormatException('$key must be an object or null');
}

ByteRange? _optionalByteRange(JsonMap json) {
  final value = _optionalMap(json, 'byte_range');
  return value == null ? null : ByteRange.fromJson(value);
}

List<JsonMap> _maps(JsonMap json, String key) {
  final value = json[key];
  if (value is! List) throw MemoryFormatException('$key must be an array');
  return value.map((item) {
    if (item is Map<String, Object?>) return item;
    throw MemoryFormatException('$key entries must be objects');
  }).toList();
}

List<String> _strings(JsonMap json, String key) {
  final value = json[key];
  if (value is! List) throw MemoryFormatException('$key must be an array');
  return value.map((item) {
    if (item is String) return item;
    throw MemoryFormatException('$key entries must be strings');
  }).toList();
}

List<String> _nonEmptyStrings(JsonMap json, String key) {
  final values = _strings(json, key);
  if (values.isEmpty || values.any((value) => value.trim().isEmpty)) {
    throw MemoryFormatException('$key must contain citations');
  }
  return values;
}

int _basisPoints(JsonMap json, String key) {
  final value = _integer(json, key);
  if (value < 0 || value > 10000) {
    throw MemoryFormatException('$key must be between 0 and 10000');
  }
  return value;
}
