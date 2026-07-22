import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/worker_http.dart';
import '../app_services.dart';
import '../channels/channels.dart';
import '../native/generated/signals/signals.dart' show AssistantProvider;
import '../providers/providers.dart';
import '../settings/settings.dart';
import '../ui/omi_ui.dart';

class SetupScreen extends StatelessWidget {
  const SetupScreen({
    required this.services,
    this.previewMode = false,
    super.key,
  });

  final AppServices services;
  final bool previewMode;

  @override
  Widget build(BuildContext context) => PageList(
    title: 'Finish setup',
    subtitle: 'Each connection makes your assistant more useful.',
    children: [
      if (!previewMode && services.settings != null)
        FutureBuilder<SetupHealth>(
          future: services.settings!.getSetupHealth(),
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
        ),
      const _SetupTile(
        icon: Icons.mic_none_rounded,
        title: 'Try voice',
        detail: 'Ask “what are my tasks?”',
        state: 'Not completed',
      ),
      const _SetupTile(
        icon: Icons.lock_outline_rounded,
        title: 'Allow screen understanding',
        detail: 'Keep visual memory under your control',
        state: 'Not granted',
      ),
      for (final provider in ChannelProvider.values)
        ChannelConnectionTile(
          client: !previewMode && services.canUseApi ? services.channels : null,
          provider: provider,
          previewMode: previewMode,
          unavailableMessage: services.configurationMessage,
        ),
      const _SetupTile(
        icon: Icons.description_outlined,
        title: 'Connect Notion',
        detail: 'Bring your workspace into memory',
        state: 'Not connected',
      ),
    ],
  );
}

class AccountScreen extends StatelessWidget {
  const AccountScreen({
    required this.services,
    this.previewMode = false,
    super.key,
  });

  final AppServices services;
  final bool previewMode;

  @override
  Widget build(BuildContext context) => PageList(
    title: 'Account',
    subtitle: 'Identity, plan, providers, and agent control.',
    children: [
      _AccountTile(
        icon: Icons.person_outline_rounded,
        title: 'Sign in',
        detail: previewMode
            ? 'Account access is disabled in the interface preview.'
            : services.auth.snapshot.session?.displayName ??
                  services.configurationMessage,
      ),
      if (previewMode || !services.canUseApi)
        const _AccountTile(
          icon: Icons.shield_outlined,
          title: 'Agent control unavailable',
          detail: 'Sign in to load your approval policy.',
        )
      else
        FutureBuilder<SettingsSnapshot>(
          future: services.settings!.getSettings(),
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
        ),
      if (previewMode || kIsWeb)
        const _AccountTile(
          icon: Icons.key_outlined,
          title: 'AI providers',
          detail: 'Configure BYOK securely from a native Omi app.',
        )
      else
        _ProviderTile(services: services),
      if (previewMode || services.billing == null)
        const _AccountTile(
          icon: Icons.credit_card_outlined,
          title: 'Plan unavailable',
          detail: 'Sign in to manage your plan.',
        )
      else
        _PlanTile(client: services.billing!),
    ],
  );
}

class _ProviderTile extends StatefulWidget {
  const _ProviderTile({required this.services});

  final AppServices services;

  @override
  State<_ProviderTile> createState() => _ProviderTileState();
}

class _ProviderTileState extends State<_ProviderTile> {
  late Future<ProviderCredential?> credential =
      widget.services.providerCredential;

  void refresh() => setState(() {
    credential = widget.services.providerCredential;
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
                  await widget.services.clearProviderCredential();
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('Use plan default'),
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
  Widget build(BuildContext context) => FutureBuilder<ProviderCredential?>(
    future: credential,
    builder: (context, snapshot) {
      final value = snapshot.data;
      return BaseTile(
        icon: Icons.key_outlined,
        title: 'AI provider',
        detail: snapshot.connectionState != ConnectionState.done
            ? 'Checking secure storage…'
            : snapshot.hasError
            ? '${snapshot.error}'
            : value == null
            ? 'Using your plan default'
            : '${value.provider.name} · ${value.model}',
        trailing: IconButton(
          tooltip: 'Configure AI provider',
          onPressed: snapshot.connectionState == ConnectionState.done
              ? () => configure(value)
              : null,
          icon: const Icon(Icons.arrow_forward_rounded),
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
