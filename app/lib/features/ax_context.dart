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

  static String _clampText(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max).trimRight()}…';

  static String _collapseLine(String text, int max) =>
      _clampText(text.replaceAll(RegExp(r'\s+'), ' ').trim(), max);

  /// Labeled AX sections shared by overlay chat and Live voice context
  /// injection. Omitted when empty; secure fields contribute no written text.
  List<String> promptSections({bool includeWritten = true}) {
    final sections = <String>[];
    if (appName case final app? when app.isNotEmpty) {
      final bundle = bundleId;
      sections.add(
        'App: $app${bundle != null && bundle.isNotEmpty ? ' ($bundle)' : ''}',
      );
    }
    if (windowTitle case final title? when title.isNotEmpty) {
      sections.add('Window: ${_collapseLine(title, 200)}');
    }
    if (includeWritten) {
      if (focusedText case final written? when written.isNotEmpty) {
        sections.add(
          'What I have already written:\n"""\n${_clampText(written, 2000)}\n"""',
        );
      }
    }
    if (selectedText case final selected? when selected.isNotEmpty) {
      sections.add(
        'Currently selected:\n"""\n${_clampText(selected, 1000)}\n"""',
      );
    }
    if (surrounding case final around? when around.isNotEmpty) {
      final marker = truncated ? '\n… (truncated)' : '';
      sections.add(
        'On screen:\n"""\n${_clampText(around, 4000)}$marker\n"""',
      );
    }
    return sections;
  }

  /// Frames this snapshot for Live/overlay injection under [question].
  /// Returns null when there is nothing on hand worth sending.
  String? asSessionContextPrompt(String question) {
    final sections = promptSections();
    if (sections.isEmpty) return null;
    return '$question\n\n'
        '--- Context (a read-only snapshot of what I am looking at right now; '
        'use it to answer, do not repeat it back verbatim) ---\n'
        '${sections.join('\n\n')}';
  }

  /// Serializes back to the native map shape, so the primary engine can relay
  /// a snapshot it read to the pill panel's own engine (which cannot reach the
  /// `omi/ax_context` channel directly). Round-trips through [fromMap].
  Map<String, Object?> toMap() => {
    if (appName != null) 'app': appName,
    if (bundleId != null) 'bundleId': bundleId,
    if (focusedText != null) 'focusedText': focusedText,
    if (selectedText != null) 'selectedText': selectedText,
    if (surrounding != null) 'surrounding': surrounding,
    if (windowTitle != null) 'windowTitle': windowTitle,
    if (secure) 'secure': true,
    if (truncated) 'truncated': true,
    if (reason != null) 'reason': reason,
  };

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

/// Mid-session Live AX refresh: fresh snapshot framed like overlay voice start.
Future<String?> refreshLiveVoiceSessionContext() async {
  final ax = await AxContext.snapshot();
  if (ax.isEmpty) return null;
  return ax.asSessionContextPrompt('Updated screen context:');
}
