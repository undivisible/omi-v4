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

final class ConversationInboxItem {
  const ConversationInboxItem({
    required this.id,
    required this.channel,
    required this.text,
    required this.channelMessageId,
    required this.receivedAt,
    required this.attempt,
    required this.leaseToken,
    required this.leaseUntil,
  });

  factory ConversationInboxItem.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final channel = json['channel'];
    final text = json['text'];
    final channelMessageId = json['channelMessageId'];
    final receivedAt = json['receivedAt'];
    final attempt = json['attempt'];
    final leaseToken = json['leaseToken'];
    final leaseUntil = json['leaseUntil'];
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9._:-]{8,128}$').hasMatch(id) ||
        (channel != 'telegram' && channel != 'blooio') ||
        text is! String ||
        text.trim().isEmpty ||
        text.length > 20000 ||
        channelMessageId is! String ||
        channelMessageId.isEmpty ||
        receivedAt is! int ||
        attempt is! int ||
        attempt < 1 ||
        leaseToken is! String ||
        !RegExp(r'^[A-Za-z0-9._:-]{8,256}$').hasMatch(leaseToken) ||
        leaseUntil is! int ||
        leaseUntil <= receivedAt) {
      throw const FormatException('Invalid conversation inbox item');
    }
    return ConversationInboxItem(
      id: id,
      channel: channel as String,
      text: text,
      channelMessageId: channelMessageId,
      receivedAt: receivedAt,
      attempt: attempt,
      leaseToken: leaseToken,
      leaseUntil: leaseUntil,
    );
  }

  final String id;
  final String channel;
  final String text;
  final String channelMessageId;
  final int receivedAt;
  final int attempt;
  final String leaseToken;
  final int leaseUntil;
}

enum ConversationInboxOutcome { done, retry }

abstract interface class ConversationInboxTransport {
  Future<ConversationInboxItem?> claim();

  Future<void> complete(
    ConversationInboxItem item, {
    required ConversationInboxOutcome outcome,
    String? responseText,
    String? error,
  });
}

final class WorkerConversationTransport
    implements ConversationTransport, ConversationInboxTransport {
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

  @override
  Future<ConversationInboxItem?> claim() async {
    final response = await _worker.send(
      method: 'POST',
      path: '/v1/conversations/default/inbox/claim',
    );
    final body = response.body;
    if (response.statusCode != 200 || body is! Map<String, Object?>) {
      throw StateError('Could not claim a conversation inbox item.');
    }
    final item = body['item'];
    if (item == null) return null;
    if (item is! Map<String, Object?>) {
      throw const FormatException('Invalid conversation inbox response');
    }
    return ConversationInboxItem.fromJson(item);
  }

  @override
  Future<void> complete(
    ConversationInboxItem item, {
    required ConversationInboxOutcome outcome,
    String? responseText,
    String? error,
  }) async {
    final normalizedResponse = responseText?.trim();
    if ((outcome == ConversationInboxOutcome.done &&
            (normalizedResponse == null ||
                normalizedResponse.isEmpty ||
                normalizedResponse.length > 4096)) ||
        (outcome == ConversationInboxOutcome.retry && responseText != null) ||
        (error != null && error.length > 1000)) {
      throw ArgumentError('Invalid conversation inbox completion');
    }
    final response = await _worker.send(
      method: 'POST',
      path: '/v1/conversations/default/inbox/${item.id}/complete',
      body: {
        'leaseToken': item.leaseToken,
        'outcome': outcome.name,
        'responseText': ?normalizedResponse,
        'error': ?error,
      },
    );
    final body = response.body;
    final status = body is Map<String, Object?> ? body['status'] : null;
    final validStatus = outcome == ConversationInboxOutcome.done
        ? status == 'done'
        : status == 'pending' || status == 'failed';
    if (response.statusCode != 200 || !validStatus) {
      throw StateError('Could not complete a conversation inbox item.');
    }
  }
}
