import 'dart:async';

import 'package:flutter/material.dart';

import '../../native/native_hub.dart';
import '../../ui/omi_typography.dart';
import 'rewind_client.dart';
import 'rewind_platform.dart';
import 'rewind_timeline_screen.dart';

/// The warm-paper palette, pinned to the same values the rest of settings
/// uses so the section looks native to the window it lives in.
class RewindColors {
  const RewindColors._({
    required this.ink,
    required this.muted,
    required this.hairline,
    required this.panel,
    required this.page,
    required this.recording,
  });

  const RewindColors.light()
    : this._(
        ink: const Color(0xff171716),
        muted: const Color(0xff706e68),
        hairline: const Color(0x1a000000),
        panel: const Color(0xfffffefa),
        page: const Color(0xfff7f6f1),
        recording: const Color(0xffc0392b),
      );

  const RewindColors.dark()
    : this._(
        ink: const Color(0xfff4f2ea),
        muted: const Color(0xffa6a49c),
        hairline: const Color(0x1affffff),
        panel: const Color(0xff232321),
        page: const Color(0xff1c1c1a),
        recording: const Color(0xffe8705f),
      );

  final Color ink;
  final Color muted;
  final Color hairline;
  final Color panel;
  final Color page;
  final Color recording;

  static RewindColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const RewindColors.dark()
      : const RewindColors.light();
}

/// The whole Rewind settings section: the master switch, the pause, the
/// retention bound, the exclusion list, and the delete controls. Every claim
/// it makes about what is being recorded is read from the live service.
class RewindSettingsTile extends StatefulWidget {
  const RewindSettingsTile({
    this.previewMode = false,
    this.client,
    this.hub,
    super.key,
  });

  final bool previewMode;

  /// Injected in tests; otherwise resolved from [RewindRuntime].
  final RewindClient? client;

  /// The hub the runtime resolves its client over, when one is not injected.
  final NativeHub? hub;

  @override
  State<RewindSettingsTile> createState() => _RewindSettingsTileState();
}

class _RewindSettingsTileState extends State<RewindSettingsTile> {
  RewindClient? _client;
  final _excludeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final injected = widget.client;
    final hub = widget.hub;
    if (injected != null) {
      _attach(injected);
    } else if (!widget.previewMode && rewindSupported && hub != null) {
      unawaited(
        RewindRuntime.instance.resolve(hub: hub, captures: false).then((
          client,
        ) {
          if (mounted) _attach(client);
        }),
      );
    }
  }

  void _attach(RewindClient client) {
    setState(() => _client = client);
    client.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _client?.removeListener(_onChanged);
    _excludeController.dispose();
    super.dispose();
  }

  Future<void> _confirmDeleteAll(RewindClient client) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete every recorded frame?'),
        content: const Text(
          'Every screenshot and every line of text Rewind has kept is '
          'removed from this machine. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('rewind_delete_all_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete everything'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await client.deleteAll();
  }

  @override
  Widget build(BuildContext context) {
    final colors = RewindColors.of(context);
    final client = _client;
    final status = client?.status;
    if (client == null || status == null) {
      return _Row(
        colors: colors,
        icon: Icons.history_toggle_off_rounded,
        title: 'Rewind',
        detail: widget.previewMode || !rewindSupported
            ? 'Continuous screen history is available on macOS only.'
            : client?.unavailableReason ?? 'Loading\u2026',
      );
    }

    final megabytes = status.totalBytes.toInt() / (1024 * 1024);
    final oldest = status.oldestCaptureAtMs;
    final options = status.retentionOptions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Row(
          colors: colors,
          icon: Icons.history_toggle_off_rounded,
          title: 'Record my screen',
          detail: status.enabled
              ? 'A red dot sits in the menu bar the whole time Rewind is on. '
                    'Pause it there or here.'
              : 'Off. Rewind captures nothing until you turn this on.',
          trailing: Switch(
            key: const Key('rewind_enabled'),
            value: status.enabled,
            onChanged: (value) => unawaited(client.setEnabled(value)),
          ),
        ),
        if (status.enabled) ...[
          _Divider(colors: colors),
          _Row(
            colors: colors,
            icon: status.paused
                ? Icons.play_arrow_rounded
                : Icons.pause_rounded,
            title: status.paused ? 'Paused' : _statusTitle(status),
            detail: _statusDetail(status),
            trailing: TextButton(
              key: const Key('rewind_pause'),
              onPressed: () => unawaited(client.setPaused(!status.paused)),
              child: Text(status.paused ? 'Resume' : 'Pause'),
            ),
          ),
          _Divider(colors: colors),
          _Row(
            colors: colors,
            icon: Icons.schedule_rounded,
            title: 'Keep history for',
            detail:
                'Oldest frames are deleted first once either bound is hit. '
                'Deleting means the file is removed, not hidden.',
            trailing: DropdownButton<String>(
              key: const Key('rewind_retention'),
              value: _selectedRetention(status),
              underline: const SizedBox.shrink(),
              items: [
                for (final option in options)
                  DropdownMenuItem(
                    value: option.label,
                    child: Text(option.label),
                  ),
              ],
              onChanged: (label) {
                for (final option in options) {
                  if (option.label == label) {
                    unawaited(client.setRetention(option));
                    return;
                  }
                }
              },
            ),
          ),
          _Divider(colors: colors),
          _Row(
            colors: colors,
            icon: Icons.password_rounded,
            title: 'Never record these apps',
            detail:
                '${status.deniedBundleIds.length} apps excluded, '
                'including every password manager Omi knows about. Add a '
                'bundle id to exclude another.',
            trailing: SizedBox(
              width: 190,
              child: TextField(
                key: const Key('rewind_exclude_field'),
                controller: _excludeController,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'com.example.app',
                ),
                onSubmitted: (value) {
                  unawaited(client.denyBundleId(value));
                  _excludeController.clear();
                },
              ),
            ),
          ),
          _Divider(colors: colors),
          _Toggle(
            colors: colors,
            keyValue: const Key('rewind_private_browsing'),
            icon: Icons.visibility_off_outlined,
            title: 'Skip private browsing windows',
            detail:
                'Windows whose title says private, incognito or inPrivate are '
                'never photographed.',
            value: status.skipPrivateBrowsing,
            onChanged: (value) =>
                unawaited(client.setPrivacyFlags(skipPrivateBrowsing: value)),
          ),
          _Divider(colors: colors),
          _Toggle(
            colors: colors,
            keyValue: const Key('rewind_ocr'),
            icon: Icons.text_fields_rounded,
            title: 'Read text off frames on this device',
            detail:
                'Apple\u2019s Vision framework transcribes each frame locally '
                'so the timeline is searchable. Nothing is uploaded.',
            value: status.readOnScreenText,
            onChanged: (value) =>
                unawaited(client.setPrivacyFlags(readOnScreenText: value)),
          ),
          _Divider(colors: colors),
          _Row(
            colors: colors,
            icon: Icons.auto_awesome_outlined,
            title: 'Automatically describe frames',
            detail:
                'Each saved frame gets a short factual caption. Omi uses '
                'Apple Foundation Models on this Mac when available; '
                'otherwise the frame may be sent to Omi cloud for a MiMo '
                'caption.',
          ),
          _Divider(colors: colors),
          _Toggle(
            colors: colors,
            keyValue: const Key('rewind_titles'),
            icon: Icons.title_rounded,
            title: 'Store window titles',
            detail:
                'Titles make the timeline readable and are also the most '
                'revealing part of it. Off keeps app names only.',
            value: status.recordWindowTitles,
            onChanged: (value) =>
                unawaited(client.setPrivacyFlags(recordWindowTitles: value)),
          ),
        ],
        _Divider(colors: colors),
        _Row(
          colors: colors,
          icon: Icons.sd_storage_outlined,
          title: 'On this Mac',
          detail: oldest == null
              ? 'No frames stored.'
              : '${status.frameCount} frames, '
                    '${megabytes.toStringAsFixed(1)} MB, '
                    'oldest ${_ago(oldest)}. Stored under ~/.omi/rewind.',
          trailing: TextButton(
            key: const Key('rewind_open_timeline'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RewindTimelineScreen(client: client),
              ),
            ),
            child: const Text('Timeline'),
          ),
        ),
        _Divider(colors: colors),
        _Row(
          colors: colors,
          icon: Icons.delete_outline_rounded,
          title: 'Delete recorded history',
          detail:
              'Forget the last hour, or everything. Both delete the files '
              'themselves.',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                key: const Key('rewind_delete_hour'),
                onPressed: () =>
                    unawaited(client.deleteLast(const Duration(hours: 1))),
                child: const Text('Last hour'),
              ),
              const SizedBox(width: 4),
              TextButton(
                key: const Key('rewind_delete_all'),
                onPressed: () => unawaited(_confirmDeleteAll(client)),
                child: const Text('Everything'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The dropdown is keyed on the label rather than on the option itself: the
  /// engine restates the option list with every status, and two structurally
  /// equal options from two different messages are not the same object.
  static String? _selectedRetention(RewindStatus status) {
    for (final option in status.retentionOptions) {
      if (option.maxAgeDays == status.retentionMaxAgeDays &&
          option.maxBytes == status.retentionMaxBytes) {
        return option.label;
      }
    }
    return status.retentionOptions.length > 2
        ? status.retentionOptions[2].label
        : null;
  }

  static String _statusTitle(RewindStatus status) =>
      status.recording ? 'Recording' : 'Waiting';

  static String _statusDetail(RewindStatus status) {
    if (status.paused) {
      return 'No frames are being captured while paused.';
    }
    return switch (status.lastSkipReason) {
      null => 'Capturing on window changes and on a per-app heartbeat.',
      RewindSkipReason.deniedApp =>
        'The app in front is on the exclusion list, so nothing is captured.',
      RewindSkipReason.privateWindow =>
        'The window in front looks like private browsing, so it is skipped.',
      RewindSkipReason.screenLocked =>
        'The screen is locked or asleep; capture is stopped.',
      RewindSkipReason.noPermission =>
        'Screen recording permission is not granted yet.',
      RewindSkipReason.idle => 'You have been away, so the heartbeat stopped.',
      RewindSkipReason.unchanged =>
        'The screen has not changed, so no frame was stored.',
      RewindSkipReason.busy => 'Catching up on the previous frame.',
      RewindSkipReason.paused => 'Paused.',
      RewindSkipReason.heartbeat ||
      RewindSkipReason.minimumInterval => 'Waiting for the next heartbeat.',
    };
  }

  static String _ago(int atMs) {
    final delta = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(atMs),
    );
    if (delta.inDays >= 1) {
      return '${delta.inDays}d ago';
    }
    if (delta.inHours >= 1) return '${delta.inHours}h ago';
    return '${delta.inMinutes}m ago';
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.colors});

  final RewindColors colors;

  @override
  Widget build(BuildContext context) =>
      Divider(height: 1, thickness: 1, color: colors.hairline);
}

class _Row extends StatelessWidget {
  const _Row({
    required this.colors,
    required this.icon,
    required this.title,
    required this.detail,
    this.trailing,
  });

  final RewindColors colors;
  final IconData icon;
  final String title;
  final String detail;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: colors.ink),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontFamily: OmiFonts.sans,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.ink,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                detail,
                style: TextStyle(
                  fontFamily: OmiFonts.sans,
                  fontSize: 12,
                  height: 1.35,
                  color: colors.muted,
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    ),
  );
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.colors,
    required this.keyValue,
    required this.icon,
    required this.title,
    required this.detail,
    required this.value,
    required this.onChanged,
  });

  final RewindColors colors;
  final Key keyValue;
  final IconData icon;
  final String title;
  final String detail;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => _Row(
    colors: colors,
    icon: icon,
    title: title,
    detail: detail,
    trailing: Switch(key: keyValue, value: value, onChanged: onChanged),
  );
}
