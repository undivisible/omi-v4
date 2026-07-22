import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/worker_http.dart';
import '../app_services.dart';
import '../capabilities/desktop_capabilities.dart';
import '../integrations/apple_eventkit.dart';
import '../integrations/apple_eventkit_import.dart';
import '../integrations/eventkit_task_sync.dart';
import '../native/generated/signals/signals.dart'
    show AssistantProvider, SystemAudioCaptureMode;
import '../providers/providers.dart';
import '../settings/settings.dart';

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
}

bool get _isWindowsStyle =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

bool get _isMacDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    required this.services,
    this.previewMode = false,
    super.key,
  });

  final AppServices services;
  final bool previewMode;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsSection selected = SettingsSection.account;

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
            title: 'Sign out',
            detail: 'Sign out of this device. Your account data stays intact.',
            trailing: TextButton(
              key: const Key('sign_out'),
              onPressed: () => unawaited(services.auth.signOut()),
              child: const Text('Sign out'),
            ),
          ),
          DeleteAccountTile(services: services),
        ],
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
        if (!previewMode && services.oauthConnections != null) ...[
          _SubscriptionSignInTile(
            client: services.oauthConnections!,
            provider: 'openai',
            title: 'Sign in with ChatGPT',
          ),
          _SubscriptionSignInTile(
            client: services.oauthConnections!,
            provider: 'xai',
            title: 'Sign in with xAI',
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final windows = _isWindowsStyle;
    final hairline = scheme.onSurface.withValues(alpha: .12);
    final available = sections;
    final active = available.contains(selected) ? selected : available.first;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760, maxHeight: 560),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(windows ? 8 : 12),
                  border: Border.all(color: hairline),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(windows ? 8 : 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 192,
                        child: ColoredBox(
                          color: scheme.onSurface.withValues(alpha: .03),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  16,
                                  16,
                                  10,
                                ),
                                child: Semantics(
                                  header: true,
                                  child: Text(
                                    'Settings',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: scheme.onSurface,
                                    ),
                                  ),
                                ),
                              ),
                              for (final section in available)
                                _SidebarItem(
                                  section: section,
                                  selected: section == active,
                                  windows: windows,
                                  onTap: () =>
                                      setState(() => selected = section),
                                ),
                            ],
                          ),
                        ),
                      ),
                      VerticalDivider(width: 1, color: hairline),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      active.label,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: scheme.onSurface,
                                      ),
                                    ),
                                  ),
                                  if (Navigator.of(context).canPop())
                                    IconButton(
                                      key: const Key('settings_close'),
                                      tooltip: 'Close settings',
                                      iconSize: 18,
                                      onPressed: () =>
                                          Navigator.of(context).maybePop(),
                                      icon: const Icon(Icons.close_rounded),
                                    ),
                                ],
                              ),
                            ),
                            Divider(height: 1, color: hairline),
                            Expanded(
                              child: ListView(
                                padding: const EdgeInsets.all(16),
                                children: [
                                  _SettingsGroup(children: _tiles(active)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
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
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: .72);
    final label = Row(
      children: [
        if (windows)
          Container(
            width: 3,
            height: 16,
            margin: const EdgeInsets.only(right: 9),
            decoration: BoxDecoration(
              color: selected ? scheme.primary : Colors.transparent,
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
        color: selected && !windows
            ? scheme.primary.withValues(alpha: .14)
            : selected
            ? scheme.onSurface.withValues(alpha: .06)
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
    final scheme = Theme.of(context).colorScheme;
    final hairline = scheme.onSurface.withValues(alpha: .1);
    if (_isWindowsStyle) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final child in children)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: scheme.onSurface.withValues(alpha: .03),
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
        color: scheme.onSurface.withValues(alpha: .03),
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
    super.key,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 18, color: scheme.onSurface),
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
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            trailing,
          ],
        ),
      ),
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
              color: Theme.of(context).colorScheme.onSurfaceVariant,
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

class _SubscriptionSignInTile extends StatefulWidget {
  const _SubscriptionSignInTile({
    required this.client,
    required this.provider,
    required this.title,
  });

  final WorkerOAuthClient client;
  final String provider;
  final String title;

  @override
  State<_SubscriptionSignInTile> createState() =>
      _SubscriptionSignInTileState();
}

class _SubscriptionSignInTileState extends State<_SubscriptionSignInTile> {
  late Future<List<String>> connected = widget.client.connectedProviders();
  Timer? poll;
  String? userCode;
  String? error;

  @override
  void dispose() {
    poll?.cancel();
    super.dispose();
  }

  Future<void> connect() async {
    setState(() {
      error = null;
      userCode = null;
    });
    final OAuthDeviceStart start;
    try {
      start = await widget.client.startDevice(widget.provider);
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
      return;
    }
    if (!mounted) return;
    setState(() => userCode = start.userCode);
    if (start.verificationUri.isNotEmpty) {
      final uri = Uri.tryParse(start.verificationUri);
      if (uri != null && uri.scheme == 'https') {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
    poll?.cancel();
    var interval = start.interval;
    final deadline = DateTime.now().add(Duration(seconds: start.expiresIn));
    void schedule() {
      poll = Timer(Duration(seconds: interval), () async {
        if (!mounted) return;
        if (DateTime.now().isAfter(deadline)) {
          setState(() {
            error = 'Code expired — try again.';
            userCode = null;
          });
          return;
        }
        final OAuthDevicePoll status;
        try {
          status = await widget.client.pollDevice(
            widget.provider,
            start.deviceCode,
          );
        } catch (failure) {
          if (mounted) {
            setState(() {
              error = '$failure';
              userCode = null;
            });
          }
          return;
        }
        if (!mounted) return;
        switch (status) {
          case OAuthDevicePoll.connected:
            setState(() {
              userCode = null;
              connected = widget.client.connectedProviders();
            });
          case OAuthDevicePoll.slowDown:
            interval += 5;
            schedule();
          case OAuthDevicePoll.pending:
            schedule();
        }
      });
    }

    schedule();
  }

  Future<void> disconnect() async {
    await widget.client.disconnect(widget.provider);
    if (mounted) {
      setState(() => connected = widget.client.connectedProviders());
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<String>>(
    future: connected,
    builder: (context, snapshot) {
      final isConnected = snapshot.data?.contains(widget.provider) ?? false;
      return _Tile(
        icon: Icons.link_rounded,
        title: widget.title,
        detail: error != null
            ? error!
            : userCode != null
            ? 'Enter code $userCode in the browser window, then wait here.'
            : isConnected
            ? 'Connected — your subscription covers chat usage.'
            : 'Use your existing subscription instead of paying for '
                  'managed usage.',
        trailing: TextButton(
          key: Key('oauth_${widget.provider}'),
          onPressed: userCode != null
              ? null
              : isConnected
              ? disconnect
              : connect,
          child: Text(
            userCode != null
                ? 'Waiting…'
                : isConnected
                ? 'Disconnect'
                : 'Connect',
          ),
        ),
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
