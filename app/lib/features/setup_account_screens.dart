import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/worker_http.dart';
import '../app_services.dart';
import '../capabilities/desktop_capabilities.dart';
import '../channels/channels.dart';
import '../conversations/conversations.dart';
import '../integrations/apple_eventkit.dart';
import '../integrations/apple_eventkit_import.dart';
import '../integrations/eventkit_task_sync.dart';
import '../native/generated/signals/signals.dart'
    show AssistantProvider, SystemAudioCaptureMode;
import '../providers/providers.dart';
import '../settings/settings.dart';
import '../ui/burst_glow.dart';
import '../ui/scroll_edge_fade.dart';
import 'meeting_notes.dart';

enum SettingsSection {
  account('Account', Icons.person_outline_rounded),
  plan('Plan & Billing', Icons.credit_card_outlined),
  providers('AI Providers', Icons.key_outlined),
  permissions('Permissions', Icons.lock_outline_rounded),
  calendar('Calendar', Icons.calendar_today_outlined),
  advanced('Advanced', Icons.tune_rounded);

  const SettingsSection(this.label, this.icon);

  final String label;
  final IconData icon;

  /// Resolves the wire name a deep link carries (the native settings window
  /// is a separate engine, so the requested anchor crosses a method channel
  /// as a plain string). Unknown names land on the default section.
  static SettingsSection? tryParse(String? name) {
    if (name == null) return null;
    for (final section in values) {
      if (section.name == name) return section;
    }
    return null;
  }
}

bool get _isWindowsStyle =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

bool get _isMacDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// The warm-paper palette, pinned rather than read from the ambient theme so
/// settings looks identical in its own native window and in the in-window
/// route fallback. Values are the hub's — nothing new is introduced here.
class _SettingsColors {
  const _SettingsColors._({
    required this.page,
    required this.panel,
    required this.hairline,
    required this.ink,
    required this.muted,
  });

  const _SettingsColors.light()
    : this._(
        page: const Color(0xfff7f6f1),
        panel: const Color(0xfffffefa),
        hairline: const Color(0x1a000000),
        ink: const Color(0xff171716),
        muted: const Color(0xff706e68),
      );

  const _SettingsColors.dark()
    : this._(
        page: const Color(0xff1c1c1a),
        panel: const Color(0xff232321),
        hairline: const Color(0x1affffff),
        ink: const Color(0xfff4f2ea),
        muted: const Color(0xffa6a49c),
      );

  final Color page;
  final Color panel;
  final Color hairline;
  final Color ink;
  final Color muted;

  static _SettingsColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const _SettingsColors.dark()
      : const _SettingsColors.light();
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    required this.services,
    this.previewMode = false,
    this.initialSection,
    this.numbersLoader,
    super.key,
  });

  final AppServices services;
  final bool previewMode;

  /// Where a deep link asked settings to land. Null opens the first section.
  final SettingsSection? initialSection;

  /// Override for the hidden "Omi in numbers" figures, so tests can supply
  /// known stores instead of the ambient ones.
  final OmiNumbersLoader? numbersLoader;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SettingsSection selected =
      widget.initialSection ?? SettingsSection.account;

  @override
  void didUpdateWidget(SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final requested = widget.initialSection;
    if (requested != null && requested != oldWidget.initialSection) {
      selected = requested;
    }
  }

  List<SettingsSection> get sections => [
    SettingsSection.account,
    SettingsSection.plan,
    SettingsSection.providers,
    if (_isMacDesktop || _isWindowsStyle) SettingsSection.permissions,
    if (_isMacDesktop) SettingsSection.calendar,
    SettingsSection.advanced,
  ];

  List<Widget> _tiles(SettingsSection section) {
    final services = widget.services;
    final previewMode = widget.previewMode;
    return switch (section) {
      SettingsSection.account => [
        _InfoTile(
          icon: Icons.person_outline_rounded,
          title: 'Sign in',
          detail: previewMode
              ? 'Account access is disabled in the interface preview.'
              : services.auth.snapshot.session?.displayName ??
                    services.configurationMessage,
        ),
        if (!previewMode && services.auth.snapshot.session != null) ...[
          _Tile(
            icon: Icons.logout_rounded,
            title: 'Log out',
            detail: 'Sign out of this device. Your account data stays intact.',
            trailing: TextButton(
              key: const Key('sign_out'),
              onPressed: () => unawaited(services.auth.signOut()),
              child: const Text('Log out'),
            ),
          ),
          DeleteAccountTile(services: services),
          if (services.channels != null)
            _ChannelLinkTile(client: services.channels!),
        ] else if (!previewMode)
          DeleteLocalDataTile(services: services),
      ],
      SettingsSection.plan => [
        if (previewMode || services.billing == null)
          const _InfoTile(
            icon: Icons.credit_card_outlined,
            title: 'Plan unavailable',
            detail: 'Sign in to manage your plan.',
          )
        else
          _PlanTile(client: services.billing!),
      ],
      SettingsSection.providers => [
        if (previewMode || kIsWeb)
          const _InfoTile(
            icon: Icons.key_outlined,
            title: 'AI providers',
            detail: 'Configure BYOK securely from a native Omi app.',
          )
        else ...[
          _ProviderTile(services: services),
          const _InfoTile(
            icon: Icons.savings_outlined,
            title: 'Bring your own key',
            detail:
                'Managed Omi AI runs about \$35/mo of usage. A personal API '
                'key runs the same usage for about \$5/mo — configure it '
                'above.',
          ),
        ],
      ],
      SettingsSection.permissions => [
        ScreenCaptureSetupTile(
          gateway: services.capabilities,
          previewMode: previewMode,
        ),
        if (_isMacDesktop)
          SystemAudioCaptureModeTile(
            services: services,
            previewMode: previewMode,
          ),
      ],
      SettingsSection.calendar => [
        for (final source in AppleEventKitSource.values)
          AppleEventKitConnectionTile(
            services: services,
            source: source,
            previewMode: previewMode,
          ),
        EventKitProactiveSyncTile(previewMode: previewMode),
      ],
      SettingsSection.advanced => [
        if (previewMode || !services.canUseApi)
          const _InfoTile(
            icon: Icons.shield_outlined,
            title: 'Agent control unavailable',
            detail: 'Sign in to load your approval policy.',
          )
        else
          _AgentControlTile(client: services.settings!),
        if (!previewMode && services.settings != null)
          _ProductionHealthTile(client: services.settings!),
      ],
    };
  }

  /// The orb click streak that reveals "Omi in numbers". Clicks have to land
  /// within [_orbStreakWindow] of each other, so ordinary single clicks on
  /// the mark never accumulate into it.
  static const orbStreakTarget = 5;
  static const _orbStreakWindow = Duration(milliseconds: 700);

  final _orbKey = GlobalKey();
  int _orbStreak = 0;
  DateTime? _lastOrbClick;
  Offset? _burstAt;
  bool _numbersRevealed = false;

  void _orbClicked() {
    final now = DateTime.now();
    final last = _lastOrbClick;
    _lastOrbClick = now;
    final streak = last != null && now.difference(last) <= _orbStreakWindow
        ? _orbStreak + 1
        : 1;
    if (streak < orbStreakTarget) {
      setState(() => _orbStreak = streak);
      return;
    }
    setState(() {
      _orbStreak = 0;
      _lastOrbClick = null;
      _numbersRevealed = true;
      // Reduced motion gets the reward without the fireworks.
      _burstAt = MediaQuery.disableAnimationsOf(context) ? null : _orbCentre();
    });
  }

  Offset? _orbCentre() {
    final box = _orbKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final overlay = context.findRenderObject();
    if (overlay is! RenderBox || !overlay.hasSize) return null;
    return box.localToGlobal(box.size.center(Offset.zero), ancestor: overlay);
  }

  @override
  Widget build(BuildContext context) {
    final colors = _SettingsColors.of(context);
    final windows = _isWindowsStyle;
    final radius = BorderRadius.circular(windows ? 8 : 12);
    final available = sections;
    final active = available.contains(selected) ? selected : available.first;
    final sidebar = DecoratedBox(
      key: const Key('settings_sidebar'),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: radius,
        border: Border.all(color: colors.hairline),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
              child: Row(
                children: [
                  _SettingsOrb(
                    key: _orbKey,
                    streak: _orbStreak,
                    onPressed: _orbClicked,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        'Settings',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: colors.ink,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            for (final section in available)
              _SidebarItem(
                section: section,
                selected: section == active,
                windows: windows,
                onTap: () => setState(() => selected = section),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 0, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  active.label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: colors.ink,
                  ),
                ),
              ),
              if (Navigator.of(context).canPop())
                IconButton(
                  key: const Key('settings_close'),
                  tooltip: 'Close settings',
                  iconSize: 18,
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close_rounded),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: colors.hairline),
        Expanded(
          child: ScrollEdgeFade(
            color: colors.page,
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              children: [
                if (_numbersRevealed) ...[
                  OmiNumbersCard(
                    loader: widget.numbersLoader ?? _defaultNumbersLoader,
                    onDismiss: () => setState(() => _numbersRevealed = false),
                  ),
                  const SizedBox(height: 12),
                ],
                _SettingsGroup(children: _tiles(active)),
              ],
            ),
          ),
        ),
      ],
    );
    return Scaffold(
      backgroundColor: colors.page,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 760,
                    maxHeight: 560,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 192, child: sidebar),
                      const SizedBox(width: 16),
                      Expanded(child: content),
                    ],
                  ),
                ),
              ),
            ),
            if (_burstAt case final centre?)
              Positioned(
                left: centre.dx,
                top: centre.dy,
                child: FractionalTranslation(
                  translation: const Offset(-.5, -.5),
                  child: OmiBurstGlow(
                    key: const Key('settings_orb_burst'),
                    progress: 1,
                    complete: true,
                    baseDiameter: 40,
                    growth: 120,
                    onBurstDone: () {
                      if (mounted) setState(() => _burstAt = null);
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<List<OmiNumber>> _defaultNumbersLoader() =>
      loadOmiNumbers(widget.services);
}

/// The Omi mark in the settings header. Every click springs it a little
/// further, which is the only hint that clicking it repeatedly does anything.
class _SettingsOrb extends StatelessWidget {
  const _SettingsOrb({
    required this.streak,
    required this.onPressed,
    super.key,
  });

  final int streak;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      label: 'Omi',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: const Key('settings_orb'),
          onTap: onPressed,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: 1 + streak * .05),
            duration: reducedMotion
                ? Duration.zero
                : const Duration(milliseconds: 420),
            curve: Curves.elasticOut,
            builder: (context, scale, child) =>
                Transform.scale(scale: reducedMotion ? 1 : scale, child: child),
            child: Container(
              width: 22,
              height: 22,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Color(0xfffffcec), Color(0xffe9e4cf)],
                ),
              ),
              child: const Icon(
                Icons.blur_on_rounded,
                color: Color(0xff171716),
                size: 14,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.section,
    required this.selected,
    required this.windows,
    required this.onTap,
  });

  final SettingsSection section;
  final bool selected;
  final bool windows;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = _SettingsColors.of(context);
    final foreground = selected ? colors.ink : colors.muted;
    final label = Row(
      children: [
        if (windows)
          Container(
            width: 3,
            height: 16,
            margin: const EdgeInsets.only(right: 9),
            decoration: BoxDecoration(
              color: selected ? colors.ink : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        Icon(section.icon, size: 16, color: foreground),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            section.label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: foreground,
            ),
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected
            ? colors.ink.withValues(alpha: windows ? .06 : .08)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(windows ? 4 : 6),
        child: InkWell(
          key: Key('settings_section_${section.name}'),
          borderRadius: BorderRadius.circular(windows ? 4 : 6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: label,
          ),
        ),
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = _SettingsColors.of(context);
    final hairline = colors.hairline;
    if (_isWindowsStyle) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final child in children)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: colors.panel,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: hairline),
              ),
              child: child,
            ),
        ],
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < children.length; index += 1) ...[
            if (index > 0) Divider(height: 1, indent: 42, color: hairline),
            children[index],
          ],
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.detail,
    required this.trailing,
    this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget trailing;
  // When set, the whole row is the button — never a button on the right of a
  // row.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = _SettingsColors.of(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
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
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: colors.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );
    return Material(
      type: MaterialType.transparency,
      child: onTap == null ? row : InkWell(onTap: onTap, child: row),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => _Tile(
    icon: icon,
    title: title,
    detail: detail,
    trailing: const SizedBox.shrink(),
  );
}

class _StateTile extends StatelessWidget {
  const _StateTile({
    required this.icon,
    required this.title,
    required this.detail,
    required this.state,
    this.onPressed,
    this.actionTooltip,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String state;
  final VoidCallback? onPressed;
  final String? actionTooltip;

  @override
  Widget build(BuildContext context) => _Tile(
    icon: icon,
    title: title,
    detail: detail,
    trailing: onPressed == null
        ? Text(
            state,
            style: TextStyle(
              fontSize: 12,
              color: _SettingsColors.of(context).muted,
            ),
          )
        : IconButton(
            tooltip: actionTooltip ?? 'Connect',
            iconSize: 18,
            onPressed: onPressed,
            icon: const Icon(Icons.arrow_forward_rounded),
          ),
  );
}

class DeleteAccountTile extends StatefulWidget {
  const DeleteAccountTile({required this.services, super.key});

  final AppServices services;

  @override
  State<DeleteAccountTile> createState() => _DeleteAccountTileState();
}

class _DeleteAccountTileState extends State<DeleteAccountTile> {
  bool deleting = false;
  String? error;

  Future<void> _confirmAndDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This permanently deletes your account and all data stored with '
          'Omi — memories, conversations, settings, and connections. This '
          'cannot be undone.',
        ),
        actions: [
          TextButton(
            key: const Key('delete_account_cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('delete_account_confirm'),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      deleting = true;
      error = null;
    });
    try {
      await widget.services.deleteAccount();
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Tile(
    icon: Icons.delete_forever_outlined,
    title: 'Delete account',
    detail:
        error ??
        (deleting
            ? 'Deleting your account…'
            : 'Permanently delete your account and every piece of stored '
                  'data.'),
    trailing: TextButton(
      key: const Key('delete_account'),
      style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
      onPressed: deleting ? null : _confirmAndDelete,
      child: const Text('Delete'),
    ),
  );
}

// Links a Telegram or iMessage chat: the user texts the bot, gets a short
// code, and types it here. The whole row is the button, matching the account
// tiles around it.
class _ChannelLinkTile extends StatefulWidget {
  const _ChannelLinkTile({required this.client});

  final ChannelClient client;

  @override
  State<_ChannelLinkTile> createState() => _ChannelLinkTileState();
}

class _ChannelLinkTileState extends State<_ChannelLinkTile> {
  late Future<Set<ChannelProvider>> _linked = _load();

  Future<Set<ChannelProvider>> _load() async {
    final linked = <ChannelProvider>{};
    for (final channel in ChannelProvider.values) {
      try {
        if (await widget.client.isLinked(channel)) linked.add(channel);
      } on ChannelClientException {
        // A single channel's status failing must not blank the row.
      }
    }
    return linked;
  }

  void _reload() {
    setState(() => _linked = _load());
  }

  String _label(ChannelProvider channel) => switch (channel) {
    ChannelProvider.telegram => 'Telegram',
    ChannelProvider.blooio => 'iMessage',
  };

  Future<void> _openSheet(Set<ChannelProvider> linked) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => _ChannelLinkDialog(
        client: widget.client,
        linked: linked,
        label: _label,
      ),
    );
    if (changed == true && mounted) _reload();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Set<ChannelProvider>>(
    future: _linked,
    builder: (context, snapshot) {
      final linked = snapshot.data ?? const <ChannelProvider>{};
      final detail = switch (snapshot.connectionState) {
        ConnectionState.done when snapshot.hasError =>
          'Could not check linked chats. Tap to try again.',
        ConnectionState.done when linked.isEmpty =>
          'Text the Omi bot on Telegram or iMessage, then enter the code it '
              'sends back.',
        ConnectionState.done =>
          'Linked: ${linked.map(_label).join(', ')}. Tap to link another or '
              'unlink.',
        _ => 'Checking your linked chats…',
      };
      return _Tile(
        key: const Key('channel_link_tile'),
        icon: Icons.chat_bubble_outline_rounded,
        title: 'Link a chat',
        detail: detail,
        trailing: Icon(
          Icons.arrow_forward_rounded,
          size: 18,
          color: _SettingsColors.of(context).muted,
        ),
        onTap: snapshot.connectionState == ConnectionState.done
            ? () => _openSheet(linked)
            : null,
      );
    },
  );
}

class _ChannelLinkDialog extends StatefulWidget {
  const _ChannelLinkDialog({
    required this.client,
    required this.linked,
    required this.label,
  });

  final ChannelClient client;
  final Set<ChannelProvider> linked;
  final String Function(ChannelProvider) label;

  @override
  State<_ChannelLinkDialog> createState() => _ChannelLinkDialogState();
}

class _ChannelLinkDialogState extends State<_ChannelLinkDialog> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _success;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    final code = _controller.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    try {
      final channel = await widget.client.redeemCode(code);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _success = '${widget.label(channel)} is now linked.';
        _controller.clear();
      });
    } on ChannelApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.statusCode == 404
            ? 'That code is unknown or has expired. Text the bot again for a '
                  'fresh one.'
            : error.message;
      });
    } on ChannelClientException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    }
  }

  Future<void> _unlink(ChannelProvider channel) async {
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    try {
      await widget.client.unlink(channel);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _success = '${widget.label(channel)} is unlinked.';
        widget.linked.remove(channel);
      });
    } on ChannelClientException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = _SettingsColors.of(context);
    return AlertDialog(
      backgroundColor: colors.panel,
      title: const Text('Link a chat'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Message the Omi bot on Telegram or iMessage and it will reply '
            'with a short code. Enter it below.',
            style: TextStyle(fontSize: 12, height: 1.35, color: colors.muted),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('channel_link_code_field'),
            controller: _controller,
            enabled: !_busy,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Link code',
              hintText: 'e.g. K7QP2RM',
            ),
            onSubmitted: (_) => _redeem(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: const TextStyle(fontSize: 12, color: Colors.redAccent),
            ),
          ],
          if (_success != null) ...[
            const SizedBox(height: 10),
            Text(_success!, style: TextStyle(fontSize: 12, color: colors.ink)),
          ],
          if (widget.linked.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Linked chats',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.ink,
              ),
            ),
            for (final channel in widget.linked)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Expanded(child: Text(widget.label(channel))),
                    TextButton(
                      onPressed: _busy ? null : () => _unlink(channel),
                      child: const Text('Unlink'),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(true),
          child: const Text('Done'),
        ),
        FilledButton(
          key: const Key('channel_link_submit'),
          onPressed: _busy ? null : _redeem,
          child: const Text('Link'),
        ),
      ],
    );
  }
}

class DeleteLocalDataTile extends StatefulWidget {
  const DeleteLocalDataTile({required this.services, super.key});

  final AppServices services;

  @override
  State<DeleteLocalDataTile> createState() => _DeleteLocalDataTileState();
}

class _DeleteLocalDataTileState extends State<DeleteLocalDataTile> {
  bool deleting = false;
  String? error;

  Future<void> _confirmAndDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete data?'),
        content: const Text(
          'This erases everything Omi stores on this device — conversations, '
          'transcripts, notes, tasks, and your onboarding profile — and '
          'returns you to onboarding. This cannot be undone.',
        ),
        actions: [
          TextButton(
            key: const Key('delete_local_data_cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('delete_local_data_confirm'),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      deleting = true;
      error = null;
    });
    try {
      await widget.services.deleteAccount();
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Tile(
    icon: Icons.delete_forever_outlined,
    title: 'Delete data',
    detail:
        error ??
        (deleting
            ? 'Deleting your local data…'
            : 'Erase everything stored on this device and start over.'),
    trailing: TextButton(
      key: const Key('delete_local_data'),
      style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
      onPressed: deleting ? null : _confirmAndDelete,
      child: const Text('Delete'),
    ),
  );
}

class _ProductionHealthTile extends StatefulWidget {
  const _ProductionHealthTile({required this.client});

  final SettingsClient client;

  @override
  State<_ProductionHealthTile> createState() => _ProductionHealthTileState();
}

class _ProductionHealthTileState extends State<_ProductionHealthTile> {
  late Future<SetupHealth> health = widget.client.getSetupHealth();

  @override
  void didUpdateWidget(_ProductionHealthTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      health = widget.client.getSetupHealth();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<SetupHealth>(
    future: health,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const _StateTile(
          icon: Icons.cloud_sync_outlined,
          title: 'Production services',
          detail: 'Checking backend availability…',
          state: 'Checking',
        );
      }
      if (snapshot.hasError) {
        return _StateTile(
          icon: Icons.cloud_off_outlined,
          title: 'Production services',
          detail: '${snapshot.error}',
          state: 'Unavailable',
        );
      }
      final services = snapshot.data!.services;
      final missing = services.entries
          .where((entry) => !entry.value)
          .map((entry) => entry.key)
          .join(', ');
      return _StateTile(
        icon: Icons.cloud_done_outlined,
        title: 'Production services',
        detail: missing.isEmpty ? 'Everything is ready' : missing,
        state:
            '${services.values.where((ready) => ready).length}/${services.length} ready',
      );
    },
  );
}

class ScreenCaptureSetupTile extends StatefulWidget {
  const ScreenCaptureSetupTile({
    required this.gateway,
    required this.previewMode,
    super.key,
  });

  final DesktopCapabilityGateway gateway;
  final bool previewMode;

  @override
  State<ScreenCaptureSetupTile> createState() => _ScreenCaptureSetupTileState();
}

class _ScreenCaptureSetupTileState extends State<ScreenCaptureSetupTile> {
  late Future<CapabilityStatus> status = _check();
  bool requesting = false;

  Future<CapabilityStatus> _check() async =>
      (await widget.gateway.check())[CoreCapability.screenCapture] ??
      const CapabilityStatus(
        state: CapabilityState.error,
        detail: 'Screen-capture capability status is missing.',
      );

  Future<void> request() async {
    setState(() => requesting = true);
    try {
      await widget.gateway.request(CoreCapability.screenCapture);
      if (mounted) status = _check();
    } catch (error) {
      if (mounted) {
        status = Future.value(
          CapabilityStatus(
            state: CapabilityState.error,
            detail: 'Could not request screen-capture access: $error',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          requesting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: status,
    builder: (context, snapshot) {
      final value = snapshot.data;
      final state = snapshot.hasError
          ? 'Check failed'
          : switch (value?.state) {
              CapabilityState.granted => 'Granted',
              CapabilityState.notRequired => 'Per capture',
              CapabilityState.notApplicable => 'Not applicable',
              CapabilityState.actionRequired => 'Action required',
              CapabilityState.error => 'Check failed',
              _ => 'Checking',
            };
      return _StateTile(
        icon: Icons.lock_outline_rounded,
        title: 'Allow screen understanding',
        detail: widget.previewMode
            ? 'Native access is disabled in the interface preview.'
            : requesting
            ? 'Requesting access…'
            : snapshot.hasError
            ? 'Could not check screen-capture access: ${snapshot.error}'
            : value?.detail ?? 'Checking screen-capture access…',
        state: state,
        onPressed:
            !widget.previewMode &&
                !requesting &&
                value?.state == CapabilityState.actionRequired
            ? request
            : null,
        actionTooltip: 'Review screen-capture access',
      );
    },
  );
}

class SystemAudioCaptureModeTile extends StatefulWidget {
  const SystemAudioCaptureModeTile({
    required this.services,
    required this.previewMode,
    super.key,
  });

  final AppServices services;
  final bool previewMode;

  @override
  State<SystemAudioCaptureModeTile> createState() =>
      _SystemAudioCaptureModeTileState();
}

class _SystemAudioCaptureModeTileState
    extends State<SystemAudioCaptureModeTile> {
  late Future<SystemAudioCaptureMode> mode =
      widget.services.systemAudioCaptureMode;
  bool saving = false;

  static const _labels = {
    SystemAudioCaptureMode.always: 'Always',
    SystemAudioCaptureMode.onlyDuringMeetings: 'Only during meetings',
    SystemAudioCaptureMode.never: 'Never',
  };

  Future<void> _select(SystemAudioCaptureMode value) async {
    setState(() => saving = true);
    try {
      await widget.services.setSystemAudioCaptureMode(value);
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() {
          saving = false;
          mode = widget.services.systemAudioCaptureMode;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<SystemAudioCaptureMode>(
    future: mode,
    builder: (context, snapshot) => _Tile(
      icon: Icons.speaker_group_outlined,
      title: 'System audio capture',
      detail: widget.previewMode
          ? 'Native capture is disabled in the interface preview.'
          : 'Choose when Omi may transcribe meeting and system audio.',
      trailing: widget.previewMode || snapshot.data == null || saving
          ? Text(
              snapshot.data == null ? 'Loading' : _labels[snapshot.data]!,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          : DropdownButton<SystemAudioCaptureMode>(
              value: snapshot.data,
              underline: const SizedBox.shrink(),
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              items: SystemAudioCaptureMode.values
                  .map(
                    (value) => DropdownMenuItem(
                      value: value,
                      child: Text(_labels[value]!),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) _select(value);
              },
            ),
    ),
  );
}

class AppleEventKitConnectionTile extends StatefulWidget {
  const AppleEventKitConnectionTile({
    required this.services,
    required this.source,
    required this.previewMode,
    this.eventKit,
    super.key,
  });

  final AppServices services;
  final AppleEventKitSource source;
  final bool previewMode;
  final AppleEventKitService? eventKit;

  @override
  State<AppleEventKitConnectionTile> createState() =>
      _AppleEventKitConnectionTileState();
}

class _AppleEventKitConnectionTileState
    extends State<AppleEventKitConnectionTile> {
  late final eventKit = widget.eventKit ?? AppleEventKitService();
  late Future<AppleEventKitAuthorization> authorization = eventKit.status(
    widget.source,
  );
  bool busy = false;
  int? imported;
  String? error;

  Future<void> connect() async {
    final uid = widget.services.auth.snapshot.session?.uid;
    if (!widget.services.chatReady || uid == null) {
      setState(() => error = 'Sign in and finish native setup first.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      var value = await eventKit.status(widget.source);
      if (value == AppleEventKitAuthorization.notDetermined) {
        value = await eventKit.request(widget.source);
      }
      if (value != AppleEventKitAuthorization.fullAccess) {
        if (mounted) setState(() => authorization = Future.value(value));
        return;
      }
      final count = await AppleEventKitImportCoordinator(
        eventKit: eventKit,
        hub: widget.services.nativeHub,
        personId: uid,
      ).import(widget.source);
      if (mounted) {
        setState(() {
          authorization = Future.value(value);
          imported = count;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: authorization,
    builder: (context, snapshot) {
      final name = widget.source == AppleEventKitSource.calendar
          ? 'Calendar'
          : 'Reminders';
      final value = snapshot.data;
      final connected = value == AppleEventKitAuthorization.fullAccess;
      final detail =
          error ??
          (widget.previewMode
              ? 'Native access is disabled in the interface preview.'
              : imported != null
              ? '$imported items queued for memory'
              : connected
              ? 'Ready to add recent $name data to memory'
              : value == AppleEventKitAuthorization.denied ||
                    value == AppleEventKitAuthorization.restricted
              ? 'Enable $name in System Settings → Privacy & Security'
              : 'Add your Apple $name context to memory');
      return _StateTile(
        icon: widget.source == AppleEventKitSource.calendar
            ? Icons.calendar_today_outlined
            : Icons.check_circle_outline_rounded,
        title: 'Connect Apple $name',
        detail: busy ? 'Importing…' : detail,
        state: imported != null
            ? 'Connected'
            : connected
            ? 'Access granted'
            : 'Not connected',
        onPressed: widget.previewMode || busy ? null : connect,
        actionTooltip: connected ? 'Import Apple $name' : 'Connect Apple $name',
      );
    },
  );
}

class EventKitProactiveSyncTile extends StatefulWidget {
  const EventKitProactiveSyncTile({
    required this.previewMode,
    this.eventKit,
    this.store,
    super.key,
  });

  final bool previewMode;
  final AppleEventKitWriter? eventKit;
  final EventKitTaskSyncStore? store;

  @override
  State<EventKitProactiveSyncTile> createState() =>
      _EventKitProactiveSyncTileState();
}

class _EventKitProactiveSyncTileState extends State<EventKitProactiveSyncTile> {
  late final AppleEventKitWriter eventKit =
      widget.eventKit ?? AppleEventKitService();
  late final EventKitTaskSyncStore store =
      widget.store ?? PreferencesEventKitTaskSyncStore();
  bool enabled = false;
  bool needsPermission = false;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      store
          .enabled()
          .then((value) {
            if (mounted) setState(() => enabled = value);
          })
          .catchError((Object _) {}),
    );
  }

  Future<void> _toggle(bool value) async {
    if (busy) return;
    setState(() {
      busy = true;
      needsPermission = false;
    });
    try {
      if (!value) {
        await store.setEnabled(false);
        if (mounted) setState(() => enabled = false);
        return;
      }
      var granted = true;
      for (final source in AppleEventKitSource.values) {
        var authorization = await eventKit.status(source);
        if (authorization == AppleEventKitAuthorization.notDetermined) {
          authorization = await eventKit.request(source);
        }
        if (authorization != AppleEventKitAuthorization.fullAccess) {
          granted = false;
        }
      }
      if (!granted) {
        await store.setEnabled(false);
        if (mounted) {
          setState(() {
            enabled = false;
            needsPermission = true;
          });
        }
        return;
      }
      await store.setEnabled(true);
      if (mounted) setState(() => enabled = true);
    } catch (_) {
      if (mounted) setState(() => needsPermission = true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Tile(
    icon: Icons.event_available_outlined,
    title: 'Let Omi add to Calendar & Reminders',
    detail: widget.previewMode || !eventKit.available
        ? 'Available on a native Omi app with EventKit access.'
        : needsPermission
        ? 'Needs permission — enable Calendar and Reminders access in '
              'System Settings → Privacy & Security.'
        : enabled
        ? 'Tasks with a due time are added to your Calendar and Reminders.'
        : 'Off. Turn on to mirror due tasks into Calendar and Reminders.',
    trailing: Switch(
      key: const Key('eventkit_proactive_sync_switch'),
      value: enabled,
      onChanged: widget.previewMode || !eventKit.available || busy
          ? null
          : (value) => unawaited(_toggle(value)),
    ),
  );
}

class _AgentControlTile extends StatefulWidget {
  const _AgentControlTile({required this.client});

  final SettingsClient client;

  @override
  State<_AgentControlTile> createState() => _AgentControlTileState();
}

class _AgentControlTileState extends State<_AgentControlTile> {
  late Future<SettingsSnapshot> snapshot = widget.client.getSettings();

  @override
  void didUpdateWidget(_AgentControlTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      snapshot = widget.client.getSettings();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<SettingsSnapshot>(
    future: snapshot,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const _InfoTile(
          icon: Icons.sync_rounded,
          title: 'Loading agent control',
          detail: 'Retrieving your approval policy…',
        );
      }
      if (snapshot.hasError) {
        return _InfoTile(
          icon: Icons.error_outline_rounded,
          title: 'Agent control could not load',
          detail: '${snapshot.error}',
        );
      }
      final settings = snapshot.data!.effectivePolicy;
      return _InfoTile(
        icon: Icons.shield_outlined,
        title: 'Agent control',
        detail:
            '${settings.approvalMode.name} approvals · Proactive ${settings.proactiveRecommendations ? 'on' : 'off'}',
      );
    },
  );
}

class _ProviderTile extends StatefulWidget {
  const _ProviderTile({required this.services});

  final AppServices services;

  @override
  State<_ProviderTile> createState() => _ProviderTileState();
}

class _ProviderTileState extends State<_ProviderTile> {
  late Future<List<ProviderCredential>> credentials =
      widget.services.allProviderCredentials;
  bool expanded = false;

  void refresh() => setState(() {
    credentials = widget.services.allProviderCredentials;
  });

  Future<void> configure(ProviderCredential? existing) async {
    var provider = existing?.provider ?? AssistantProvider.openAi;
    final model = TextEditingController(text: existing?.model);
    final secret = TextEditingController();
    final endpoint = TextEditingController(text: existing?.endpoint);
    String? error;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Bring your own model'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<AssistantProvider>(
                  initialValue: provider,
                  decoration: const InputDecoration(labelText: 'Provider'),
                  items: AssistantProvider.values
                      .where((value) => value != AssistantProvider.worker)
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(value.name),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => update(() => provider = value!),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: model,
                  decoration: const InputDecoration(labelText: 'Model'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: secret,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'API key'),
                ),
                if (provider == AssistantProvider.compatible) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: endpoint,
                    decoration: const InputDecoration(
                      labelText: 'HTTPS endpoint',
                    ),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(error!, style: const TextStyle(color: Colors.redAccent)),
                ],
              ],
            ),
          ),
          actions: [
            if (existing != null)
              TextButton(
                onPressed: () async {
                  await widget.services.removeProviderCredential(
                    existing.provider,
                  );
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('Remove'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  await widget.services.saveProviderCredential(
                    ProviderCredential(
                      provider: provider,
                      model: model.text,
                      credential: secret.text,
                      endpoint: provider == AssistantProvider.compatible
                          ? endpoint.text
                          : null,
                    ),
                  );
                  if (context.mounted) Navigator.pop(context);
                } catch (failure) {
                  update(() => error = '$failure');
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    model.dispose();
    secret.dispose();
    endpoint.dispose();
    if (mounted) refresh();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<ProviderCredential>>(
    future: credentials,
    builder: (context, snapshot) {
      final values = snapshot.data ?? const <ProviderCredential>[];
      final loaded = snapshot.connectionState == ConnectionState.done;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Tile(
            icon: Icons.key_outlined,
            title: 'Bring your own AI',
            detail: !loaded
                ? 'Checking secure storage…'
                : snapshot.hasError
                ? '${snapshot.error}'
                : values.isEmpty
                ? 'Using your plan default'
                : values.length == 1
                ? '${values.first.provider.name} · ${values.first.model}'
                : '${values.length} providers · '
                      '${values.first.provider.name} routes first',
            trailing: TextButton(
              key: const Key('toggle_byok'),
              onPressed: loaded
                  ? () => setState(() => expanded = !expanded)
                  : null,
              child: Text(expanded ? 'Hide' : 'Show'),
            ),
          ),
          if (expanded && loaded) ...[
            for (final value in values)
              _Tile(
                key: ValueKey('provider_${value.provider.name}'),
                icon: Icons.subdirectory_arrow_right_rounded,
                title: '${value.provider.name} · ${value.model}',
                detail: value.endpoint ?? 'Key stored securely on this device',
                trailing: IconButton(
                  tooltip: 'Edit provider',
                  iconSize: 18,
                  onPressed: () => configure(value),
                  icon: const Icon(Icons.edit_outlined),
                ),
              ),
            _Tile(
              key: const Key('add_provider'),
              icon: Icons.add_rounded,
              title: 'Add a provider',
              detail:
                  'Add multiple providers or custom endpoints; the newest '
                  'routes automatically.',
              trailing: IconButton(
                tooltip: 'Add provider',
                iconSize: 18,
                onPressed: () => configure(null),
                icon: const Icon(Icons.arrow_forward_rounded),
              ),
            ),
          ],
        ],
      );
    },
  );
}

class _PlanTile extends StatefulWidget {
  const _PlanTile({required this.client});

  final WorkerBillingClient client;

  @override
  State<_PlanTile> createState() => _PlanTileState();
}

class _PlanTileState extends State<_PlanTile> {
  late Future<BillingEntitlement> entitlement = widget.client.getEntitlement();
  bool opening = false;
  String? error;

  Future<void> open(BillingEntitlement value) async {
    setState(() {
      opening = true;
      error = null;
    });
    try {
      final uri = value.plan == OmiPlan.pro && value.active
          ? await widget.client.createPortal()
          : await widget.client.createCheckout();
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError('Could not open billing');
      }
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<BillingEntitlement>(
    future: entitlement,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const _InfoTile(
          icon: Icons.sync_rounded,
          title: 'Loading plan',
          detail: 'Checking your entitlement…',
        );
      }
      if (snapshot.hasError) {
        return _InfoTile(
          icon: Icons.error_outline_rounded,
          title: 'Plan could not load',
          detail: '${snapshot.error}',
        );
      }
      final value = snapshot.data!;
      return _Tile(
        icon: Icons.credit_card_outlined,
        title: value.plan == OmiPlan.pro && value.active ? 'Omi AI' : 'Omi',
        detail:
            error ??
            (value.plan == OmiPlan.pro && value.active
                ? 'Managed AI is active'
                : 'BYOK and local AI'),
        trailing: IconButton(
          tooltip: value.plan == OmiPlan.pro && value.active
              ? 'Manage billing'
              : 'Upgrade to Omi AI',
          iconSize: 18,
          onPressed: opening ? null : () => open(value),
          icon: opening
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.arrow_forward_rounded),
        ),
      );
    },
  );
}

/// One line of the hidden "Omi in numbers" card.
final class OmiNumber {
  const OmiNumber(this.label, this.value);

  final String label;
  final String value;
}

typedef OmiNumbersLoader = Future<List<OmiNumber>> Function();

/// Counts what this device already stores. Every line is a real figure read
/// back out of an existing store; anything that cannot be counted from what
/// is already on disk is left out rather than estimated, so an empty list
/// here means there is genuinely nothing to show yet.
Future<List<OmiNumber>> loadOmiNumbers(AppServices services) async {
  DateTime? earliest;
  void observe(DateTime moment) {
    if (moment.millisecondsSinceEpoch <= 0) return;
    final known = earliest;
    if (known == null || moment.isBefore(known)) earliest = moment;
  }

  var meetings = const <MeetingNote>[];
  try {
    meetings = await services.meetingNotes.list();
  } catch (_) {}
  var transcribedMinutes = 0;
  for (final note in meetings) {
    final span = note.endedAt.difference(note.startedAt);
    if (span > Duration.zero) transcribedMinutes += span.inMinutes;
    observe(note.startedAt.toUtc());
  }

  var messages = const <ConversationMessage>[];
  try {
    messages = await services.replayConversation();
  } catch (_) {}
  for (final message in messages) {
    observe(
      DateTime.fromMillisecondsSinceEpoch(message.createdAt, isUtc: true),
    );
  }

  final numbers = <OmiNumber>[
    if (messages.isNotEmpty)
      OmiNumber('Messages exchanged', '${messages.length}'),
    if (meetings.isNotEmpty)
      OmiNumber('Meetings recorded', '${meetings.length}'),
    if (transcribedMinutes > 0)
      OmiNumber('Minutes transcribed', '$transcribedMinutes'),
  ];
  if (earliest case final first?) {
    final days = DateTime.now().toUtc().difference(first).inDays;
    if (days > 0) numbers.add(OmiNumber('Days with Omi', '$days'));
  }
  return numbers;
}

/// The reward behind the settings orb. It is a card in the normal scroll, not
/// a modal: it never blocks anything, and its own control puts it away.
class OmiNumbersCard extends StatefulWidget {
  const OmiNumbersCard({
    required this.loader,
    required this.onDismiss,
    super.key,
  });

  final OmiNumbersLoader loader;
  final VoidCallback onDismiss;

  @override
  State<OmiNumbersCard> createState() => _OmiNumbersCardState();
}

class _OmiNumbersCardState extends State<OmiNumbersCard> {
  late final Future<List<OmiNumber>> numbers = widget.loader();

  @override
  Widget build(BuildContext context) {
    final colors = _SettingsColors.of(context);
    return DecoratedBox(
      key: const Key('omi_numbers_card'),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome_outlined, size: 16, color: colors.ink),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Your Omi in numbers',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colors.ink,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('omi_numbers_dismiss'),
                  tooltip: 'Hide',
                  iconSize: 16,
                  onPressed: widget.onDismiss,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            FutureBuilder<List<OmiNumber>>(
              future: numbers,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return Padding(
                    padding: const EdgeInsets.only(left: 24, right: 12),
                    child: Text(
                      'Counting…',
                      style: TextStyle(fontSize: 12, color: colors.muted),
                    ),
                  );
                }
                final values = snapshot.data ?? const <OmiNumber>[];
                if (values.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.only(left: 24, right: 12),
                    child: Text(
                      'Nothing to count yet — come back after a few '
                      'conversations.',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: colors.muted,
                      ),
                    ),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.only(left: 24, right: 12, top: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final number in values)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  number.label,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.muted,
                                  ),
                                ),
                              ),
                              Text(
                                number.value,
                                key: Key('omi_number_${number.label}'),
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: colors.ink,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
