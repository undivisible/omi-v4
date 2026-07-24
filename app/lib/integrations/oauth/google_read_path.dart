import 'dart:convert';

import 'package:http/http.dart' as http;

import 'oauth_connector.dart';
import 'oauth_flow.dart';
import 'oauth_manager.dart';
import 'oauth_read_path.dart';

/// Read-only Gmail and Calendar access, enough to prove the grant works end to
/// end. Nothing here writes, and nothing here is wired into memory yet.
final class GoogleReadPath implements OAuthReadPath {
  GoogleReadPath({required this.manager, http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  static final gmailMessages = Uri.parse(
    'https://gmail.googleapis.com/gmail/v1/users/me/messages',
  );
  static final calendarEvents = Uri.parse(
    'https://www.googleapis.com/calendar/v3/calendars/primary/events',
  );

  final OAuthConnectionManager manager;
  final http.Client _http;

  OAuthConnector get connector => googleOAuthConnector;

  @override
  Future<List<ConnectorPreviewItem>> preview(
    String uid, {
    int limit = 3,
  }) async {
    final token = await manager.accessToken(uid, connector);
    return [
      ...await upcomingEvents(token, limit: limit),
      ...await recentMessages(token, limit: limit),
    ];
  }

  /// Upcoming calendar events, title and start time only.
  Future<List<ConnectorPreviewItem>> upcomingEvents(
    String token, {
    int limit = 3,
  }) async {
    final body = await _get(
      calendarEvents.replace(
        queryParameters: {
          'maxResults': '$limit',
          'singleEvents': 'true',
          'orderBy': 'startTime',
          'timeMin': DateTime.now().toUtc().toIso8601String(),
        },
      ),
      token,
    );
    final items = body['items'];
    if (items is! List) return const [];
    return [
      for (final item in items.whereType<Map>())
        ConnectorPreviewItem(
          title: '${item['summary'] ?? 'Untitled event'}',
          subtitle: 'Google Calendar',
          at: _start(item['start']),
        ),
    ];
  }

  /// Recent inbox message metadata — subject and sender, never the body.
  Future<List<ConnectorPreviewItem>> recentMessages(
    String token, {
    int limit = 3,
  }) async {
    final list = await _get(
      gmailMessages.replace(
        queryParameters: {'maxResults': '$limit', 'labelIds': 'INBOX'},
      ),
      token,
    );
    final messages = list['messages'];
    if (messages is! List) return const [];
    final previews = <ConnectorPreviewItem>[];
    for (final message in messages.whereType<Map>()) {
      final id = message['id'];
      if (id is! String) continue;
      final detail = await _get(
        gmailMessages.replace(
          path: '${gmailMessages.path}/$id',
          queryParameters: {'format': 'metadata', 'metadataHeaders': 'Subject'},
        ),
        token,
      );
      previews.add(
        ConnectorPreviewItem(
          title: _header(detail, 'Subject') ?? '(no subject)',
          subtitle: 'Gmail',
          at: _internalDate(detail['internalDate']),
        ),
      );
    }
    return previews;
  }

  Future<Map<String, Object?>> _get(Uri uri, String token) async {
    final response = await _http.get(
      uri,
      headers: {'authorization': 'Bearer $token', 'accept': 'application/json'},
    );
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw OAuthReconnectRequiredException(connector.id);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OAuthException('Google returned ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) return const {};
    return decoded.map((key, value) => MapEntry('$key', value));
  }

  String? _header(Map<String, Object?> message, String name) {
    final payload = message['payload'];
    if (payload is! Map) return null;
    final headers = payload['headers'];
    if (headers is! List) return null;
    for (final header in headers.whereType<Map>()) {
      if ('${header['name']}'.toLowerCase() == name.toLowerCase()) {
        final value = '${header['value']}';
        return value.isEmpty ? null : value;
      }
    }
    return null;
  }

  DateTime? _start(Object? start) {
    if (start is! Map) return null;
    final value = start['dateTime'] ?? start['date'];
    return value is String ? DateTime.tryParse(value) : null;
  }

  DateTime? _internalDate(Object? value) {
    final millis = int.tryParse('$value');
    return millis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }
}
