import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'conversations.dart';

/// Persists the local-mode (signed-out, dev Gemini key) chat history so it
/// survives app relaunches. Signed-in history lives on the worker and is
/// replayed from there; this store only backs conversations that would
/// otherwise exist purely in memory.
abstract interface class LocalConversationStore
    implements ConversationTransport {
  Future<void> clear();
}

final class PreferencesLocalConversationStore
    implements LocalConversationStore {
  PreferencesLocalConversationStore({
    this.capacity = 200,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const _key = 'local_conversation_v1';

  final int capacity;
  final DateTime Function() _now;

  Future<List<ConversationMessage>> _load(SharedPreferences preferences) async {
    final raw = preferences.getString(_key);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final entry in decoded)
          if (entry is Map<String, Object?>)
            ConversationMessage.fromJson(entry),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(
    SharedPreferences preferences,
    List<ConversationMessage> messages,
  ) async {
    final bounded = messages.length > capacity
        ? messages.sublist(messages.length - capacity)
        : messages;
    final saved = await preferences.setString(
      _key,
      jsonEncode([
        for (final message in bounded)
          {
            'cursor': message.cursor,
            'clientMessageId': message.clientMessageId,
            'role': message.role,
            'source': message.source,
            'text': message.text,
            'createdAt': message.createdAt,
          },
      ]),
    );
    if (!saved) {
      throw StateError('Could not persist the local conversation.');
    }
  }

  @override
  Future<ConversationMessage> append({
    required String clientMessageId,
    required String role,
    required String source,
    required String text,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final messages = await _load(preferences);
    final message = ConversationMessage(
      cursor: messages.isEmpty ? 1 : messages.last.cursor + 1,
      clientMessageId: clientMessageId,
      role: role,
      source: source,
      text: text,
      createdAt: _now().millisecondsSinceEpoch,
    );
    messages.add(message);
    await _save(preferences, messages);
    return message;
  }

  @override
  Future<List<ConversationMessage>> replay({required int after}) async {
    final preferences = await SharedPreferences.getInstance();
    final messages = await _load(preferences);
    return [
      for (final message in messages)
        if (message.cursor > after) message,
    ];
  }

  @override
  Future<void> clear() async {
    await (await SharedPreferences.getInstance()).remove(_key);
  }
}

final class VolatileLocalConversationStore implements LocalConversationStore {
  VolatileLocalConversationStore({this.capacity = 200});

  final int capacity;
  final List<ConversationMessage> _messages = [];

  @override
  Future<ConversationMessage> append({
    required String clientMessageId,
    required String role,
    required String source,
    required String text,
  }) async {
    final message = ConversationMessage(
      cursor: _messages.isEmpty ? 1 : _messages.last.cursor + 1,
      clientMessageId: clientMessageId,
      role: role,
      source: source,
      text: text,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    _messages.add(message);
    if (_messages.length > capacity) {
      _messages.removeRange(0, _messages.length - capacity);
    }
    return message;
  }

  @override
  Future<List<ConversationMessage>> replay({required int after}) async => [
    for (final message in _messages)
      if (message.cursor > after) message,
  ];

  @override
  Future<void> clear() async => _messages.clear();
}
