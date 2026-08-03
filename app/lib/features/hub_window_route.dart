import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The channel the settings engine shares with the Runner. Opening settings
/// can name a section, and the window may already be up when that happens, so
/// the Runner both answers `pendingSection` while this engine boots and calls
/// `showSection` on it afterwards.
const settingsRouteChannel = MethodChannel('omi/settings_route');

/// Hands a settings section to the hub window and brings that window forward.
///
/// The settings window is a second FlutterEngine, and rinf binds exactly one
/// Dart isolate to the Rust hub per process: `rinf_prepare_isolate_extern`
/// keeps a single global isolate handle and every caller replaces the last,
/// and starting the Rust logic again tears down the running runtime. The hub
/// window holds that binding, so a section that needs the hub can only be
/// rendered there. Returns false when the Runner did not answer.
Future<bool> openSectionInHubWindow(String sectionName) async {
  try {
    await settingsRouteChannel.invokeMethod<void>('openInHub', sectionName);
    return true;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// Stands in for a settings section the settings window cannot render, and
/// offers the one action that does work: open it where the hub lives.
class HubWindowSectionTile extends StatefulWidget {
  const HubWindowSectionTile({
    required this.section,
    required this.icon,
    required this.title,
    required this.detail,
    required this.actionLabel,
    this.opener = openSectionInHubWindow,
    super.key,
  });

  final String section;
  final IconData icon;
  final String title;
  final String detail;
  final String actionLabel;

  /// Injected in tests; otherwise the real channel call.
  final Future<bool> Function(String section) opener;

  @override
  State<HubWindowSectionTile> createState() => _HubWindowSectionTileState();
}

class _HubWindowSectionTileState extends State<HubWindowSectionTile> {
  bool _busy = false;
  bool _failed = false;

  Future<void> _open() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    final opened = await widget.opener(widget.section);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = !opened;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(widget.icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.detail,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.35,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.tonal(
                  key: Key('hub_window_section_${widget.section}'),
                  onPressed: _busy ? null : () => unawaited(_open()),
                  child: Text(widget.actionLabel),
                ),
                if (_failed)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'The Omi window did not answer. Open it from the menu '
                      'bar and look for this section there.',
                      key: Key('hub_window_section_${widget.section}_failed'),
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.35,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
