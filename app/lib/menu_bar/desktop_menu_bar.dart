import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../currents/currents.dart';
import '../ui/markdown_text.dart';

final class DesktopMenuBarController {
  DesktopMenuBarController({
    required this.currents,
    required this.isListening,
    required this.onCapture,
    required this.onToggleListening,
    required this.onOpenSettings,
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('omi/menu_bar');

  final CurrentsController? currents;
  final bool Function() isListening;
  final Future<void> Function() onCapture;
  final Future<void> Function() onToggleListening;
  final VoidCallback onOpenSettings;
  final MethodChannel _channel;
  bool _started = false;

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

  Future<void> _handleCall(MethodCall call) async {
    switch (call.method) {
      case 'capture':
        await onCapture();
      case 'toggleListening':
        await onToggleListening();
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
    });
  }

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
}
