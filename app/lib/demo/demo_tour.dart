import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../features/meeting_notes_screen.dart';
import '../features/setup_account_screens.dart';
import '../features/tasks_screen.dart';
import 'demo_guide.dart';
import 'demo_memory_screen.dart';
import 'demo_model.dart';
import 'demo_pendant.dart';
import 'demo_prompt_bus.dart';

/// The walkthrough's own chrome: which step is next, where the answers are
/// coming from, and — where the machine can take it — the opt-in that puts a
/// real model behind the tour.
///
/// It drives the tour by typing into the real composer, so every step is an
/// ordinary chat turn the visitor could have typed themselves. They are never
/// held to it: the chips are optional, the steps can be taken in any order,
/// and anything else typed into the composer is answered normally.
///
/// It is mounted as an overlay entry in the navigator's own overlay (see
/// [DemoTourOverlay]), not through `MaterialApp.builder`: a widget hosted
/// above the navigator by that builder does not repaint on its own `setState`
/// in a release web build, so the panel would freeze on its first step. Living
/// in the same overlay the routes and the chat live in, it repaints normally.
class DemoTourPanel extends StatefulWidget {
  const DemoTourPanel({
    required this.services,
    required this.navigator,
    super.key,
  });

  final AppServices services;
  final GlobalKey<NavigatorState> navigator;

  @override
  State<DemoTourPanel> createState() => _DemoTourPanelState();
}

class _DemoTourPanelState extends State<DemoTourPanel> {
  final _tour = DemoTour.instance;
  final _model = DemoModel.instance;
  bool _collapsed = false;
  bool _sizedOnce = false;
  DemoSurface _shown = DemoSurface.hub;

  /// On a phone the panel would cover most of the hub, so it starts folded
  /// down to its one-line header there and the visitor opens it. On a desktop
  /// it starts open, where there is room for it beside the reading column.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sizedOnce) return;
    _sizedOnce = true;
    _collapsed = MediaQuery.sizeOf(context).width < 560;
  }

  @override
  void initState() {
    super.initState();
    // Idempotent: whichever of the demo's entry points got there first, the
    // panel will not render an opt-in it has not asked the browser about.
    unawaited(_model.resolve());
    _tour.addListener(_changed);
    _tour.surfaceRequests.addListener(_surfaceChanged);
    _model.addListener(_changed);
    DemoPromptBus.instance.attachments.addListener(_changed);
  }

  @override
  void dispose() {
    _tour.removeListener(_changed);
    _tour.surfaceRequests.removeListener(_surfaceChanged);
    _model.removeListener(_changed);
    DemoPromptBus.instance.attachments.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Opens the surface the current step is about. Always from the root, so a
  /// tour taken out of order never leaves a stack of screens behind.
  void _surfaceChanged() {
    final surface = _tour.surface.value;
    _shown = surface;
    final navigator = widget.navigator.currentState;
    if (navigator == null) return;
    navigator.popUntil((route) => route.isFirst);
    final builder = switch (surface) {
      DemoSurface.hub => null,
      DemoSurface.currents => (BuildContext context) => TasksScreen(
        controller: widget.services.currents!,
      ),
      DemoSurface.memory => (BuildContext context) => const DemoMemoryScreen(),
      DemoSurface.meetings => (BuildContext context) => MeetingNotesScreen(
        services: widget.services,
      ),
      DemoSurface.pendant =>
        (BuildContext context) => const DemoPendantScreen(),
      DemoSurface.settings => (BuildContext context) => SettingsScreen(
        services: widget.services,
        initialSection: SettingsSection.providers,
      ),
    };
    if (builder == null) return;
    navigator.push(MaterialPageRoute<void>(builder: builder));
  }

  void _take(DemoTourStep step) {
    // Back to the hub first: the answer streams into the chat, and the chat
    // has to be what the visitor is looking at when it does.
    _tour.show(DemoSurface.hub);
    _tour.enter(step);
    DemoPromptBus.instance.send(step.prompt);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? const Color(0xfff4f2ea) : const Color(0xff171716);
    final muted = dark ? const Color(0xffa6a49c) : const Color(0xff706e68);
    final surface = dark ? const Color(0xff232321) : const Color(0xfffffefa);
    final hairline = dark ? const Color(0x24fffcec) : const Color(0x1a171716);
    final narrow = MediaQuery.sizeOf(context).width < 560;
    final collapsed = _collapsed;
    final shown = _shown;
    final step = _tour.next;
    final taken = _tour.visited.length;
    final total = DemoTour.steps.length;

    return Align(
      alignment: narrow ? Alignment.bottomCenter : Alignment.bottomRight,
      child: Padding(
        // Clear of the composer: the panel must never sit on top of the one
        // control the visitor needs to talk back with.
        padding: EdgeInsets.fromLTRB(
          narrow ? 10 : 20,
          0,
          narrow ? 10 : 20,
          narrow ? 10 : 108,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 348,
            maxHeight: MediaQuery.sizeOf(context).height * 0.62,
          ),
          child: Material(
            color: surface,
            elevation: 6,
            shadowColor: Colors.black.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: hairline),
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            collapsed
                                ? 'Guided tour · $taken of $total'
                                : 'Guided tour',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                              color: ink,
                            ),
                          ),
                        ),
                        IconButton(
                          key: const Key('demo_tour_collapse'),
                          onPressed: () =>
                              setState(() => _collapsed = !_collapsed),
                          iconSize: 18,
                          visualDensity: VisualDensity.compact,
                          color: muted,
                          icon: Icon(
                            semanticLabel: collapsed
                                ? 'Show the tour'
                                : 'Hide the tour',
                            collapsed
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.keyboard_arrow_down_rounded,
                          ),
                        ),
                      ],
                    ),
                    if (!collapsed) ...[
                      _TierLine(model: _model, ink: ink, muted: muted),
                      const SizedBox(height: 10),
                      if (step != null)
                        Text(
                          taken == 0
                              ? 'Ask me anything, or start here:'
                              : 'Next, if you like:',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: muted,
                          ),
                        )
                      else
                        Text(
                          'That is the whole tour. The composer is still yours '
                          '— ask anything.',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: muted,
                          ),
                        ),
                      const SizedBox(height: 8),
                      if (step != null)
                        _Chip(
                          key: const Key('demo_tour_next'),
                          label: step.chip,
                          ink: ink,
                          hairline: hairline,
                          onTap: () => _take(step),
                        ),
                      if (_tour.lastStep case final last?
                          when last.surface != DemoSurface.hub &&
                              shown != last.surface)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: _Chip(
                            key: const Key('demo_tour_show'),
                            label:
                                'Open ${DemoTour.surfaceLabel(last.surface)}',
                            ink: ink,
                            hairline: hairline,
                            onTap: () => _tour.show(last.surface),
                          ),
                        ),
                      if (shown != DemoSurface.hub)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: _Chip(
                            key: const Key('demo_tour_back'),
                            label: 'Back to the hub',
                            ink: ink,
                            hairline: hairline,
                            onTap: () => _tour.show(DemoSurface.hub),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          '$taken of $total',
                          style: TextStyle(fontSize: 11, color: muted),
                        ),
                      ),
                      _ModelOptIn(model: _model, ink: ink, muted: muted),
                    ],
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

/// Mounts the tour panel in the navigator's own overlay and keeps it above
/// every route.
///
/// The panel cannot ride `MaterialApp.builder` above the navigator: a widget
/// hosted there does not repaint on its own `setState` in a release web build,
/// so the tour would freeze on its first step. The navigator's overlay is the
/// same one the routes and the chat live in, and it repaints normally — so the
/// panel goes there, re-pinned to the top whenever the route stack changes.
class DemoTourOverlay {
  DemoTourOverlay({required this.services, required this.navigator});

  final AppServices services;
  final GlobalKey<NavigatorState> navigator;

  OverlayEntry? _entry;

  /// The observer handed to the [MaterialApp]: every route change re-pins the
  /// panel to the top of the overlay.
  late final NavigatorObserver observer = _DemoTourObserver(pin);

  /// Inserts the panel if it is not there yet, or lifts it back above the
  /// routes if it is. Re-inserting the same entry only reorders it, so the
  /// panel's state survives. Deferred to after the frame so it never mutates
  /// the overlay in the middle of a route transition's build.
  void pin() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final overlay = navigator.currentState?.overlay;
      if (overlay == null) return;
      final entry = _entry ??= OverlayEntry(
        builder: (context) =>
            DemoTourPanel(services: services, navigator: navigator),
      );
      if (entry.mounted) entry.remove();
      overlay.insert(entry);
    });
  }
}

class _DemoTourObserver extends NavigatorObserver {
  _DemoTourObserver(this._pin);

  final VoidCallback _pin;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _pin();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _pin();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _pin();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _pin();
}

/// Says, plainly, where the answers are coming from. The one thing this
/// cannot do is imply a model when there is none.
class _TierLine extends StatelessWidget {
  const _TierLine({
    required this.model,
    required this.ink,
    required this.muted,
  });

  final DemoModel model;
  final Color ink;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    final live = model.tier != DemoModelTier.scripted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(right: 7),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: live ? const Color(0xff2f9d8a) : muted,
              ),
            ),
            Expanded(
              child: Text(
                model.label,
                key: const Key('demo_tour_tier'),
                style: TextStyle(fontSize: 11.5, height: 1.35, color: ink),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          model.detail,
          style: TextStyle(fontSize: 11, height: 1.4, color: muted),
        ),
      ],
    );
  }
}

/// The WebGPU opt-in.
///
/// It is only rendered when the machine passed every check, it names the
/// download and its size before anything is fetched, and one click is the
/// only thing that can start the fetch.
class _ModelOptIn extends StatelessWidget {
  const _ModelOptIn({
    required this.model,
    required this.ink,
    required this.muted,
  });

  final DemoModel model;
  final Color ink;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    if (model.preparing) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(
          'Downloading ${model.downloadModel} — ${model.progress}%',
          style: TextStyle(fontSize: 11.5, color: muted),
        ),
      );
    }
    if (model.failure case final failure?) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(
          failure,
          style: TextStyle(fontSize: 11.5, height: 1.4, color: muted),
        ),
      );
    }
    // The browser's own model first: it is smaller, shared with every other
    // site, and the browser owns the download.
    if (model.canOfferPromptApi) {
      return _OptIn(
        buttonKey: const Key('demo_tour_enable_browser_model'),
        blurb:
            'Your browser has a built-in model it has not installed yet. Let '
            'it, and the tour runs on that instead — on-device, with nothing '
            'sent anywhere. The browser owns the download and reuses it '
            'across sites.',
        button: 'Let the browser install its model',
        onPressed: model.enablePromptApi,
        ink: ink,
        muted: muted,
      );
    }
    if (!model.canOfferWebgpu) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This machine could run a real model here instead. It downloads '
            '${model.downloadModel} and its runtime — about '
            '${model.downloadMb} MB — and then runs on your GPU. Nothing you '
            'type is sent anywhere, and nothing is fetched until you press '
            'this.',
            style: TextStyle(fontSize: 11.5, height: 1.45, color: muted),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const Key('demo_tour_enable_model'),
            onPressed: model.enableWebgpu,
            style: TextButton.styleFrom(
              foregroundColor: ink,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 32),
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: Text('Download ${model.downloadMb} MB and run it here'),
          ),
        ],
      ),
    );
  }
}

/// One opt-in: what it costs, then the button that spends it.
class _OptIn extends StatelessWidget {
  const _OptIn({
    required this.buttonKey,
    required this.blurb,
    required this.button,
    required this.onPressed,
    required this.ink,
    required this.muted,
  });

  final Key buttonKey;
  final String blurb;
  final String button;
  final VoidCallback onPressed;
  final Color ink;
  final Color muted;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          blurb,
          style: TextStyle(fontSize: 11.5, height: 1.45, color: muted),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: buttonKey,
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: ink,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 32),
            textStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          child: Text(button),
        ),
      ],
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.ink,
    required this.hairline,
    required this.onTap,
    super.key,
  });

  final String label;
  final Color ink;
  final Color hairline;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        side: BorderSide(color: hairline),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        minimumSize: const Size(0, 34),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    ),
  );
}
