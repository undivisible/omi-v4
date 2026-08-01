import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ui/omi_typography.dart';
import 'google_read_path.dart';
import 'oauth_connection.dart';
import 'oauth_connector.dart';
import 'oauth_flow.dart';
import 'oauth_manager.dart';
import 'oauth_read_path.dart';

/// The warm-paper palette, pinned the same way the settings screen pins it so
/// this tile looks identical in the native settings window and in the in-window
/// route fallback.
class _ConnectorColors {
  const _ConnectorColors._({
    required this.hairline,
    required this.ink,
    required this.muted,
    required this.wash,
  });

  const _ConnectorColors.light()
    : this._(
        hairline: const Color(0x1a000000),
        ink: const Color(0xff171716),
        muted: const Color(0xff706e68),
        wash: const Color(0x0d000000),
      );

  const _ConnectorColors.dark()
    : this._(
        hairline: const Color(0x1affffff),
        ink: const Color(0xfff4f2ea),
        muted: const Color(0xffa6a49c),
        wash: const Color(0x14ffffff),
      );

  final Color hairline;
  final Color ink;
  final Color muted;
  final Color wash;

  static _ConnectorColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const _ConnectorColors.dark()
      : const _ConnectorColors.light();
}

/// Settings row for one OAuth connector: connect, see exactly what was
/// granted, read a few items to prove it works, disconnect.
///
/// The row is connector-agnostic — everything provider specific comes from the
/// [OAuthConnector] descriptor and the optional read path.
class OAuthConnectorTile extends StatefulWidget {
  const OAuthConnectorTile({
    required this.connector,
    required this.uid,
    required this.previewMode,
    this.manager,
    this.readPathBuilder,
    super.key,
  });

  final OAuthConnector connector;

  /// Signed-in person the grant belongs to. Null keeps the row inert.
  final String? uid;

  final bool previewMode;
  final OAuthConnectionManager? manager;

  /// Supplies the connector's read path. Defaults to the Google one for the
  /// Google connector and to nothing for connectors that have none yet.
  final OAuthReadPath? Function(OAuthConnectionManager manager)?
  readPathBuilder;

  @override
  State<OAuthConnectorTile> createState() => _OAuthConnectorTileState();
}

class _OAuthConnectorTileState extends State<OAuthConnectorTile> {
  late final OAuthConnectionManager manager =
      widget.manager ?? OAuthConnectionManager();
  late final OAuthReadPath? readPath = widget.readPathBuilder != null
      ? widget.readPathBuilder!(manager)
      : widget.connector.id == googleOAuthConnector.id
      ? GoogleReadPath(manager: manager)
      : null;

  OAuthConnection? connection;
  List<OAuthConnection> connections = [];
  List<ConnectorPreviewItem>? items;
  String? previewAccount;
  bool busy = false;
  bool expanded = false;
  String? message;
  bool _clientIdDialogOpen = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final uid = widget.uid;
    if (uid == null || widget.previewMode) return;
    final all = await manager.connections(uid, widget.connector);
    if (mounted) {
      setState(() {
        connections = all;
        connection = all.isEmpty ? null : all.first;
      });
    }
  }

  Future<void> _run(Future<void> Function(String uid) action) async {
    final uid = widget.uid;
    if (uid == null) {
      setState(() => message = 'Sign in to connect an account.');
      return;
    }
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action(uid);
    } on OAuthReconnectRequiredException {
      if (mounted) {
        setState(
          () => message =
              '${widget.connector.displayName} ended this connection. '
              'Reconnect to continue.',
        );
      }
    } on OAuthException catch (failure) {
      if (mounted) setState(() => message = failure.message);
    } catch (failure) {
      if (mounted) setState(() => message = '$failure');
    } finally {
      if (mounted) setState(() => busy = false);
      await _load();
    }
  }

  Future<void> _connect() async {
    final clientId = await _ensureClientId();
    if (clientId == null) return;
    await _run((uid) async {
      final value = await manager.connect(uid, widget.connector);
      final all = await manager.connections(uid, widget.connector);
      if (mounted) {
        setState(() {
          connections = all;
          connection = all.isEmpty ? value : all.first;
          expanded = true;
          items = null;
        });
      }
    });
  }

  Future<void> _disconnect() async {
    await _run((uid) async {
      await manager.disconnect(uid, widget.connector);
      if (mounted) {
        setState(() {
          connections = [];
          connection = null;
          items = null;
          previewAccount = null;
          expanded = false;
        });
      }
    });
  }

  Future<void> _disconnectAccount(OAuthConnection value) async {
    await _run((uid) async {
      await manager.disconnect(uid, widget.connector, account: value.account);
      final all = await manager.connections(uid, widget.connector);
      if (mounted) {
        setState(() {
          connections = all;
          connection = all.isEmpty ? null : all.first;
          if (value.account == previewAccount) {
            items = null;
            previewAccount = null;
          }
        });
      }
    });
  }

  Future<void> _preview() async {
    final path = readPath;
    if (path == null) return;
    final account = connection?.account;
    await _run((uid) async {
      final values = await path.preview(uid, account: account);
      if (mounted) {
        setState(() {
          items = values;
          previewAccount = account;
        });
      }
    });
  }

  Future<void> _previewAccount(OAuthConnection value) async {
    final path = readPath;
    if (path == null) return;
    await _run((uid) async {
      final values = await path.preview(uid, account: value.account);
      if (mounted) {
        setState(() {
          items = values;
          previewAccount = value.account;
        });
      }
    });
  }

  /// Asks for the client id the first time, and lets the user replace it
  /// later. Nothing is embedded in the app — a desktop bundle cannot keep a
  /// secret, so the client id is the user's own.
  Future<String?> _ensureClientId() async {
    final existing = await manager.clientIds.read(widget.connector.id);
    if (existing != null && existing.isNotEmpty) return existing;
    if (!mounted || _clientIdDialogOpen) return null;
    _clientIdDialogOpen = true;
    try {
      final entered = await showDialog<String>(
        context: context,
        useRootNavigator: true,
        builder: (context) => _ClientIdDialog(connector: widget.connector),
      );
      final trimmed = entered?.trim();
      if (trimmed == null || trimmed.isEmpty) return null;
      await manager.clientIds.write(widget.connector.id, trimmed);
      return trimmed;
    } finally {
      _clientIdDialogOpen = false;
    }
  }

  String get _state {
    if (widget.previewMode) return 'Preview';
    final value = connection;
    if (value == null) return 'Not connected';
    return value.needsReconnect ? 'Reconnect needed' : 'Connected';
  }

  @override
  Widget build(BuildContext context) {
    final colors = _ConnectorColors.of(context);
    final value = connection;
    final connected = value != null && !value.needsReconnect;
    final detail =
        message ??
        (widget.previewMode
            ? 'Accounts cannot be connected in the interface preview.'
            : value == null
            ? 'Connect ${widget.connector.displayName} with read-only access.'
            : value.needsReconnect
            ? 'The grant is no longer valid. Reconnect to restore access.'
            : value.account ??
                  'Connected with ${value.grantedScopes.length} granted '
                      'permissions.');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                connected ? Icons.link_rounded : Icons.link_off_rounded,
                size: 18,
                color: colors.ink,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.connector.displayName,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colors.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      busy ? 'Working…' : detail,
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
              Text(_state, style: TextStyle(fontSize: 12, color: colors.muted)),
              const SizedBox(width: 8),
              TextButton(
                key: Key('oauth_${widget.connector.id}_action'),
                onPressed: widget.previewMode || busy
                    ? null
                    : value == null || value.needsReconnect
                    ? _connect
                    : _disconnect,
                child: Text(
                  value == null
                      ? 'Connect'
                      : value.needsReconnect
                      ? 'Reconnect'
                      : 'Disconnect',
                ),
              ),
            ],
          ),
          if (value != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: Key('oauth_${widget.connector.id}_scopes'),
                onPressed: () => setState(() => expanded = !expanded),
                child: Text(
                  expanded ? 'Hide granted access' : 'Show granted access',
                ),
              ),
            ),
            if (expanded)
              _GrantedScopes(
                connector: widget.connector,
                granted: value.grantedScopes,
              ),
            if (!widget.previewMode) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: Key('oauth_${widget.connector.id}_add'),
                  onPressed: busy ? null : _connect,
                  child: const Text('Connect another account'),
                ),
              ),
            ],
          ],
          if (connected && readPath != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: Key('oauth_${widget.connector.id}_preview'),
                onPressed: busy ? null : _preview,
                child: const Text('Read a few recent items'),
              ),
            ),
            _previewItemsIfShown(
              values: items,
              shownAccount: previewAccount,
              account: value.account,
              colors: colors,
            ),
          ],
          for (final other in connections.skip(1)) _accountRow(other),
        ],
      ),
    );
  }

  Widget _accountRow(OAuthConnection value) {
    final colors = _ConnectorColors.of(context);
    final connected = !value.needsReconnect;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colors.wash,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          value.account ?? 'Connected account',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: colors.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          value.needsReconnect
                              ? 'Reconnect needed'
                              : 'Connected',
                          style: TextStyle(fontSize: 12, color: colors.muted),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    key: Key(
                      'oauth_${widget.connector.id}_account_${value.account ?? 'none'}_action',
                    ),
                    onPressed: busy
                        ? null
                        : value.needsReconnect
                        ? _connect
                        : () => _disconnectAccount(value),
                    child: Text(
                      value.needsReconnect ? 'Reconnect' : 'Disconnect',
                    ),
                  ),
                  if (connected && readPath != null)
                    TextButton(
                      key: Key(
                        'oauth_${widget.connector.id}_account_${value.account ?? 'none'}_read',
                      ),
                      onPressed: busy ? null : () => _previewAccount(value),
                      child: const Text('Read'),
                    ),
                ],
              ),
              _previewItemsIfShown(
                values: items,
                shownAccount: previewAccount,
                account: value.account,
                colors: colors,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _previewItemsIfShown({
    required List<ConnectorPreviewItem>? values,
    required String? shownAccount,
    required String? account,
    required _ConnectorColors colors,
  }) {
    if (values == null || shownAccount != account) {
      return const SizedBox.shrink();
    }
    return _previewItems(values: values, colors: colors);
  }

  Widget _previewItems({
    required List<ConnectorPreviewItem> values,
    required _ConnectorColors colors,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.wash,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (values.isEmpty)
            Text(
              'Nothing recent to show.',
              style: TextStyle(fontSize: 12, color: colors.muted),
            ),
          for (final item in values)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${item.subtitle} · ${item.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.ink),
              ),
            ),
        ],
      ),
    );
  }
}

class _GrantedScopes extends StatelessWidget {
  const _GrantedScopes({required this.connector, required this.granted});

  final OAuthConnector connector;
  final List<String> granted;

  @override
  Widget build(BuildContext context) {
    final colors = _ConnectorColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final scope in granted)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check_rounded, size: 14, color: colors.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _summary(scope),
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: colors.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Text(
          connector.revocable
              ? 'Disconnecting revokes this access at '
                    '${connector.displayName}, not just on this Mac.'
              : 'Disconnecting forgets these tokens locally. '
                    '${connector.displayName} has no revocation endpoint.',
          style: TextStyle(fontSize: 11, height: 1.35, color: colors.muted),
        ),
      ],
    );
  }

  String _summary(String scope) {
    for (final known in connector.scopes) {
      if (known.value == scope) return known.summary;
    }
    return scope;
  }
}

class _ClientIdDialog extends StatefulWidget {
  const _ClientIdDialog({required this.connector});

  final OAuthConnector connector;

  @override
  State<_ClientIdDialog> createState() => _ClientIdDialogState();
}

class _ClientIdDialogState extends State<_ClientIdDialog> {
  final controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final help = widget.connector.clientIdHelpUrl;
    return AlertDialog(
      title: Text('${widget.connector.displayName} client ID'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.connector.clientIdInstructions,
            style: const TextStyle(
              fontFamily: OmiFonts.sans,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('oauth_client_id_field'),
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Client ID',
              hintText: '1234567890-abc.apps.googleusercontent.com',
            ),
            style: OmiAccentText.monoSmall,
          ),
          if (help != null) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => unawaited(
                launchUrl(help, mode: LaunchMode.externalApplication),
              ),
              child: const Text('Open the console'),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('oauth_client_id_save'),
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
