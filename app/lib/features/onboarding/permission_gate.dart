import 'dart:async';

import 'package:flutter/material.dart';

import '../../auth/auth.dart';
import '../../capabilities/desktop_capabilities.dart';
import 'authentication_gate.dart';

class ProductionGate extends StatefulWidget {
  const ProductionGate({
    required this.configurationMessage,
    required this.auth,
    required this.capabilities,
    required this.onOpenPreview,
    required this.onFinish,
    super.key,
  });

  final String configurationMessage;
  final AuthController auth;
  final DesktopCapabilityGateway capabilities;
  final VoidCallback onOpenPreview;
  final FutureOr<void> Function() onFinish;

  @override
  State<ProductionGate> createState() => _ProductionGateState();
}

class _ProductionGateState extends State<ProductionGate>
    with WidgetsBindingObserver {
  static const permissionCapabilities = [
    CoreCapability.microphone,
    CoreCapability.accessibility,
    CoreCapability.screenCapture,
    CoreCapability.appData,
  ];
  Map<CoreCapability, CapabilityStatus> statuses = {
    for (final capability in CoreCapability.values)
      capability: const CapabilityStatus(
        state: CapabilityState.checking,
        detail: 'Checking capability…',
      ),
  };
  bool refreshing = false;
  bool finishing = false;
  bool finishFailed = false;
  final requesting = <CoreCapability>{};
  int checkGeneration = 0;
  Timer? permissionPoll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(_refreshView);
    unawaited(widget.capabilities.dismissOverlay());
    unawaited(_check());
    _startPermissionPoll();
  }

  @override
  void dispose() {
    permissionPoll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.auth.removeListener(_refreshView);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !refreshing && !finishing) {
      unawaited(_check());
    }
  }

  void _refreshView() {
    if (!mounted) return;
    setState(() {});
    if (ready && !finishing && !refreshing) {
      permissionPoll?.cancel();
      permissionPoll = null;
      unawaited(_finish());
    }
  }

  Future<void> _check() async {
    final generation = ++checkGeneration;
    setState(() => refreshing = true);
    Map<CoreCapability, CapabilityStatus> next;
    try {
      next = await widget.capabilities.check();
    } catch (error) {
      next = {
        for (final capability in CoreCapability.values)
          capability: CapabilityStatus(
            state: CapabilityState.error,
            detail: 'Could not check this capability: $error',
          ),
      };
    }
    if (!mounted || generation != checkGeneration) return;
    setState(() {
      statuses = next;
      refreshing = false;
    });
    if (ready) {
      permissionPoll?.cancel();
      permissionPoll = null;
      if (!finishing) await _finish();
    }
  }

  Future<void> _request(CoreCapability capability) async {
    if (!requesting.add(capability)) return;
    if (mounted) setState(() {});
    try {
      await widget.capabilities.request(capability);
      if (!mounted) return;
      await _check();
      if (!ready) _startPermissionPoll();
    } catch (error) {
      if (!mounted || statuses[capability]?.acceptable == true) return;
      setState(() {
        statuses = {
          ...statuses,
          capability: CapabilityStatus(
            state: CapabilityState.error,
            detail: 'Could not request this capability: $error',
          ),
        };
      });
    } finally {
      requesting.remove(capability);
      if (mounted) setState(() {});
    }
  }

  void _startPermissionPoll() {
    permissionPoll ??= Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted && !refreshing && !finishing) unawaited(_check());
    });
  }

  Future<void> _finish() async {
    if (finishing) return;
    setState(() {
      finishing = true;
      finishFailed = false;
    });
    try {
      await widget.onFinish();
      if (mounted) setState(() => finishing = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        finishing = false;
        finishFailed = true;
      });
    }
  }

  // Firebase can be entirely unconfigured (local/testing builds with no
  // backend); there is no sign-in flow to satisfy in that case, so don't
  // block forever waiting for processing authority that can never arrive.
  bool get _authSatisfied =>
      widget.auth.snapshot.phase == AuthPhase.unavailable ||
      widget.auth.snapshot.hasProcessingAuthority;

  bool get ready =>
      _authSatisfied &&
      permissionCapabilities.every(
        (capability) => statuses[capability]?.acceptable == true,
      );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'First…',
        textAlign: TextAlign.left,
        style: TextStyle(
          color: Color(0xfffffcec),
          fontFamily: 'Avenir Next',
          fontSize: 38,
          fontWeight: FontWeight.w500,
          letterSpacing: -1.5,
        ),
      ),
      const SizedBox(height: 26),
      AuthenticationGate(
        auth: widget.auth,
        configurationMessage: widget.configurationMessage,
      ),
      if (widget.auth.snapshot.phase == AuthPhase.signedIn &&
          !widget.auth.snapshot.hasProcessingAuthority) ...[
        const SizedBox(height: 8),
        FilledButton(
          key: const Key('grant_processing_consent'),
          onPressed: () => unawaited(widget.auth.grantProcessingConsent()),
          child: const Text('Allow Omi to process my data'),
        ),
      ],
      const SizedBox(height: 18),
      for (final capability in permissionCapabilities)
        _CapabilityRow(
          capability: capability,
          status: statuses[capability]!,
          onRequest:
              statuses[capability]!.state == CapabilityState.actionRequired &&
                  !requesting.contains(capability)
              ? () => unawaited(_request(capability))
              : null,
        ),
      const SizedBox(height: 14),
      TextButton(
        key: const Key('open_interface_preview'),
        onPressed: widget.onOpenPreview,
        child: const Text('Explore the interface preview'),
      ),
      if (finishFailed) ...[
        const SizedBox(height: 8),
        Semantics(
          liveRegion: true,
          child: const Text(
            'Onboarding completion could not be saved. Try again.',
            style: TextStyle(color: Color(0xffffb4ab)),
          ),
        ),
      ],
    ],
  );
}

class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({
    required this.capability,
    required this.status,
    required this.onRequest,
  });

  final CoreCapability capability;
  final CapabilityStatus status;
  final VoidCallback? onRequest;

  @override
  Widget build(BuildContext context) {
    final copy = switch (capability) {
      CoreCapability.microphone =>
        'I would like to use your microphone so we can talk.',
      CoreCapability.screenCapture =>
        'I would like to see your screen so I can give relevant help.',
      CoreCapability.accessibility =>
        'I would like accessibility access so I can act when you ask.',
      CoreCapability.appData =>
        'I would like Full Disk Access to learn more about you.',
      CoreCapability.workspaceRoot => throw StateError(
        'Workspace selection is not an operating-system permission.',
      ),
    };
    final state = switch (status.state) {
      CapabilityState.checking => 'Checking',
      CapabilityState.granted => 'Granted',
      CapabilityState.actionRequired => 'Action required',
      CapabilityState.notRequired => 'No grant required',
      CapabilityState.notApplicable => 'Not applicable',
      CapabilityState.error => 'Check failed',
    };
    final granted = status.acceptable;
    return Semantics(
      button: true,
      enabled: onRequest != null,
      label: copy,
      value: granted ? 'Granted' : state,
      onTap: onRequest,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Material(
            color: const Color(0x0dffffff),
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onRequest,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        color: granted
                            ? const Color(0xfffffcec)
                            : Colors.transparent,
                        border: Border.all(color: const Color(0x73ffffff)),
                      ),
                      child: granted
                          ? const Icon(
                              Icons.check_rounded,
                              size: 14,
                              color: Color(0xff171716),
                            )
                          : null,
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Text(
                        copy,
                        style: const TextStyle(
                          color: Color(0xd1ffffff),
                          fontSize: 15,
                          height: 1.35,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      granted
                          ? 'Granted'
                          : onRequest == null
                          ? state
                          : 'Open',
                      style: const TextStyle(
                        color: Color(0x73ffffff),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
