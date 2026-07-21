import 'dart:async';

import 'package:flutter/foundation.dart';

import '../native/generated/signals/signals.dart';
import '../native/native_hub.dart';

final class NativeMemoryController extends ChangeNotifier {
  NativeMemoryController({
    required NativeHub hub,
    required Stream<NativeEvent> events,
    String Function()? requestId,
    DateTime Function()? now,
  }) : this._(hub, events, requestId ?? _defaultRequestId, now ?? DateTime.now);

  NativeMemoryController._(this._hub, this._events, this._requestId, this._now);

  final NativeHub _hub;
  final Stream<NativeEvent> _events;
  final String Function() _requestId;
  final DateTime Function() _now;
  StreamSubscription<NativeEvent>? _subscription;
  String? _activeRequestId;
  String _query = 'profile';
  List<MemorySearchItem> _items = const [];
  List<String> _gaps = const [];
  String? _error;
  bool _loading = false;
  bool _disposed = false;

  List<MemorySearchItem> get items => _items;
  List<String> get gaps => _gaps;
  String? get error => _error;
  bool get loading => _loading;
  String get query => _query;

  void start() {
    if (_subscription != null) return;
    _subscription = _events.listen(_handleEvent, onError: _handleStreamError);
  }

  void search(String query) {
    final normalized = query.trim();
    if (normalized.isEmpty) return;
    start();
    final requestId = _requestId();
    _activeRequestId = requestId;
    _query = normalized;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _hub.search(requestId: requestId, query: normalized);
    } catch (error) {
      if (_activeRequestId != requestId) return;
      _loading = false;
      _error = error.toString();
      notifyListeners();
    }
  }

  void correct({
    required String claimId,
    required String text,
    required String value,
  }) {
    final normalizedText = text.trim();
    final normalizedValue = value.trim();
    if (normalizedText.isEmpty || normalizedValue.isEmpty) return;
    final nowMs = _now().millisecondsSinceEpoch;
    final requestId = _requestId();
    _activeRequestId = requestId;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _hub.correctMemory(
        requestId: requestId,
        claimId: claimId,
        text: normalizedText,
        value: normalizedValue,
        occurredAtMs: nowMs,
        recordedAtMs: nowMs,
      );
    } catch (error) {
      _completeWithError(requestId, error.toString());
    }
  }

  void deleteSource(String sourceId) {
    final requestId = _requestId();
    _activeRequestId = requestId;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _hub.deleteMemorySource(
        requestId: requestId,
        sourceId: sourceId,
        deletedAtMs: _now().millisecondsSinceEpoch,
      );
    } catch (error) {
      _completeWithError(requestId, error.toString());
    }
  }

  void _handleEvent(NativeEvent event) {
    switch (event) {
      case NativeEventMemorySearchResults(:final value)
          when value.requestId == _activeRequestId:
        _items = List.unmodifiable(value.items);
        _gaps = List.unmodifiable(value.gaps);
        _loading = false;
        _error = null;
        notifyListeners();
      case NativeEventMemoryCorrected(:final value)
          when value.requestId == _activeRequestId:
        search(_query);
      case NativeEventMemorySourceDeleted(:final value)
          when value.requestId == _activeRequestId:
        search(_query);
      case NativeEventError(:final value)
          when value.requestId == _activeRequestId:
        _completeWithError(value.requestId!, value.message);
      default:
        break;
    }
  }

  void _handleStreamError(Object error) {
    if (_disposed) return;
    _loading = false;
    _error = error.toString();
    notifyListeners();
  }

  void _completeWithError(String requestId, String message) {
    if (_disposed || requestId != _activeRequestId) return;
    _loading = false;
    _error = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  static String _defaultRequestId() =>
      'memory-${DateTime.now().microsecondsSinceEpoch}';
}
