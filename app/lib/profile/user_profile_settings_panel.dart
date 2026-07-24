import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../native/native_hub.dart';
import '../random_id.dart';
import 'user_profile.dart';

class UserProfileSettingsPanel extends StatefulWidget {
  const UserProfileSettingsPanel({
    required this.services,
    this.previewMode = false,
    super.key,
  });

  final AppServices services;
  final bool previewMode;

  @override
  State<UserProfileSettingsPanel> createState() =>
      _UserProfileSettingsPanelState();
}

enum _Role { assistant, user }

final class _Turn {
  _Turn({required this.role, required this.text});

  final _Role role;
  String text;
}

class _UserProfileSettingsPanelState extends State<UserProfileSettingsPanel> {
  final _store = PreferencesUserProfileStore();
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _turns = <_Turn>[];

  StreamSubscription<NativeEvent>? _events;
  UserProfileDocument _document = const UserProfileDocument();
  String? _activeRequestId;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    unawaited(_events?.cancel() ?? Future<void>.value());
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String? get _uid => widget.services.auth.snapshot.session?.uid;

  Future<void> _bootstrap() async {
    final uid = _uid;
    if (uid == null || widget.previewMode) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _turns
          ..clear()
          ..add(
            _Turn(
              role: _Role.assistant,
              text: widget.previewMode
                  ? 'Sign in to talk through the personal context Omi uses in prompts.'
                  : 'Sign in to review and update what Omi knows about you.',
            ),
          );
      });
      return;
    }
    final document = await _store.load(uid);
    final name =
        document.name ??
        widget.services.auth.snapshot.session?.displayName ??
        await widget.services.localProfileName();
    final seeded =
        document.name == null && name != null && name.trim().isNotEmpty
        ? document.copyWith(name: name.trim())
        : document;
    if (!mounted) return;
    setState(() {
      _document = seeded;
      _loading = false;
      _turns
        ..clear()
        ..add(
          _Turn(role: _Role.assistant, text: openingProfileChatMessage(seeded)),
        );
    });
    _events = widget.services.nativeEvents.listen(_onNativeEvent);
    _scrollToEnd();
  }

  void _onNativeEvent(NativeEvent event) {
    final requestId = _activeRequestId;
    if (requestId == null) return;
    switch (event) {
      case NativeEventAssistantDelta(:final value)
          when value.requestId == requestId:
        final last = _turns.isEmpty ? null : _turns.last;
        if (last == null || last.role != _Role.assistant) {
          _turns.add(_Turn(role: _Role.assistant, text: value.text));
        } else {
          last.text += value.text;
        }
        if (mounted) setState(() {});
        _scrollToEnd();
        if (value.finalSegment) {
          final reply =
              (_turns.isNotEmpty && _turns.last.role == _Role.assistant)
              ? _turns.last.text
              : value.text;
          unawaited(_finishTurn(reply));
        }
      case NativeEventError(:final value) when value.requestId == requestId:
        setState(() {
          _busy = false;
          _activeRequestId = null;
          _turns.add(
            _Turn(
              role: _Role.assistant,
              text: 'I couldn’t update that just now. Try again in a moment.',
            ),
          );
        });
        _scrollToEnd();
      default:
        break;
    }
  }

  Future<void> _finishTurn(String rawReply) async {
    try {
      final patch = parseUserProfilePatch(rawReply);
      final visible = stripProfilePatchMarkup(rawReply);
      if (_turns.isNotEmpty && _turns.last.role == _Role.assistant) {
        _turns.last.text = visible.isEmpty
            ? (patch == null
                  ? 'Got it — nothing to change.'
                  : 'Updated. Here’s the prompt I will use now:\n\n${formatPromptPreview(applyUserProfilePatch(_document, patch))}')
            : visible;
      }
      if (patch != null) {
        final next = applyUserProfilePatch(_document, patch);
        await _persist(next);
        if (!mounted) return;
        setState(() => _document = next);
        if (visible.isEmpty || !visible.contains('About the user:')) {
          _turns.add(
            _Turn(
              role: _Role.assistant,
              text: 'Updated prompt:\n\n${formatPromptPreview(next)}',
            ),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _activeRequestId = null;
        });
        _scrollToEnd();
      }
    }
  }

  Future<void> _persist(UserProfileDocument document) async {
    final uid = _uid;
    if (uid == null) return;
    await _store.save(uid, document);
    final databasePath = await widget.services.memoryDatabasePath(uid);
    await _store.writeSidecar(databasePath, document);
    final memory = widget.services.memory;
    if (memory != null) {
      unawaited(
        syncUserProfileToMemory(
          memory: memory,
          document: document,
        ).catchError((_) {}),
      );
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy || _uid == null || widget.previewMode) return;
    if (!widget.services.nativeHub.available) {
      setState(() {
        _turns.add(
          _Turn(
            role: _Role.assistant,
            text:
                'Native assistant isn’t available here, so I can’t edit the profile yet.',
          ),
        );
      });
      return;
    }
    final requestId = 'profile-chat-${randomId()}';
    setState(() {
      _busy = true;
      _activeRequestId = requestId;
      _turns
        ..add(_Turn(role: _Role.user, text: text))
        ..add(_Turn(role: _Role.assistant, text: ''));
      _input.clear();
    });
    _scrollToEnd();
    try {
      widget.services.nativeHub.sendMessage(
        requestId: requestId,
        text: text,
        memoryContext: profileEditorFraming(_document),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _activeRequestId = null;
        if (_turns.isNotEmpty && _turns.last.role == _Role.assistant) {
          _turns.last.text =
              'I couldn’t reach the assistant. Check that you’re signed in and try again.';
        }
      });
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = _ProfileChatColors.of(context);
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: colors.ink),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Personal context',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Talk through what Omi should know — beliefs, goals, and the rest.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: colors.muted,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.hairline),
          Expanded(
            child: ListView.builder(
              key: const Key('user_profile_chat_list'),
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              itemCount: _turns.length,
              itemBuilder: (context, index) {
                final turn = _turns[index];
                return _Bubble(turn: turn, colors: colors);
              },
            ),
          ),
          Divider(height: 1, color: colors.hairline),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('user_profile_chat_input'),
                    controller: _input,
                    focusNode: _focus,
                    enabled: !_busy && _uid != null && !widget.previewMode,
                    minLines: 1,
                    maxLines: 4,
                    style: TextStyle(fontSize: 13, color: colors.ink),
                    cursorColor: colors.ink,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Ask to change a belief, goal, or preference…',
                      hintStyle: TextStyle(fontSize: 13, color: colors.muted),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                    onSubmitted: (_) => unawaited(_send()),
                  ),
                ),
                IconButton(
                  key: const Key('user_profile_chat_send'),
                  tooltip: 'Send',
                  onPressed: _busy || _uid == null || widget.previewMode
                      ? null
                      : () => unawaited(_send()),
                  icon: _busy
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colors.muted,
                          ),
                        )
                      : Icon(Icons.arrow_upward_rounded, color: colors.ink),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.turn, required this.colors});

  final _Turn turn;
  final _ProfileChatColors colors;

  @override
  Widget build(BuildContext context) {
    final isUser = turn.role == _Role.user;
    final text = turn.text.isEmpty && !isUser ? '…' : turn.text;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: isUser ? colors.page : colors.panel,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.hairline),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: SelectableText(
                text,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: isUser ? colors.ink : colors.ink,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileChatColors {
  const _ProfileChatColors({
    required this.page,
    required this.panel,
    required this.hairline,
    required this.ink,
    required this.muted,
  });

  final Color page;
  final Color panel;
  final Color hairline;
  final Color ink;
  final Color muted;

  static _ProfileChatColors of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark
        ? const _ProfileChatColors(
            page: Color(0xff1c1c1a),
            panel: Color(0xff232321),
            hairline: Color(0x1affffff),
            ink: Color(0xfff4f2ea),
            muted: Color(0xffa6a49c),
          )
        : const _ProfileChatColors(
            page: Color(0xfff7f6f1),
            panel: Color(0xfffffefa),
            hairline: Color(0x1a000000),
            ink: Color(0xff171716),
            muted: Color(0xff706e68),
          );
  }
}
