import 'package:flutter/foundation.dart';

/// One line of evidence that a connection actually reads something. Kept
/// deliberately generic: the settings UI renders these without knowing which
/// provider produced them.
@immutable
final class ConnectorPreviewItem {
  const ConnectorPreviewItem({
    required this.title,
    required this.subtitle,
    this.at,
  });

  final String title;
  final String subtitle;
  final DateTime? at;
}

/// A connector's read path. Today this only feeds the settings preview; the
/// same call is what a future ingestion pass would drain into memory.
abstract interface class OAuthReadPath {
  Future<List<ConnectorPreviewItem>> preview(String uid, {int limit});
}
