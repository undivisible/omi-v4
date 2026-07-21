import '../api/worker_http.dart';

final class ConversationMessage {
  const ConversationMessage({
    required this.cursor,
    required this.clientMessageId,
    required this.role,
    required this.source,
    required this.text,
    required this.createdAt,
  });

  factory ConversationMessage.fromJson(Map<String, Object?> json) {
    final cursor = json['cursor'];
    final clientMessageId = json['clientMessageId'];
    final role = json['role'];
    final source = json['source'];
    final text = json['text'];
    final createdAt = json['createdAt'];
    if (cursor is! int ||
        clientMessageId is! String ||
        role is! String ||
        source is! String ||
        text is! String ||
        createdAt is! int) {
      throw const FormatException('Invalid conversation message');
    }
    return ConversationMessage(
      cursor: cursor,
      clientMessageId: clientMessageId,
      role: role,
      source: source,
      text: text,
      createdAt: createdAt,
    );
  }

  final int cursor;
  final String clientMessageId;
  final String role;
  final String source;
  final String text;
  final int createdAt;
}

abstract interface class ConversationTransport {
  Future<ConversationMessage> append({
    required String clientMessageId,
    required String role,
    required String source,
    required String text,
  });

  Future<List<ConversationMessage>> replay({required int after});
}

final class WorkerConversationTransport implements ConversationTransport {
  const WorkerConversationTransport(this._worker);

  final WorkerHttpClient _worker;

  @override
  Future<ConversationMessage> append({
    required String clientMessageId,
    required String role,
    required String source,
    required String text,
  }) async {
    final response = await _worker.send(
      method: 'POST',
      path: '/v1/conversations/default/messages',
      body: {
        'clientMessageId': clientMessageId,
        'role': role,
        'source': source,
        'text': text,
      },
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw StateError('Could not save conversation message.');
    }
    final body = response.body;
    if (body is! Map<String, Object?> ||
        body['message'] is! Map<String, Object?>) {
      throw const FormatException('Invalid conversation response');
    }
    return ConversationMessage.fromJson(
      body['message']! as Map<String, Object?>,
    );
  }

  @override
  Future<List<ConversationMessage>> replay({required int after}) async {
    if (after < 0) throw ArgumentError.value(after, 'after');
    final result = <ConversationMessage>[];
    var cursor = after;
    while (true) {
      final response = await _worker.send(
        method: 'GET',
        path: '/v1/conversations/default/messages',
        query: {'after': '$cursor', 'limit': '200'},
      );
      final body = response.body;
      if (response.statusCode != 200 || body is! Map<String, Object?>) {
        throw StateError('Could not replay conversation.');
      }
      final values = body['messages'];
      final nextCursor = body['nextCursor'];
      if (values is! List || nextCursor is! int || nextCursor < cursor) {
        throw const FormatException('Invalid conversation replay');
      }
      final page = values
          .map((value) {
            if (value is! Map<String, Object?>) {
              throw const FormatException('Invalid conversation message');
            }
            return ConversationMessage.fromJson(value);
          })
          .toList(growable: false);
      if (page.any((message) => message.cursor <= cursor) ||
          (page.isNotEmpty && page.last.cursor != nextCursor)) {
        throw const FormatException('Invalid conversation replay');
      }
      result.addAll(page);
      if (page.length < 200) return result;
      cursor = nextCursor;
    }
  }
}
