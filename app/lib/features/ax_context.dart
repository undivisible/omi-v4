import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// An immutable, read-only snapshot of the on-screen context around the user's
/// text cursor, captured from the macOS accessibility tree the moment a pill
/// prompt is submitted: the frontmost app, what the user has already written in
/// the focused field, any current selection, and a bounded excerpt of the
/// surrounding window text (the thread they are looking at).
@immutable
final class AxContextSnapshot {
  const AxContextSnapshot({
    this.appName,
    this.bundleId,
    this.focusedText,
    this.selectedText,
    this.surrounding,
    this.windowTitle,
    this.secure = false,
    this.truncated = false,
    this.reason,
  });

  final String? appName;
  final String? bundleId;
  final String? focusedText;
  final String? selectedText;
  final String? surrounding;
  final String? windowTitle;

  /// True when the focused element is a secure (password) field. Its contents
  /// are never read, so [focusedText] is null in that case. This mirrors the
  /// native privacy boundary, not a convenience flag.
  final bool secure;

  /// True when a native hard cap (depth, node count, character budget, or the
  /// wall-clock deadline) stopped the surrounding-text walk before it finished.
  final bool truncated;

  /// Why a field is missing when it is ("not_trusted", "no_focus",
  /// "unsupported", or a channel error). Never carries field contents.
  final String? reason;

  static const empty = AxContextSnapshot();

  /// True when nothing here is worth adding to a prompt.
  bool get isEmpty =>
      _blank(appName) &&
      _blank(focusedText) &&
      _blank(selectedText) &&
      _blank(surrounding) &&
      _blank(windowTitle);

  static bool _blank(String? value) => value == null || value.isEmpty;

  static AxContextSnapshot fromMap(Map<Object?, Object?> map) {
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value : null;
    return AxContextSnapshot(
      appName: text(map['app']),
      bundleId: text(map['bundleId']),
      focusedText: text(map['focusedText']),
      selectedText: text(map['selectedText']),
      surrounding: text(map['surrounding']),
      windowTitle: text(map['windowTitle']),
      secure: map['secure'] == true,
      truncated: map['truncated'] == true,
      reason: text(map['reason']),
    );
  }
}

/// The MethodChannel bridge to the native accessibility-tree reader
/// (`AXContextReader` on the Swift side). Read-only: it never writes, clicks,
/// or types; it only snapshots what is already on screen. Non-macOS and a
/// missing plugin both yield an empty snapshot — this never throws, so a flaky
/// reader can never break sending a prompt.
abstract final class AxContext {
  static const _channel = MethodChannel('omi/ax_context');

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static Future<AxContextSnapshot> snapshot() async {
    if (!_supported) {
      return const AxContextSnapshot(reason: 'unsupported');
    }
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'snapshot',
      );
      if (result == null) return AxContextSnapshot.empty;
      return AxContextSnapshot.fromMap(result);
    } on MissingPluginException {
      return const AxContextSnapshot(reason: 'unsupported');
    } on PlatformException {
      return const AxContextSnapshot(reason: 'channel_error');
    }
  }
}
