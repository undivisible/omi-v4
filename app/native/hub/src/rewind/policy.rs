//! The capture policy: event-driven triggers, per-app heartbeats, and a
//! preview similarity gate, in that order.
//!
//! Pure and synchronous — it owns no timers, no platform handles and no I/O,
//! so the whole schedule is testable by advancing a clock. The two stages are
//! separate methods on purpose, and the split is the frame-economy invariant
//! in code: [`CapturePolicy::evaluate`] runs before a single pixel is read,
//! and [`CapturePolicy::evaluate_preview`] runs against 72 bytes of luminance
//! while the full frame is still held, unencoded, on the native side.

use super::dhash::PreviewHash;
use super::models::{AppTempo, PolicyConfig, WindowContext};
use super::privacy::{PrivacySettings, SkipReason};

/// Apps whose screens change slowly enough that the interactive heartbeat is
/// pure waste: music and video players, photo and book libraries, readers.
/// Matched on bundle id so a lookalike window title cannot promote or demote
/// an app.
pub const SLOW_CHANGING_BUNDLE_IDS: &[&str] = &[
    "com.apple.Music",
    "com.apple.iTunes",
    "com.apple.TV",
    "com.apple.Photos",
    "com.apple.podcasts",
    "com.apple.iBooksX",
    "com.apple.Preview",
    "com.spotify.client",
    "com.colliderli.iina",
    "org.videolan.vlc",
    "com.plexapp.plexdesktop",
    "com.readdle.PDFExpert-Mac",
    "com.kagi.kagimacOS",
    "com.amazon.Kindle",
    "com.apple.QuickTimePlayerX",
];

/// The verdict of one policy evaluation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Decision {
    Capture,
    Skip(SkipReason),
}

impl Decision {
    pub fn captures(self) -> bool {
        matches!(self, Self::Capture)
    }

    pub fn reason(self) -> Option<SkipReason> {
        match self {
            Self::Capture => None,
            Self::Skip(reason) => Some(reason),
        }
    }
}

/// Everything the policy is allowed to look at for one tick.
#[derive(Clone, Debug)]
pub struct Tick {
    /// Milliseconds since the Unix epoch, sampled once per tick and reused for
    /// every stage of that tick, so a frame's stored timestamp is the instant
    /// the decision was made rather than the instant the encoder finished.
    pub now_ms: i64,
    pub context: WindowContext,
    /// Time since the last user input event, from the system's own idle clock.
    pub idle_ms: i64,
    /// Screen locked, display asleep, or the machine is going to sleep.
    pub locked: bool,
    /// The user pressed pause. Nothing is captured, full stop.
    pub paused: bool,
    /// The encoder or the writer has not finished the previous frame. This is
    /// the backpressure flag: frames are dropped, never queued.
    pub busy: bool,
    /// Screen recording permission is actually granted right now.
    pub permitted: bool,
}

/// The scheduling half of Rewind. The privacy configuration it consults is
/// owned here rather than passed per call, so a decision is never made against
/// a half-applied setting.
pub struct CapturePolicy {
    pub config: PolicyConfig,
    pub privacy: PrivacySettings,
    slow_changing: Vec<String>,
    last_context: Option<WindowContext>,
    last_capture_at_ms: Option<i64>,
    last_hash: Option<PreviewHash>,
}

impl Default for CapturePolicy {
    fn default() -> Self {
        Self::new(PolicyConfig::default(), PrivacySettings::default())
    }
}

impl CapturePolicy {
    pub fn new(config: PolicyConfig, privacy: PrivacySettings) -> Self {
        Self {
            config,
            privacy,
            slow_changing: SLOW_CHANGING_BUNDLE_IDS
                .iter()
                .map(|id| (*id).to_owned())
                .collect(),
            last_context: None,
            last_capture_at_ms: None,
            last_hash: None,
        }
    }

    pub fn tempo_for(&self, context: &WindowContext) -> AppTempo {
        match context.bundle_id.as_ref() {
            Some(bundle_id) if self.slow_changing.iter().any(|id| id == bundle_id) => {
                AppTempo::SlowChanging
            }
            _ => AppTempo::Interactive,
        }
    }

    /// Stage one, decided before any pixels are read: may this screen be looked
    /// at at all, and is it time to look?
    pub fn evaluate(&self, tick: &Tick) -> Decision {
        if tick.paused {
            return Decision::Skip(SkipReason::Paused);
        }
        if !tick.permitted {
            return Decision::Skip(SkipReason::NoPermission);
        }
        if tick.locked {
            return Decision::Skip(SkipReason::ScreenLocked);
        }
        if let Some(denial) = self.privacy.denial_for(&tick.context) {
            return Decision::Skip(denial);
        }
        if tick.busy {
            return Decision::Skip(SkipReason::Busy);
        }

        let last = self.last_capture_at_ms;
        if let Some(last) = last
            && tick.now_ms - last < millis(self.config.minimum_interval)
        {
            return Decision::Skip(SkipReason::MinimumInterval);
        }

        // Event-driven trigger: a new app or a new window title is a new thing to
        // remember, and it earns a frame without waiting for the heartbeat.
        match self.last_context.as_ref() {
            None => return Decision::Capture,
            Some(previous) if !previous.same_as(&tick.context) => return Decision::Capture,
            Some(_) => {}
        }

        // Heartbeat only while the user is actually here.
        if tick.idle_ms >= millis(self.config.idle_after) {
            return Decision::Skip(SkipReason::Idle);
        }
        let Some(last) = last else {
            return Decision::Capture;
        };
        let due = millis(self.config.heartbeat_for(self.tempo_for(&tick.context)));
        if tick.now_ms - last >= due {
            Decision::Capture
        } else {
            Decision::Skip(SkipReason::Heartbeat)
        }
    }

    /// Stage two, decided from the cheap preview: has the screen meaningfully
    /// changed since the last frame that was actually stored? A context change
    /// always wins — the same-looking screen in a different window is still a
    /// different moment.
    pub fn evaluate_preview(&self, tick: &Tick, preview: PreviewHash) -> Decision {
        match self.last_context.as_ref() {
            None => return Decision::Capture,
            Some(previous) if !previous.same_as(&tick.context) => return Decision::Capture,
            Some(_) => {}
        }
        let Some(previous_hash) = self.last_hash else {
            return Decision::Capture;
        };
        if previous_hash.distance_to(preview) <= self.config.similarity_threshold {
            Decision::Skip(SkipReason::Unchanged)
        } else {
            Decision::Capture
        }
    }

    /// Records that a frame was stored. Only stored frames move the heartbeat
    /// clock, so a run of skipped previews cannot starve the timeline.
    pub fn record_capture(&mut self, tick: &Tick, preview: PreviewHash) {
        self.last_context = Some(tick.context.clone());
        self.last_capture_at_ms = Some(tick.now_ms);
        self.last_hash = Some(preview);
    }

    /// Records that the preview gate rejected a frame. The context and hash
    /// advance (so the next comparison is against what is really on screen) but
    /// the heartbeat clock does too, so an unchanging screen is re-previewed at
    /// the heartbeat rate rather than every tick.
    pub fn record_skipped_preview(&mut self, tick: &Tick, preview: PreviewHash) {
        self.last_context = Some(tick.context.clone());
        self.last_capture_at_ms = Some(tick.now_ms);
        self.last_hash = Some(preview);
    }

    /// Forgets the schedule. Used when capture is paused or permission is lost,
    /// so resuming takes a frame immediately instead of honouring a stale
    /// heartbeat from before the gap.
    pub fn reset(&mut self) {
        self.last_context = None;
        self.last_capture_at_ms = None;
        self.last_hash = None;
    }
}

/// Durations are policy knobs but the clock is integer milliseconds, so every
/// comparison goes through one saturating conversion rather than a scatter of
/// casts.
fn millis(duration: std::time::Duration) -> i64 {
    i64::try_from(duration.as_millis()).unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests {
    use super::{CapturePolicy, SkipReason, Tick};
    use crate::rewind::dhash::{PREVIEW_LENGTH, PreviewHash};
    use crate::rewind::models::{AppTempo, PolicyConfig, WindowContext};
    use crate::rewind::privacy::PrivacySettings;
    use std::time::Duration;

    /// The instant every schedule test counts from: 2026-07-23T09:00 local in
    /// the Dart suite, pinned here as an epoch value so the arithmetic is the
    /// only thing under test.
    const START: i64 = 1_784_797_200_000;

    fn config() -> PolicyConfig {
        PolicyConfig {
            interactive_heartbeat: Duration::from_secs(20),
            slow_changing_heartbeat: Duration::from_secs(3 * 60),
            idle_after: Duration::from_secs(2 * 60),
            minimum_interval: Duration::from_secs(3),
            similarity_threshold: 3,
        }
    }

    fn policy() -> CapturePolicy {
        CapturePolicy::new(config(), PrivacySettings::default())
    }

    struct TickBuilder {
        now_ms: i64,
        bundle_id: &'static str,
        title: Option<&'static str>,
        idle_ms: i64,
        locked: bool,
        paused: bool,
        busy: bool,
        permitted: bool,
    }

    fn tick(now_ms: i64) -> TickBuilder {
        TickBuilder {
            now_ms,
            bundle_id: "com.apple.Terminal",
            title: Some("zsh"),
            idle_ms: 0,
            locked: false,
            paused: false,
            busy: false,
            permitted: true,
        }
    }

    impl TickBuilder {
        fn bundle(mut self, bundle_id: &'static str) -> Self {
            self.bundle_id = bundle_id;
            self
        }

        fn title(mut self, title: Option<&'static str>) -> Self {
            self.title = title;
            self
        }

        fn idle(mut self, idle: Duration) -> Self {
            self.idle_ms = i64::try_from(idle.as_millis()).unwrap_or_default();
            self
        }

        fn locked(mut self) -> Self {
            self.locked = true;
            self
        }

        fn paused(mut self) -> Self {
            self.paused = true;
            self
        }

        fn busy(mut self) -> Self {
            self.busy = true;
            self
        }

        fn unpermitted(mut self) -> Self {
            self.permitted = false;
            self
        }

        fn build(self) -> Tick {
            Tick {
                now_ms: self.now_ms,
                context: WindowContext {
                    bundle_id: Some(self.bundle_id.to_owned()),
                    app_name: Some(self.bundle_id.to_owned()),
                    window_title: self.title.map(str::to_owned),
                },
                idle_ms: self.idle_ms,
                locked: self.locked,
                paused: self.paused,
                busy: self.busy,
                permitted: self.permitted,
            }
        }
    }

    fn hash(seed: usize) -> PreviewHash {
        let luma: Vec<u8> = (0..PREVIEW_LENGTH)
            .map(|index| u8::try_from((index * seed) % 251).unwrap_or_default())
            .collect();
        PreviewHash::from_luma(&luma).unwrap_or(PreviewHash::EMPTY)
    }

    fn seconds(value: u64) -> i64 {
        i64::try_from(Duration::from_secs(value).as_millis()).unwrap_or_default()
    }

    fn minutes(value: u64) -> i64 {
        seconds(value * 60)
    }

    #[test]
    fn the_first_look_at_a_screen_is_always_a_capture() {
        assert!(policy().evaluate(&tick(START).build()).captures());
    }

    #[test]
    fn a_paused_locked_unpermitted_or_denied_screen_is_never_captured() {
        let policy = policy();
        assert_eq!(
            policy.evaluate(&tick(START).paused().build()).reason(),
            Some(SkipReason::Paused)
        );
        assert_eq!(
            policy.evaluate(&tick(START).locked().build()).reason(),
            Some(SkipReason::ScreenLocked)
        );
        assert_eq!(
            policy.evaluate(&tick(START).unpermitted().build()).reason(),
            Some(SkipReason::NoPermission)
        );
        assert_eq!(
            policy
                .evaluate(&tick(START).bundle("com.1password.1password").build())
                .reason(),
            Some(SkipReason::DeniedApp)
        );
        assert_eq!(
            policy
                .evaluate(&tick(START).title(Some("Search — Private Browsing")).build())
                .reason(),
            Some(SkipReason::PrivateWindow)
        );
    }

    #[test]
    fn pause_outranks_every_other_reason() {
        let decision = policy().evaluate(
            &tick(START)
                .paused()
                .locked()
                .bundle("com.1password.1password")
                .build(),
        );
        assert_eq!(decision.reason(), Some(SkipReason::Paused));
    }

    #[test]
    fn backpressure_drops_the_tick_rather_than_queueing_it() {
        assert_eq!(
            policy().evaluate(&tick(START).busy().build()).reason(),
            Some(SkipReason::Busy)
        );
    }

    #[test]
    fn a_window_title_change_captures_without_waiting_for_the_heartbeat() {
        let mut policy = policy();
        policy.record_capture(&tick(START).build(), hash(3));
        assert_eq!(
            policy.evaluate(&tick(START + seconds(4)).build()).reason(),
            Some(SkipReason::Heartbeat)
        );
        let switched = tick(START + seconds(4))
            .title(Some("vim main.dart"))
            .build();
        assert!(policy.evaluate(&switched).captures());
    }

    #[test]
    fn the_minimum_interval_floors_a_burst_of_context_changes() {
        let mut policy = policy();
        policy.record_capture(&tick(START).build(), hash(3));
        let rapid = tick(START + seconds(1)).bundle("com.apple.Safari").build();
        assert_eq!(
            policy.evaluate(&rapid).reason(),
            Some(SkipReason::MinimumInterval)
        );
    }

    #[test]
    fn a_slow_changing_app_captures_far_less_often_than_an_interactive_one() {
        let mut policy = policy();
        let music = "com.apple.Music";
        assert_eq!(
            policy.tempo_for(&WindowContext {
                bundle_id: Some(music.to_owned()),
                ..WindowContext::default()
            }),
            AppTempo::SlowChanging
        );
        policy.record_capture(
            &tick(START).bundle(music).title(Some("Album")).build(),
            hash(3),
        );
        assert_eq!(
            policy
                .evaluate(
                    &tick(START + seconds(45))
                        .bundle(music)
                        .title(Some("Album"))
                        .build()
                )
                .reason(),
            Some(SkipReason::Heartbeat)
        );
        assert!(
            policy
                .evaluate(
                    &tick(START + minutes(4))
                        .bundle(music)
                        .title(Some("Album"))
                        .build()
                )
                .captures()
        );

        let mut interactive = self::policy();
        interactive.record_capture(&tick(START).build(), hash(3));
        assert!(
            interactive
                .evaluate(&tick(START + seconds(45)).build())
                .captures()
        );
    }

    #[test]
    fn the_heartbeat_stops_entirely_once_the_user_is_idle() {
        let mut policy = policy();
        policy.record_capture(&tick(START).build(), hash(3));
        assert_eq!(
            policy
                .evaluate(
                    &tick(START + minutes(10))
                        .idle(Duration::from_secs(5 * 60))
                        .build()
                )
                .reason(),
            Some(SkipReason::Idle)
        );
    }

    #[test]
    fn an_unchanged_preview_is_skipped_and_a_changed_one_is_kept() {
        let mut policy = policy();
        let first = hash(3);
        policy.record_capture(&tick(START).build(), first);
        let later = tick(START + seconds(30)).build();
        assert_eq!(
            policy.evaluate_preview(&later, first).reason(),
            Some(SkipReason::Unchanged)
        );
        assert!(policy.evaluate_preview(&later, hash(29)).captures());
    }

    #[test]
    fn a_new_window_always_beats_the_similarity_gate() {
        let mut policy = policy();
        let seen = hash(3);
        policy.record_capture(&tick(START).build(), seen);
        let elsewhere = tick(START + seconds(30))
            .bundle("com.apple.Safari")
            .title(Some("Docs"))
            .build();
        assert!(policy.evaluate_preview(&elsewhere, seen).captures());
    }

    #[test]
    fn reset_makes_the_next_tick_capture_immediately() {
        let mut policy = policy();
        policy.record_capture(&tick(START).build(), hash(3));
        policy.reset();
        assert!(
            policy
                .evaluate(&tick(START + seconds(1)).build())
                .captures()
        );
    }

    #[test]
    fn a_skipped_preview_moves_the_heartbeat_clock_so_the_screen_is_not_re_read_every_tick() {
        let mut policy = policy();
        let seen = hash(3);
        policy.record_capture(&tick(START).build(), seen);
        let later = tick(START + seconds(30)).build();
        policy.record_skipped_preview(&later, seen);
        assert_eq!(
            policy
                .evaluate(&tick(START + seconds(30) + seconds(4)).build())
                .reason(),
            Some(SkipReason::Heartbeat)
        );
    }
}
