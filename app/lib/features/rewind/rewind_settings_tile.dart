import 'dart:async';

import 'package:flutter/material.dart';

import '../../ui/omi_typography.dart';
import 'rewind_models.dart';
import 'rewind_privacy.dart';
import 'rewind_runtime.dart';
import 'rewind_service.dart';
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
  const RewindSettingsTile({this.previewMode = false, this.service, super.key});

  final bool previewMode;

  /// Injected in tests; otherwise resolved from [RewindRuntime].
  final RewindService? service;

  @override
  State<RewindSettingsTile> createState() => _RewindSettingsTileState();
}

class _RewindSettingsTileState extends State<RewindSettingsTile> {
  RewindService? _service;
  final _excludeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final injected = widget.service;
    if (injected != null) {
      _attach(injected);
    } else if (!widget.previewMode && rewindSupported) {
      unawaited(
        RewindRuntime.instance.resolve(captures: false).then((service) {
          if (mounted) _attach(service);
        }),
      );
    }
  }

  void _attach(RewindService service) {
    setState(() => _service = service);
    service.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _service?.removeListener(_onChanged);
    _excludeController.dispose();
    super.dispose();
  }

  Future<void> _confirmDeleteAll(RewindService service) async {
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
    if (confirmed ?? false) await service.deleteAll();
  }

  @override
  Widget build(BuildContext context) {
    final colors = RewindColors.of(context);
    final service = _service;
    if (service == null) {
      return _Row(
        colors: colors,
        icon: Icons.history_toggle_off_rounded,
        title: 'Rewind',
        detail: widget.previewMode || !rewindSupported
            ? 'Continuous screen history is available on macOS only.'
            : 'Loading…',
      );
    }

    final settings = service.settings;
    final frames = service.frames;
    final megabytes = service.totalBytes / (1024 * 1024);
    final oldest = frames.isEmpty ? null : frames.first.capturedAt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Row(
          colors: colors,
          icon: Icons.history_toggle_off_rounded,
          title: 'Record my screen',
          detail: settings.enabled
              ? 'A red dot sits in the menu bar the whole time Rewind is on. '
                    'Pause it there or here.'
              : 'Off. Rewind captures nothing until you turn this on.',
          trailing: Switch(
            key: const Key('rewind_enabled'),
            value: settings.enabled,
            onChanged: (value) => unawaited(service.setEnabled(value)),
          ),
        ),
        if (settings.enabled) ...[
          _Divider(colors: colors),
          _Row(
            colors: colors,
            icon: settings.paused
                ? Icons.play_arrow_rounded
                : Icons.pause_rounded,
            title: settings.paused ? 'Paused' : _statusTitle(service),
            detail: _statusDetail(service),
            trailing: TextButton(
              key: const Key('rewind_pause'),
              onPressed: () => unawaited(service.setPaused(!settings.paused)),
              child: Text(settings.paused ? 'Resume' : 'Pause'),
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
            trailing: DropdownButton<RewindRetention>(
              key: const Key('rewind_retention'),
              value: RewindRetention.options.contains(settings.retention)
                  ? settings.retention
                  : RewindRetention.options[2],
              underline: const SizedBox.shrink(),
              items: [
                for (final option in RewindRetention.options)
                  DropdownMenuItem(value: option, child: Text(option.label)),
              ],
              onChanged: (value) =>
                  value == null ? null : unawaited(service.setRetention(value)),
            ),
          ),
          _Divider(colors: colors),
          _Row(
            colors: colors,
            icon: Icons.password_rounded,
            title: 'Never record these apps',
            detail:
                '${settings.privacy.deniedBundleIds.length} apps excluded, '
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
                  unawaited(service.denyBundleId(value));
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
            value: settings.privacy.skipPrivateBrowsing,
            onChanged: (value) => unawaited(
              service.setPrivacy(
                settings.privacy.copyWith(skipPrivateBrowsing: value),
              ),
            ),
          ),
          _Divider(colors: colors),
          _Toggle(
            colors: colors,
            keyValue: const Key('rewind_ocr'),
            icon: Icons.text_fields_rounded,
            title: 'Read text off frames on this device',
            detail:
                'Apple’s Vision framework transcribes each frame locally '
                'so the timeline is searchable. Nothing is uploaded.',
            value: settings.privacy.readOnScreenText,
            onChanged: (value) => unawaited(
              service.setPrivacy(
                settings.privacy.copyWith(readOnScreenText: value),
              ),
            ),
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
            value: settings.privacy.recordWindowTitles,
            onChanged: (value) => unawaited(
              service.setPrivacy(
                settings.privacy.copyWith(recordWindowTitles: value),
              ),
            ),
          ),
        ],
        _Divider(colors: colors),
        _Row(
          colors: colors,
          icon: Icons.sd_storage_outlined,
          title: 'On this Mac',
          detail: frames.isEmpty
              ? 'No frames stored.'
              : '${frames.length} frames, ${megabytes.toStringAsFixed(1)} MB, '
                    'oldest ${_ago(oldest!)}. Stored under ~/.omi/rewind.',
          trailing: TextButton(
            key: const Key('rewind_open_timeline'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RewindTimelineScreen(service: service),
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
                    unawaited(service.deleteLast(const Duration(hours: 1))),
                child: const Text('Last hour'),
              ),
              const SizedBox(width: 4),
              TextButton(
                key: const Key('rewind_delete_all'),
                onPressed: () => unawaited(_confirmDeleteAll(service)),
                child: const Text('Everything'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _statusTitle(RewindService service) =>
      service.recording ? 'Recording' : 'Waiting';

  static String _statusDetail(RewindService service) {
    final reason = service.lastSkipReason;
    if (service.settings.paused) {
      return 'No frames are being captured while paused.';
    }
    return switch (reason) {
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

  static String _ago(DateTime at) {
    final delta = DateTime.now().difference(at);
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
