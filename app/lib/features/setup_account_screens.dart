import 'package:flutter/material.dart';

import '../app_services.dart';
import '../channels/channels.dart';
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
        _ChannelTile(
          services: services,
          provider: provider,
          previewMode: previewMode,
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
      const _AccountTile(
        icon: Icons.key_outlined,
        title: 'AI providers',
        detail: 'No provider connected',
      ),
      const _AccountTile(
        icon: Icons.credit_card_outlined,
        title: 'Plan',
        detail: 'Entitlement has not loaded',
      ),
    ],
  );
}

class _ChannelTile extends StatefulWidget {
  const _ChannelTile({
    required this.services,
    required this.provider,
    required this.previewMode,
  });

  final AppServices services;
  final ChannelProvider provider;
  final bool previewMode;

  @override
  State<_ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<_ChannelTile> {
  Future<bool>? linked;
  ChannelLinkState state = const ChannelLinkState.unlinked();

  @override
  void initState() {
    super.initState();
    if (!widget.previewMode && widget.services.canUseApi) {
      linked = widget.services.channels!.isLinked(widget.provider);
    }
  }

  Future<void> requestLink() async {
    setState(() => state = const ChannelLinkState.requesting());
    try {
      final token = await widget.services.channels!.requestLink(
        widget.provider,
      );
      setState(() => state = ChannelLinkState.awaitingConfirmation(token));
    } catch (error) {
      setState(() => state = ChannelLinkState.failed('$error'));
    }
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
            : widget.services.configurationMessage,
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
            onPressed: waiting || snapshot.data == true ? null : requestLink,
            actionTooltip: 'Connect $name',
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
