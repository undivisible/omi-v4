import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/worker_http.dart';
import '../app_services.dart';
import '../capabilities/desktop_capabilities.dart';
import '../channels/channels.dart';
import '../integrations/apple_eventkit.dart';
import '../integrations/apple_eventkit_import.dart';
import '../native/generated/signals/signals.dart' show AssistantProvider;
import '../providers/providers.dart';
import '../settings/settings.dart';
import '../ui/omi_ui.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.services,
    this.previewMode = false,
    super.key,
  });

  final AppServices services;
  final bool previewMode;

  @override
  Widget build(BuildContext context) => PageList(
    title: 'Settings',
    subtitle: 'Identity, plan, providers, connections, and agent control.',
    children: [
      _AccountTile(
        icon: Icons.person_outline_rounded,
        title: 'Sign in',
        detail: previewMode
            ? 'Account access is disabled in the interface preview.'
            : services.auth.snapshot.session?.displayName ??
                  services.configurationMessage,
      ),
      if (previewMode || services.billing == null)
        const _AccountTile(
          icon: Icons.credit_card_outlined,
          title: 'Plan unavailable',
          detail: 'Sign in to manage your plan.',
        )
      else
        _PlanTile(client: services.billing!),
      if (previewMode || kIsWeb)
        const _AccountTile(
          icon: Icons.key_outlined,
          title: 'AI providers',
          detail: 'Configure BYOK securely from a native Omi app.',
        )
      else ...[
        _ProviderTile(services: services),
        const _AccountTile(
          icon: Icons.savings_outlined,
          title: 'Bring your own key',
          detail:
              'Managed Omi AI runs about \$35/mo of usage. A personal API key '
              'runs the same usage for about \$5/mo — configure it above.',
        ),
      ],
      if (previewMode || !services.canUseApi)
        const _AccountTile(
          icon: Icons.shield_outlined,
          title: 'Agent control unavailable',
          detail: 'Sign in to load your approval policy.',
        )
      else
        _AgentControlTile(client: services.settings!),
      if (!previewMode && services.settings != null)
        _ProductionHealthTile(client: services.settings!),
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.macOS ||
              defaultTargetPlatform == TargetPlatform.windows))
        ScreenCaptureSetupTile(
          gateway: services.capabilities,
          previewMode: previewMode,
        ),
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS)
        for (final source in AppleEventKitSource.values)
          AppleEventKitConnectionTile(
            services: services,
            source: source,
            previewMode: previewMode,
          ),
    ],
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
        return const _SetupTile(
          icon: Icons.cloud_sync_outlined,
          title: 'Production services',
          detail: 'Checking backend availability…',
          state: 'Checking',
        );
      }
      if (snapshot.hasError) {
        return _SetupTile(
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
      return _SetupTile(
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
      return _SetupTile(
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
      return _SetupTile(
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
        return const _AccountTile(
          icon: Icons.sync_rounded,
          title: 'Loading agent control',
          detail: 'Retrieving your approval policy…',
        );
      }
      if (snapshot.hasError) {
        return _AccountTile(
          icon: Icons.error_outline_rounded,
          title: 'Agent control could not load',
          detail: '${snapshot.error}',
        );
      }
      final settings = snapshot.data!.effectivePolicy;
      return _AccountTile(
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
          BaseTile(
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
              BaseTile(
                key: ValueKey('provider_${value.provider.name}'),
                icon: Icons.subdirectory_arrow_right_rounded,
                title: '${value.provider.name} · ${value.model}',
                detail: value.endpoint ?? 'Key stored securely on this device',
                trailing: IconButton(
                  tooltip: 'Edit provider',
                  onPressed: () => configure(value),
                  icon: const Icon(Icons.edit_outlined),
                ),
              ),
            BaseTile(
              key: const Key('add_provider'),
              icon: Icons.add_rounded,
              title: 'Add a provider',
              detail:
                  'Add multiple providers or custom endpoints; the newest '
                  'routes automatically.',
              trailing: IconButton(
                tooltip: 'Add provider',
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
        return const _AccountTile(
          icon: Icons.sync_rounded,
          title: 'Loading plan',
          detail: 'Checking your entitlement…',
        );
      }
      if (snapshot.hasError) {
        return _AccountTile(
          icon: Icons.error_outline_rounded,
          title: 'Plan could not load',
          detail: '${snapshot.error}',
        );
      }
      final value = snapshot.data!;
      return BaseTile(
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

class ChannelConnectionTile extends StatefulWidget {
  const ChannelConnectionTile({
    required this.client,
    required this.provider,
    required this.previewMode,
    required this.unavailableMessage,
    super.key,
  });

  final ChannelClient? client;
  final ChannelProvider provider;
  final bool previewMode;
  final String unavailableMessage;

  @override
  State<ChannelConnectionTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<ChannelConnectionTile> {
  Future<bool>? linked;
  ChannelLinkState state = const ChannelLinkState.unlinked();

  @override
  void initState() {
    super.initState();
    if (widget.client != null) {
      linked = widget.client!.isLinked(widget.provider);
    }
  }

  @override
  void didUpdateWidget(ChannelConnectionTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client ||
        oldWidget.provider != widget.provider) {
      state = const ChannelLinkState.unlinked();
      linked = widget.client?.isLinked(widget.provider);
    }
  }

  Future<void> requestLink() async {
    setState(() => state = const ChannelLinkState.requesting());
    try {
      final token = await widget.client!.requestLink(widget.provider);
      if (!mounted) return;
      setState(() => state = ChannelLinkState.awaitingConfirmation(token));
    } catch (error) {
      if (!mounted) return;
      setState(() => state = ChannelLinkState.failed('$error'));
    }
  }

  void recheckLink() {
    setState(() {
      state = const ChannelLinkState.unlinked();
      linked = widget.client!.isLinked(widget.provider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = switch (widget.provider) {
      ChannelProvider.telegram => 'Telegram',
      ChannelProvider.blooio => 'Blooio',
    };
    if (linked == null) {
      return _SetupTile(
        icon: widget.provider == ChannelProvider.telegram
            ? Icons.send_outlined
            : Icons.chat_bubble_outline_rounded,
        title: 'Connect $name',
        detail: widget.previewMode
            ? 'Connections are disabled in the interface preview.'
            : widget.unavailableMessage,
        state: 'Unavailable',
      );
    }
    return FutureBuilder<bool>(
      future: linked,
      builder: (context, snapshot) {
        final waiting =
            snapshot.connectionState != ConnectionState.done ||
            state.phase == ChannelLinkPhase.requesting;
        final detail = switch (state.phase) {
          ChannelLinkPhase.awaitingConfirmation =>
            'Link code: ${state.token!.token}',
          ChannelLinkPhase.failed => state.error!,
          _ when snapshot.hasError => '${snapshot.error}',
          _ when waiting => 'Checking connection…',
          _ when snapshot.data == true => 'Connected',
          _ => 'Use the same assistant from any device',
        };
        final connectionState = snapshot.data == true
            ? 'Connected'
            : 'Not connected';
        final announce =
            waiting ||
            snapshot.hasError ||
            state.phase == ChannelLinkPhase.failed ||
            state.phase == ChannelLinkPhase.awaitingConfirmation;
        return Semantics(
          liveRegion: announce,
          child: _SetupTile(
            icon: widget.provider == ChannelProvider.telegram
                ? Icons.send_outlined
                : Icons.chat_bubble_outline_rounded,
            title: 'Connect $name',
            detail: detail,
            state: connectionState,
            onPressed: waiting || snapshot.data == true
                ? null
                : state.phase == ChannelLinkPhase.awaitingConfirmation
                ? recheckLink
                : requestLink,
            actionTooltip: state.phase == ChannelLinkPhase.awaitingConfirmation
                ? 'Check $name connection'
                : 'Connect $name',
          ),
        );
      },
    );
  }
}

class _SetupTile extends StatelessWidget {
  const _SetupTile({
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
  Widget build(BuildContext context) => BaseTile(
    icon: icon,
    title: title,
    detail: detail,
    trailing: onPressed == null
        ? Text(state, style: const TextStyle(color: Colors.white54))
        : IconButton(
            tooltip: actionTooltip ?? 'Connect',
            onPressed: onPressed,
            icon: const Icon(Icons.arrow_forward_rounded),
          ),
  );
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => BaseTile(
    icon: icon,
    title: title,
    detail: detail,
    trailing: const SizedBox.shrink(),
  );
}
