import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../native/native_hub.dart';
import '../ui/omi_typography.dart';

class _SpeechColors {
  const _SpeechColors._({
    required this.ink,
    required this.muted,
    required this.hairline,
    required this.panel,
    required this.page,
    required this.warning,
  });

  const _SpeechColors.light()
    : this._(
        ink: const Color(0xff171716),
        muted: const Color(0xff706e68),
        hairline: const Color(0x1a000000),
        panel: const Color(0xfffffefa),
        page: const Color(0xfff7f6f1),
        warning: const Color(0xffd97757),
      );

  const _SpeechColors.dark()
    : this._(
        ink: const Color(0xfff4f2ea),
        muted: const Color(0xffa6a49c),
        hairline: const Color(0x1affffff),
        panel: const Color(0xff232321),
        page: const Color(0xff1c1c1a),
        warning: const Color(0xffe8705f),
      );

  final Color ink;
  final Color muted;
  final Color hairline;
  final Color panel;
  final Color page;
  final Color warning;

  static _SpeechColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const _SpeechColors.dark()
      : const _SpeechColors.light();
}

/// The settings surface for the voices Omi has learned.
///
/// The hub owns every decision about voiceprints — this screen only names,
/// merges, forgets and pauses them, and never sees a vector. Every command
/// answers with the whole list, so the screen holds no local model of a
/// profile: it sends, waits for the answer that carries its own request id,
/// and replaces what it is showing.
class SpeechProfilesScreen extends StatefulWidget {
  const SpeechProfilesScreen({required this.services, super.key});

  final AppServices services;

  @override
  State<SpeechProfilesScreen> createState() => _SpeechProfilesScreenState();
}

class _SpeechProfilesScreenState extends State<SpeechProfilesScreen> {
  static const _signedOut =
      'Sign in to see the voices Omi has learned. Voiceprints are kept per '
      'account on this device.';

  StreamSubscription<NativeEvent>? _subscription;
  SpeechProfileScope? _scope;
  List<SpeechProfileRecord>? _profiles;
  String? _unavailable;
  String? _pendingRequestId;
  int _sequence = 0;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _subscription = widget.services.nativeHub.events.listen(_onEvent);
    unawaited(_open());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Future<void> _open() async {
    final uid = widget.services.auth.snapshot.session?.uid;
    if (uid == null) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _unavailable = _signedOut;
      });
      return;
    }
    final directory = await widget.services.dataDirectory();
    if (!mounted) return;
    final scope = SpeechProfileScope(directory: directory, uid: uid);
    _scope = scope;
    _send(
      (requestId) => widget.services.nativeHub.listSpeechProfiles(
        requestId: requestId,
        scope: scope,
      ),
    );
  }

  void _send(void Function(String requestId) command) {
    final requestId = 'speech-profiles-${_sequence++}';
    _pendingRequestId = requestId;
    setState(() => _busy = true);
    try {
      command(requestId);
    } on NativeHubUnavailable catch (error) {
      _pendingRequestId = null;
      setState(() {
        _busy = false;
        _unavailable = error.message;
      });
    }
  }

  void _onEvent(NativeEvent event) {
    if (event is! NativeEventSpeechProfiles) return;
    final update = event.value;
    if (update.requestId != _pendingRequestId) return;
    _pendingRequestId = null;
    final payload = update.payload;
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (payload is SpeechProfilePayloadProfiles) {
        _profiles = payload.profiles;
        _unavailable = null;
      } else if (payload is SpeechProfilePayloadUnavailable) {
        _profiles = null;
        _unavailable = payload.detail;
      }
    });
  }

  String _label(SpeechProfileRecord record) =>
      record.displayName ?? 'this unnamed voice';

  Future<void> _rename(SpeechProfileRecord record) async {
    final scope = _scope;
    if (scope == null) return;
    final name = await showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => _NameDialog(initial: record.displayName),
    );
    if (name == null || !mounted) return;
    final trimmed = name.trim();
    _send(
      (requestId) => widget.services.nativeHub.renameSpeechProfile(
        requestId: requestId,
        scope: scope,
        profileId: record.id,
        displayName: trimmed.isEmpty ? null : trimmed,
      ),
    );
  }

  void _clearName(SpeechProfileRecord record) {
    final scope = _scope;
    if (scope == null) return;
    _send(
      (requestId) => widget.services.nativeHub.renameSpeechProfile(
        requestId: requestId,
        scope: scope,
        profileId: record.id,
      ),
    );
  }

  void _togglePause(SpeechProfileRecord record) {
    final scope = _scope;
    if (scope == null) return;
    _send(
      (requestId) => widget.services.nativeHub.pauseSpeechLearning(
        requestId: requestId,
        scope: scope,
        profileId: record.id,
        paused: !record.learningPaused,
      ),
    );
  }

  Future<void> _forget(SpeechProfileRecord record) async {
    final scope = _scope;
    if (scope == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => _ConfirmDialog(
        title: 'Forget ${_label(record)}?',
        message:
            'Omi deletes all ${_voiceprints(record.embeddingCount)} it holds '
            'for ${_label(record)}. This voice stops being recognised, and '
            'the voiceprints cannot be recovered — only speaking again will '
            'teach Omi this voice from scratch.',
        action: 'Forget voice',
        confirmKey: const Key('speech_profile_forget_confirm'),
      ),
    );
    if (confirmed != true || !mounted) return;
    _send(
      (requestId) => widget.services.nativeHub.forgetSpeechProfile(
        requestId: requestId,
        scope: scope,
        profileId: record.id,
      ),
    );
  }

  Future<void> _merge(SpeechProfileRecord source) async {
    final scope = _scope;
    final profiles = _profiles;
    if (scope == null || profiles == null) return;
    final others = profiles.where((other) => other.id != source.id).toList();
    if (others.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('There is no other voice to merge this one into.'),
        ),
      );
      return;
    }
    final target = await showDialog<SpeechProfileRecord>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => _MergeTargetDialog(candidates: others),
    );
    if (target == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => _ConfirmDialog(
        title: 'Merge into ${_label(target)}?',
        message:
            'Omi moves the ${_voiceprints(source.embeddingCount)} held for '
            '${_label(source)} into ${_label(target)}. ${_label(source)} '
            'disappears from this list for good, and everything Omi hears in '
            'that voice is recognised as ${_label(target)} from now on.',
        action: 'Merge voices',
        confirmKey: const Key('speech_profile_merge_confirm'),
      ),
    );
    if (confirmed != true || !mounted) return;
    _send(
      (requestId) => widget.services.nativeHub.mergeSpeechProfiles(
        requestId: requestId,
        scope: scope,
        targetProfileId: target.id,
        sourceProfileId: source.id,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = _SpeechColors.of(context);
    return Scaffold(
      backgroundColor: colors.page,
      appBar: AppBar(
        backgroundColor: colors.page,
        elevation: 0,
        title: Text(
          'Voices',
          style: TextStyle(
            fontFamily: OmiFonts.sans,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: colors.ink,
          ),
        ),
      ),
      body: SafeArea(child: _body(colors)),
    );
  }

  Widget _body(_SpeechColors colors) {
    final unavailable = _unavailable;
    if (unavailable != null) {
      return _Notice(
        key: const Key('speech_profiles_unavailable'),
        colors: colors,
        icon: Icons.cloud_off_rounded,
        title: 'Voices are not available',
        detail: unavailable,
      );
    }
    final profiles = _profiles;
    if (profiles == null) {
      return const Center(
        key: Key('speech_profiles_loading'),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (profiles.isEmpty) {
      return _Notice(
        key: const Key('speech_profiles_empty'),
        colors: colors,
        icon: Icons.record_voice_over_outlined,
        title: 'No voices learned yet',
        detail:
            'Omi learns a voice while it listens. Once it has heard someone '
            'enough to tell them apart, they show up here to be named.',
      );
    }
    return ListView.builder(
      key: const Key('speech_profiles_list'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: profiles.length,
      itemBuilder: (context, index) => _ProfileTile(
        colors: colors,
        record: profiles[index],
        enabled: !_busy,
        onRename: () => unawaited(_rename(profiles[index])),
        onClearName: () => _clearName(profiles[index]),
        onTogglePause: () => _togglePause(profiles[index]),
        onMerge: () => unawaited(_merge(profiles[index])),
        onForget: () => unawaited(_forget(profiles[index])),
      ),
    );
  }
}

String _voiceprints(int count) =>
    count == 1 ? '1 voiceprint' : '$count voiceprints';

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.colors,
    required this.record,
    required this.enabled,
    required this.onRename,
    required this.onClearName,
    required this.onTogglePause,
    required this.onMerge,
    required this.onForget,
  });

  final _SpeechColors colors;
  final SpeechProfileRecord record;
  final bool enabled;
  final VoidCallback onRename;
  final VoidCallback onClearName;
  final VoidCallback onTogglePause;
  final VoidCallback onMerge;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final named = record.displayName != null;
    final detail = [
      record.kind == 'owner' ? 'You' : 'Someone else',
      _voiceprints(record.embeddingCount),
      if (record.learningPaused) 'Learning paused',
    ].join(' · ');
    return Container(
      key: Key('speech_profile_${record.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border.all(color: colors.hairline),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  named ? record.displayName! : 'Unnamed voice',
                  style: TextStyle(
                    fontFamily: OmiFonts.sans,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    fontStyle: named ? FontStyle.normal : FontStyle.italic,
                    color: named ? colors.ink : colors.muted,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: TextStyle(
                    fontFamily: OmiFonts.sans,
                    fontSize: 12,
                    color: colors.muted,
                  ),
                ),
                if (!named) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    key: Key('speech_profile_name_${record.id}'),
                    onPressed: enabled ? onRename : null,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Give this voice a name'),
                  ),
                ],
              ],
            ),
          ),
          PopupMenuButton<String>(
            key: Key('speech_profile_menu_${record.id}'),
            enabled: enabled,
            icon: Icon(Icons.more_horiz_rounded, color: colors.muted),
            onSelected: (value) {
              switch (value) {
                case 'rename':
                  onRename();
                case 'clear':
                  onClearName();
                case 'pause':
                  onTogglePause();
                case 'merge':
                  onMerge();
                case 'forget':
                  onForget();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                key: Key('speech_profile_rename_item_${record.id}'),
                value: 'rename',
                child: Text(named ? 'Rename' : 'Name this voice'),
              ),
              if (named)
                PopupMenuItem(
                  key: Key('speech_profile_clear_item_${record.id}'),
                  value: 'clear',
                  child: const Text('Clear the name'),
                ),
              PopupMenuItem(
                key: Key('speech_profile_pause_item_${record.id}'),
                value: 'pause',
                child: Text(
                  record.learningPaused ? 'Resume learning' : 'Pause learning',
                ),
              ),
              PopupMenuItem(
                key: Key('speech_profile_merge_item_${record.id}'),
                value: 'merge',
                child: const Text('Merge into another voice'),
              ),
              PopupMenuItem(
                key: Key('speech_profile_forget_item_${record.id}'),
                value: 'forget',
                child: Text(
                  'Forget this voice',
                  style: TextStyle(color: colors.warning),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.colors,
    required this.icon,
    required this.title,
    required this.detail,
    super.key,
  });

  final _SpeechColors colors;
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 28, color: colors.muted),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: OmiFonts.sans,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colors.ink,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: OmiFonts.sans,
              fontSize: 12,
              height: 1.5,
              color: colors.muted,
            ),
          ),
        ],
      ),
    ),
  );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial});

  final String? initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial == null ? 'Name this voice' : 'Rename voice'),
    content: TextField(
      key: const Key('speech_profile_name_field'),
      controller: _controller,
      autofocus: true,
      decoration: const InputDecoration(
        isDense: true,
        hintText: 'Who is this?',
      ),
      onSubmitted: (value) => Navigator.of(context).pop(value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      TextButton(
        key: const Key('speech_profile_name_save'),
        onPressed: () => Navigator.of(context).pop(_controller.text),
        child: const Text('Save'),
      ),
    ],
  );
}

class _MergeTargetDialog extends StatelessWidget {
  const _MergeTargetDialog({required this.candidates});

  final List<SpeechProfileRecord> candidates;

  @override
  Widget build(BuildContext context) => SimpleDialog(
    key: const Key('speech_profile_merge_target'),
    title: const Text('Merge into which voice?'),
    children: [
      for (final candidate in candidates)
        SimpleDialogOption(
          key: Key('speech_profile_merge_target_${candidate.id}'),
          onPressed: () => Navigator.of(context).pop(candidate),
          child: Text(candidate.displayName ?? 'Unnamed voice'),
        ),
      SimpleDialogOption(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
    ],
  );
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({
    required this.title,
    required this.message,
    required this.action,
    required this.confirmKey,
  });

  final String title;
  final String message;
  final String action;
  final Key confirmKey;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(title),
    content: Text(message),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Keep it'),
      ),
      TextButton(
        key: confirmKey,
        style: TextButton.styleFrom(
          foregroundColor: _SpeechColors.of(context).warning,
        ),
        onPressed: () => Navigator.of(context).pop(true),
        child: Text(action),
      ),
    ],
  );
}
