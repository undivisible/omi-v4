import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../currents/currents.dart';
import '../ui/markdown_text.dart';

/// What a menu-bar action reports back: null when it did what it said, or a
/// one-line reason the menu shows so the item is never a silent no-op.
typedef MenuBarAction = Future<String?> Function();

final class DesktopMenuBarController {
  DesktopMenuBarController({
    required this.currents,
    required this.isListening,
    required this.isMeetingActive,
    required this.onOpenInput,
    required this.onToggleLiveConversation,
    required this.onToggleMeeting,
    required this.onOpenSettings,
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('omi/menu_bar');

  final CurrentsController? currents;
  final bool Function() isListening;
  final bool Function() isMeetingActive;

  /// Opens the typing surface — the floating input, never voice.
  final MenuBarAction onOpenInput;

  /// Starts or ends a spoken conversation — voice only, never the text field.
  final MenuBarAction onToggleLiveConversation;

  final MenuBarAction onToggleMeeting;
  final VoidCallback onOpenSettings;
  final MethodChannel _channel;
  bool _started = false;
  String? _notice;

  /// The last failure a menu action reported, shown as a disabled line in the
  /// menu until the next action succeeds.
  @visibleForTesting
  String? get notice => _notice;

  Future<void> start() async {
    if (!_supported || _started) return;
    _started = true;
    currents?.addListener(_currentsChanged);
    _channel.setMethodCallHandler(_handleCall);
    await _sync();
  }

  Future<void> dispose() async {
    if (!_started) return;
    _started = false;
    currents?.removeListener(_currentsChanged);
    _channel.setMethodCallHandler(null);
    await _channel.invokeMethod<void>('dispose');
  }

  void _currentsChanged() => unawaited(_sync());

  /// The meeting runtime flips its own state, so the menu title only tracks it
  /// when whoever owns that signal asks for a redraw.
  Future<void> refresh() => _sync();

  Future<void> _handleCall(MethodCall call) async {
    switch (call.method) {
      case 'openInput':
        _notice = await onOpenInput();
      case 'toggleLiveConversation':
        _notice = await onToggleLiveConversation();
      case 'toggleMeeting':
        _notice = await onToggleMeeting();
      case 'openSettings':
        onOpenSettings();
        return;
      default:
        throw MissingPluginException('Unknown menu-bar action ${call.method}');
    }
    await _sync();
  }

  Future<void> _sync() async {
    if (!_started) return;
    final items = currents?.items ?? const <CurrentCard>[];
    await _channel.invokeMethod<void>('update', {
      'task': items.isEmpty ? null : stripInlineMarkdown(items.first.title),
      'listening': isListening(),
      'meeting': isMeetingActive(),
      'notice': _notice,
    });
  }

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
}
