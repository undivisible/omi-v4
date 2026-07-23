import 'dart:convert';

final class HubTaskMeta {
  const HubTaskMeta({
    required this.kind,
    required this.title,
    this.startsAt,
    this.endsAt,
    this.detail,
  });

  final String kind;
  final String title;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final String? detail;

  static HubTaskMeta? fromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    final title = json['title'];
    if (kind is! String || kind.trim().isEmpty) return null;
    if (title is! String || title.trim().isEmpty) return null;
    DateTime? time(Object? value) =>
        value is String ? DateTime.tryParse(value) : null;
    final detail = json['detail'];
    return HubTaskMeta(
      kind: kind.trim(),
      title: title.trim(),
      startsAt: time(json['startsAt']),
      endsAt: time(json['endsAt']),
      detail: detail is String && detail.trim().isNotEmpty
          ? detail.trim()
          : null,
    );
  }

  static HubTaskMeta? tryDecode(String encoded) {
    final trimmed = encoded.trim();
    if (!trimmed.startsWith('{')) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    return fromJson(decoded.cast<String, Object?>());
  }

  String encode() => jsonEncode({
    'kind': kind,
    'title': title,
    if (startsAt != null) 'startsAt': startsAt!.toIso8601String(),
    if (endsAt != null) 'endsAt': endsAt!.toIso8601String(),
    if (detail != null) 'detail': detail,
  });

  String? formatTimeRange() {
    final start = startsAt;
    if (start == null) return null;
    final local = start.toLocal();
    final end = endsAt?.toLocal();
    if (end == null) return _clock(local);
    return '${_clock(local)} – ${_clock(end)}';
  }

  static String _clock(DateTime time) {
    final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
    final minute = time.minute.toString().padLeft(2, '0');
    final period = time.hour < 12 ? 'AM' : 'PM';
    return '$hour:$minute $period';
  }
}
