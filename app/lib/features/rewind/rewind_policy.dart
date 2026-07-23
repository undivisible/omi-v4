import 'package:flutter/foundation.dart';

import 'rewind_dhash.dart';
import 'rewind_models.dart';
import 'rewind_privacy.dart';

/// Apps whose screens change slowly enough that the interactive heartbeat is
/// pure waste: music and video players, photo and book libraries, readers.
/// Matched on bundle id so a lookalike window title cannot promote or demote
/// an app.
const kRewindSlowChangingBundleIds = <String>{
  'com.apple.Music',
  'com.apple.iTunes',
  'com.apple.TV',
  'com.apple.Photos',
  'com.apple.podcasts',
  'com.apple.iBooksX',
  'com.apple.Preview',
  'com.spotify.client',
  'com.colliderli.iina',
  'org.videolan.vlc',
  'com.plexapp.plexdesktop',
  'com.readdle.PDFExpert-Mac',
  'com.kagi.kagimacOS',
  'com.amazon.Kindle',
  'com.apple.QuickTimePlayerX',
};

/// The verdict of one policy evaluation.
@immutable
final class RewindDecision {
  const RewindDecision._(this.capture, this.reason);

  const RewindDecision.capture() : this._(true, null);
  const RewindDecision.skip(RewindSkipReason reason) : this._(false, reason);

  final bool capture;
  final RewindSkipReason? reason;

  @override
  String toString() => capture ? 'capture' : 'skip(${reason!.name})';
}

/// Everything the policy is allowed to look at for one tick.
@immutable
final class RewindTick {
  const RewindTick({
    required this.now,
    required this.context,
    required this.idleFor,
    this.locked = false,
    this.paused = false,
    this.busy = false,
    this.permitted = true,
  });

  final DateTime now;
  final RewindWindowContext context;

  /// Time since the last user input event, from the system's own idle clock.
  final Duration idleFor;

  /// Screen locked, display asleep, or the machine is going to sleep.
  final bool locked;

  /// The user pressed pause. Nothing is captured, full stop.
  final bool paused;

  /// The encoder or the writer has not finished the previous frame. This is
  /// the backpressure flag: frames are dropped, never queued.
  final bool busy;

  /// Screen recording permission is actually granted right now.
  final bool permitted;
}

/// The capture policy: event-driven triggers, per-app heartbeats, and a
/// preview similarity gate, in that order. Pure and synchronous — it owns no
/// timers, no platform handles and no I/O, so the whole schedule is testable
/// by advancing a clock.
final class RewindCapturePolicy {
  RewindCapturePolicy({
    this.config = const RewindPolicyConfig(),
    this.privacy = const RewindPrivacySettings(),
    Set<String> slowChangingBundleIds = kRewindSlowChangingBundleIds,
  }) : _slowChanging = slowChangingBundleIds;

  final RewindPolicyConfig config;

  /// The live privacy configuration. Replaced wholesale when the user changes
  /// it, so a decision is never made against a half-applied setting.
  RewindPrivacySettings privacy;
  final Set<String> _slowChanging;

  RewindWindowContext? _lastContext;
  DateTime? _lastCaptureAt;
  RewindPreviewHash? _lastHash;

  RewindAppTempo tempoFor(RewindWindowContext context) {
    final bundleId = context.bundleId;
    return bundleId != null && _slowChanging.contains(bundleId)
        ? RewindAppTempo.slowChanging
        : RewindAppTempo.interactive;
  }

  /// Stage one, decided before any pixels are read: may this screen be looked
  /// at at all, and is it time to look?
  RewindDecision evaluate(RewindTick tick) {
    if (tick.paused) return const RewindDecision.skip(RewindSkipReason.paused);
    if (!tick.permitted) {
      return const RewindDecision.skip(RewindSkipReason.noPermission);
    }
    if (tick.locked) {
      return const RewindDecision.skip(RewindSkipReason.screenLocked);
    }
    final denial = privacy.denialFor(tick.context);
    if (denial != null) return RewindDecision.skip(denial);
    if (tick.busy) return const RewindDecision.skip(RewindSkipReason.busy);

    final last = _lastCaptureAt;
    if (last != null && tick.now.difference(last) < config.minimumInterval) {
      return const RewindDecision.skip(RewindSkipReason.minimumInterval);
    }

    // Event-driven trigger: a new app or a new window title is a new thing to
    // remember, and it earns a frame without waiting for the heartbeat.
    final previous = _lastContext;
    if (previous == null || !previous.sameAs(tick.context)) {
      return const RewindDecision.capture();
    }

    // Heartbeat only while the user is actually here.
    if (tick.idleFor >= config.idleAfter) {
      return const RewindDecision.skip(RewindSkipReason.idle);
    }
    if (last == null) return const RewindDecision.capture();
    final due = config.heartbeatFor(tempoFor(tick.context));
    return tick.now.difference(last) >= due
        ? const RewindDecision.capture()
        : const RewindDecision.skip(RewindSkipReason.heartbeat);
  }

  /// Stage two, decided from the cheap preview: has the screen meaningfully
  /// changed since the last frame that was actually stored? A context change
  /// always wins — the same-looking screen in a different window is still a
  /// different moment.
  RewindDecision evaluatePreview(RewindTick tick, RewindPreviewHash preview) {
    final previousContext = _lastContext;
    if (previousContext == null || !previousContext.sameAs(tick.context)) {
      return const RewindDecision.capture();
    }
    final previousHash = _lastHash;
    if (previousHash == null) return const RewindDecision.capture();
    return previousHash.distanceTo(preview) <= config.similarityThreshold
        ? const RewindDecision.skip(RewindSkipReason.unchanged)
        : const RewindDecision.capture();
  }

  /// Records that a frame was stored. Only stored frames move the heartbeat
  /// clock, so a run of skipped previews cannot starve the timeline.
  void recordCapture(RewindTick tick, RewindPreviewHash preview) {
    _lastContext = tick.context;
    _lastCaptureAt = tick.now;
    _lastHash = preview;
  }

  /// Records that the preview gate rejected a frame. The context and hash
  /// advance (so the next comparison is against what is really on screen) but
  /// the heartbeat clock does too, so an unchanging screen is re-previewed at
  /// the heartbeat rate rather than every tick.
  void recordSkippedPreview(RewindTick tick, RewindPreviewHash preview) {
    _lastContext = tick.context;
    _lastCaptureAt = tick.now;
    _lastHash = preview;
  }

  /// Forgets the schedule. Used when capture is paused or permission is lost,
  /// so resuming takes a frame immediately instead of honouring a stale
  /// heartbeat from before the gap.
  void reset() {
    _lastContext = null;
    _lastCaptureAt = null;
    _lastHash = null;
  }
}
