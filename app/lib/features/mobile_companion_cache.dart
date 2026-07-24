import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../conversations/conversations.dart';
import '../currents/currents.dart';

/// SharedPreferences cache for the mobile companion shell: tab index,
/// last successful conversation replay, and the most recent currents snapshot.
abstract interface class MobileCompanionCache {
  Future<int> readPageIndex();
  Future<void> savePageIndex(int index);

  Future<List<ConversationMessage>> readConversation();
  Future<void> saveConversation(List<ConversationMessage> messages);

  Future<CompanionChatSessionSnapshot?> readChatSession();
  Future<void> saveChatSession(CompanionChatSessionSnapshot snapshot);
  Future<void> clearChatSession();

  Future<CompanionCurrentsSnapshot?> readCurrents();
  Future<void> saveCurrents({
    required List<CurrentCard> items,
    String? briefCrepus,
  });

  Future<void> clear();
}

final class CompanionChatSessionSnapshot {
  const CompanionChatSessionSnapshot({
    required this.exchangeStart,
    required this.lastActivityMs,
  });

  final int exchangeStart;
  final int lastActivityMs;
}

final class CompanionCurrentsSnapshot {
  const CompanionCurrentsSnapshot({
    required this.items,
    required this.cachedAt,
    this.briefCrepus,
  });

  final List<CurrentCard> items;
  final String? briefCrepus;
  final int cachedAt;
}

final class PreferencesMobileCompanionCache implements MobileCompanionCache {
  PreferencesMobileCompanionCache({
    this.conversationCapacity = 200,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const pageIndexKey = 'companion_page_index_v1';
  static const conversationKey = 'companion_conversation_v1';
  static const chatSessionKey = 'companion_chat_session_v1';
  static const currentsKey = 'companion_currents_v1';

  final int conversationCapacity;
  final DateTime Function() _now;

  @override
  Future<int> readPageIndex() async {
    final value =
        (await SharedPreferences.getInstance()).getInt(pageIndexKey) ?? 0;
    return value.clamp(0, 2);
  }

  @override
  Future<void> savePageIndex(int index) async {
    await (await SharedPreferences.getInstance()).setInt(
      pageIndexKey,
      index.clamp(0, 2),
    );
  }

  @override
  Future<List<ConversationMessage>> readConversation() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      conversationKey,
    );
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map<String, Object?>)
            ConversationMessage.fromJson(entry),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> saveConversation(List<ConversationMessage> messages) async {
    final bounded = messages.length > conversationCapacity
        ? messages.sublist(messages.length - conversationCapacity)
        : messages;
    await (await SharedPreferences.getInstance()).setString(
      conversationKey,
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
  }

  @override
  Future<CompanionChatSessionSnapshot?> readChatSession() async {
    final raw = (await SharedPreferences.getInstance()).getString(chatSessionKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      final exchangeStart = decoded['exchangeStart'];
      final lastActivityMs = decoded['lastActivityMs'];
      if (exchangeStart is! int || lastActivityMs is! int) return null;
      return CompanionChatSessionSnapshot(
        exchangeStart: exchangeStart,
        lastActivityMs: lastActivityMs,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveChatSession(CompanionChatSessionSnapshot snapshot) async {
    await (await SharedPreferences.getInstance()).setString(
      chatSessionKey,
      jsonEncode({
        'exchangeStart': snapshot.exchangeStart,
        'lastActivityMs': snapshot.lastActivityMs,
      }),
    );
  }

  @override
  Future<void> clearChatSession() async {
    await (await SharedPreferences.getInstance()).remove(chatSessionKey);
  }

  @override
  Future<CompanionCurrentsSnapshot?> readCurrents() async {
    final raw = (await SharedPreferences.getInstance()).getString(currentsKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      final itemsRaw = decoded['items'];
      final cachedAt = decoded['cachedAt'];
      if (itemsRaw is! List || cachedAt is! int) return null;
      final items = [
        for (final entry in itemsRaw)
          if (entry is Map<String, Object?>) CurrentCard.fromJson(entry),
      ];
      final briefCrepus = decoded['briefCrepus'];
      return CompanionCurrentsSnapshot(
        items: items,
        briefCrepus: briefCrepus is String && briefCrepus.isNotEmpty
            ? briefCrepus
            : null,
        cachedAt: cachedAt,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveCurrents({
    required List<CurrentCard> items,
    String? briefCrepus,
  }) async {
    await (await SharedPreferences.getInstance()).setString(
      currentsKey,
      jsonEncode({
        'items': [for (final card in items) _currentCardToJson(card)],
        'briefCrepus': ?briefCrepus,
        'cachedAt': _now().millisecondsSinceEpoch,
      }),
    );
  }

  @override
  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(pageIndexKey);
    await preferences.remove(conversationKey);
    await preferences.remove(chatSessionKey);
    await preferences.remove(currentsKey);
  }

  static Map<String, Object?> _currentCardToJson(CurrentCard card) => {
    ...card.item.toJson(),
    'title': card.title,
    'summary': card.summary,
    'contentKind': switch (card.contentKind) {
      CurrentContentKind.agentAction => 'agent_action',
      CurrentContentKind.humanAction => 'human_action',
      CurrentContentKind.awareness => 'awareness',
    },
    if (card.sourceKind != null) 'sourceKind': card.sourceKind,
    if (card.metadata != null) 'metadata': card.metadata,
  };
}

final class VolatileMobileCompanionCache implements MobileCompanionCache {
  VolatileMobileCompanionCache({this.conversationCapacity = 200});

  final int conversationCapacity;
  int _pageIndex = 0;
  List<ConversationMessage> _conversation = const [];
  CompanionChatSessionSnapshot? _chatSession;
  CompanionCurrentsSnapshot? _currents;

  @override
  Future<int> readPageIndex() async => _pageIndex;

  @override
  Future<void> savePageIndex(int index) async {
    _pageIndex = index.clamp(0, 2);
  }

  @override
  Future<List<ConversationMessage>> readConversation() async =>
      List.unmodifiable(_conversation);

  @override
  Future<void> saveConversation(List<ConversationMessage> messages) async {
    _conversation = List.unmodifiable(
      messages.length > conversationCapacity
          ? messages.sublist(messages.length - conversationCapacity)
          : messages,
    );
  }

  @override
  Future<CompanionChatSessionSnapshot?> readChatSession() async => _chatSession;

  @override
  Future<void> saveChatSession(CompanionChatSessionSnapshot snapshot) async {
    _chatSession = snapshot;
  }

  @override
  Future<void> clearChatSession() async {
    _chatSession = null;
  }

  @override
  Future<CompanionCurrentsSnapshot?> readCurrents() async => _currents;

  @override
  Future<void> saveCurrents({
    required List<CurrentCard> items,
    String? briefCrepus,
  }) async {
    _currents = CompanionCurrentsSnapshot(
      items: List.unmodifiable(items),
      briefCrepus: briefCrepus,
      cachedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  Future<void> clear() async {
    _pageIndex = 0;
    _conversation = const [];
    _chatSession = null;
    _currents = null;
  }
}
