import 'package:flutter/foundation.dart';

import 'currents.dart';

final class CurrentsController extends ChangeNotifier {
  CurrentsController(this._client);

  final CurrentsClient _client;
  List<CurrentCard> items = const [];
  String? error;
  bool loading = false;
  Future<void>? _loadFuture;

  Future<void> load() => _loadFuture ??= _load();

  Future<void> _load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      await _client.generate();
      items = await _client.list();
    } on CurrentsClientException catch (failure) {
      error = failure.message;
    } finally {
      loading = false;
      _loadFuture = null;
      notifyListeners();
    }
  }

  Future<void> dismiss(String id) => _feedback(id, CurrentStatus.dismissed);

  Future<void> snooze(String id, DateTime until) =>
      _feedback(id, CurrentStatus.snoozed, snoozedUntil: until);

  Future<CurrentActionHandoff> accept(String id) => _client.accept(id);

  Future<void> _feedback(
    String id,
    CurrentStatus status, {
    DateTime? snoozedUntil,
  }) async {
    await _client.feedback(id, status, snoozedUntil: snoozedUntil);
    items = List.unmodifiable(items.where((item) => item.item.id != id));
    notifyListeners();
  }
}
