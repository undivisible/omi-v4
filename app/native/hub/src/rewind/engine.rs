//! Runs the capture policy against the store and the settings file, and
//! answers each step of the capture handshake with the one instruction the
//! Flutter side is allowed to carry out next.
//!
//! # The frame-economy invariant
//!
//! The capture surface on the Dart side is split in two on purpose: `preview`
//! grabs the screen and hands back only a 72-byte luminance thumbnail, holding
//! the full frame in native memory, and `encodeHeldFrame` turns that same held
//! frame into JPEG bytes. No frame is ever encoded and then thrown away, and
//! no encoded frame is ever decoded again.
//!
//! Moving the policy into Rust has to keep that true across a bridge that
//! cannot call back into Dart, so the engine never *asks* for pixels and then
//! decides. It is a state machine over three exchanges, and the decision sits
//! between the second and the third:
//!
//! 1. [`Request::Tick`] carries only what can be sampled without reading a
//!    single pixel — the frontmost window, the system idle clock, the lock and
//!    permission flags. Stage one of the policy answers [`Directive::Preview`]
//!    or [`Directive::Idle`]. A denied app or a private window is refused
//!    here, before the screen has been touched at all.
//! 2. [`Request::PreviewTaken`] carries the 72 luminance bytes, with the full
//!    frame still held, unencoded, on the native side. Stage two hashes them
//!    and answers [`Directive::Encode`] or [`Directive::Discard`].
//! 3. [`Request::FrameEncoded`] carries the bytes the encoder produced — and
//!    it is only ever sent in reply to [`Directive::Encode`], which is only
//!    ever issued once the similarity gate has already said keep.
//!
//! There is no path from a preview to an encode that does not pass through
//! stage two, because the step id the engine hands out in exchange two is the
//! only thing that unlocks exchange three.

use std::collections::HashMap;
use std::path::PathBuf;

use super::dhash::PreviewHash;
use super::models::{Display, Frame, PolicyConfig, Retention, WindowContext};
use super::policy::{CapturePolicy, Tick};
use super::privacy::{PrivacySettings, SkipReason};
use super::settings::{Settings, SettingsFile};
use super::store::{NewFrame, Store};

/// The largest encoded frame the engine will file. A screen grab bigger than
/// this is a malformed encode rather than a screenshot, and refusing it keeps
/// one bad frame from spending the whole retention budget at once.
const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;

/// One step of the capture handshake, or one thing the user asked for.
#[derive(Clone, Debug)]
pub enum Request {
    /// A scheduled evaluation. Everything in it is readable without touching
    /// the framebuffer.
    Tick {
        context: WindowContext,
        display: Display,
        idle_ms: i64,
        locked: bool,
        permitted: bool,
    },
    /// The luminance preview for the step the engine asked to preview. An
    /// empty or short buffer means the capture failed.
    PreviewTaken {
        step_id: u64,
        luma: Vec<u8>,
    },
    /// The encoded frame for the step the engine asked to encode. Empty bytes
    /// mean the held frame was gone by the time the encoder ran.
    FrameEncoded {
        step_id: u64,
        jpeg: Vec<u8>,
        ocr_text: Option<String>,
    },
    SetEnabled(bool),
    SetPaused(bool),
    SetRetention {
        max_age_days: i64,
        max_bytes: u64,
    },
    SetPrivacyFlags {
        skip_private_browsing: bool,
        record_window_titles: bool,
        read_on_screen_text: bool,
    },
    DenyBundleId(String),
    AllowBundleId(String),
    ListFrames {
        limit: usize,
    },
    Search {
        query: String,
        limit: usize,
    },
    DeleteAll,
    /// "Forget the last hour": everything captured within `window_ms` of now.
    DeleteLast {
        window_ms: i64,
    },
    DeleteFrame {
        relative_path: String,
    },
    Status,
}

/// The single thing the Flutter side must do next for the step it named.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Directive {
    /// Capture a preview and hold the frame. The only directive that reads
    /// pixels, and it is never issued for a screen the privacy rules refused.
    Preview,
    /// Nothing is held; do nothing.
    Idle { reason: SkipReason },
    /// Encode the held frame, optionally recognizing text in the same pass.
    /// Only ever issued after the similarity gate has decided to keep it.
    Encode { recognize_text: bool },
    /// Drop the held frame without encoding it.
    Discard { reason: SkipReason },
    /// The frame is on disk.
    Stored,
}

/// Just enough state for the UI to tell the truth about whether the screen is
/// being recorded right now.
#[derive(Clone, Debug)]
pub struct Status {
    pub enabled: bool,
    pub paused: bool,
    /// True only when a frame could actually be taken right now: enabled, not
    /// paused, permission granted, screen unlocked.
    pub recording: bool,
    pub retention: Retention,
    pub privacy: PrivacySettings,
    pub last_skip_reason: Option<SkipReason>,
    pub last_capture_at_ms: Option<i64>,
    pub captured_this_session: u64,
    pub frame_count: u64,
    pub total_bytes: u64,
    pub oldest_capture_at_ms: Option<i64>,
    pub permitted: bool,
    pub locked: bool,
    /// Where the frames live, so the timeline can render them without the
    /// Flutter side having to re-derive the path convention.
    pub root: String,
}

#[derive(Clone, Debug)]
pub enum Response {
    Directive { step_id: u64, directive: Directive },
    Status(Box<Status>),
    Frames(Vec<Frame>),
}

/// The half-finished capture the engine is waiting on. Exactly one may exist:
/// a second tick that arrives while one is open is backpressure, and the
/// policy answers it with [`SkipReason::Busy`] rather than starting a rival
/// step that would orphan the held frame.
struct PendingStep {
    id: u64,
    display: Display,
    tick: Tick,
    stage: Stage,
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum Stage {
    AwaitingPreview,
    AwaitingEncode { hash: PreviewHash },
}

pub struct Engine {
    store: Store,
    settings_file: SettingsFile,
    settings: Settings,
    policies: HashMap<String, CapturePolicy>,
    pending: Option<PendingStep>,
    next_step_id: u64,
    last_skip_reason: Option<SkipReason>,
    last_capture_at_ms: Option<i64>,
    captured_this_session: u64,
    permitted: bool,
    locked: bool,
}

impl Engine {
    /// Opens the timeline under `root` (`~/.omi/rewind`), reading the settings
    /// file and the frame index. Both are created lazily, so a first run costs
    /// one directory and nothing else — an engine that has never recorded
    /// leaves no frames behind.
    pub fn open(root: PathBuf) -> Self {
        let mut settings_file = SettingsFile::new(&root);
        let settings = settings_file.read();
        let mut store = Store::new(root);
        store.load();
        Self {
            store,
            settings_file,
            settings,
            policies: HashMap::new(),
            pending: None,
            next_step_id: 1,
            last_skip_reason: None,
            last_capture_at_ms: None,
            captured_this_session: 0,
            permitted: false,
            locked: false,
        }
    }

    pub fn settings(&self) -> &Settings {
        &self.settings
    }

    /// Where this timeline lives. The frames are addressed relative to it, so
    /// the bridge needs it to hand absolute paths to the image renderer.
    pub fn root(&self) -> &std::path::Path {
        self.store.root()
    }

    /// The frame index, in capture order.
    pub fn stored_frames(&self) -> &[Frame] {
        self.store.frames()
    }

    /// Where one frame's image actually is, for a reader that needs the bytes
    /// rather than the row.
    pub fn frame_path(&self, frame: &Frame) -> PathBuf {
        self.store.file_for(frame)
    }

    pub fn handle(&mut self, request: Request, now_ms: i64) -> Response {
        match request {
            Request::Tick {
                context,
                display,
                idle_ms,
                locked,
                permitted,
            } => self.tick(context, display, idle_ms, locked, permitted, now_ms),
            Request::PreviewTaken { step_id, luma } => self.preview_taken(step_id, &luma),
            Request::FrameEncoded {
                step_id,
                jpeg,
                ocr_text,
            } => self.frame_encoded(step_id, &jpeg, ocr_text),
            Request::SetEnabled(enabled) => self.set_enabled(enabled),
            Request::SetPaused(paused) => self.set_paused(paused),
            Request::SetRetention {
                max_age_days,
                max_bytes,
            } => self.set_retention(max_age_days, max_bytes, now_ms),
            Request::SetPrivacyFlags {
                skip_private_browsing,
                record_window_titles,
                read_on_screen_text,
            } => {
                let mut privacy = self.settings.privacy.clone();
                privacy.skip_private_browsing = skip_private_browsing;
                privacy.record_window_titles = record_window_titles;
                privacy.read_on_screen_text = read_on_screen_text;
                self.set_privacy(privacy)
            }
            Request::DenyBundleId(bundle_id) => {
                let mut privacy = self.settings.privacy.clone();
                privacy.deny(&bundle_id);
                self.set_privacy(privacy)
            }
            Request::AllowBundleId(bundle_id) => {
                let mut privacy = self.settings.privacy.clone();
                privacy.allow(&bundle_id);
                self.set_privacy(privacy)
            }
            Request::ListFrames { limit } => Response::Frames(
                self.store
                    .frames()
                    .iter()
                    .rev()
                    .take(limit)
                    .cloned()
                    .collect(),
            ),
            Request::Search { query, limit } => Response::Frames(self.store.search(&query, limit)),
            Request::DeleteAll => {
                self.store.delete_all();
                self.policies.values_mut().for_each(CapturePolicy::reset);
                self.status()
            }
            Request::DeleteLast { window_ms } => {
                self.store
                    .delete_range(now_ms.saturating_sub(window_ms), now_ms);
                self.policies.values_mut().for_each(CapturePolicy::reset);
                self.status()
            }
            Request::DeleteFrame { relative_path } => {
                self.store.delete(&relative_path);
                self.status()
            }
            Request::Status => self.status(),
        }
    }

    /// Stage one. Nothing here has looked at the screen.
    fn tick(
        &mut self,
        context: WindowContext,
        display: Display,
        idle_ms: i64,
        locked: bool,
        permitted: bool,
        now_ms: i64,
    ) -> Response {
        self.refresh_settings();
        self.permitted = permitted;
        self.locked = locked;
        let tick = Tick {
            now_ms,
            context,
            idle_ms,
            locked,
            // Backpressure: the previous frame has not finished encoding or
            // writing, so this one is dropped rather than queued behind it.
            busy: self.pending.is_some(),
            paused: !self.settings.recording(),
            permitted,
        };

        let policy = self.policies.entry(display.id.clone()).or_insert_with(|| {
            CapturePolicy::new(PolicyConfig::default(), self.settings.privacy.clone())
        });
        let decision = policy.evaluate(&tick);
        if let Some(reason) = decision.reason() {
            self.last_skip_reason = Some(reason);
            // A step that is already open keeps its id; the Busy answer is
            // about this tick, not about the frame still being held.
            let step_id = self.pending.as_ref().map_or(0, |pending| pending.id);
            return Response::Directive {
                step_id,
                directive: Directive::Idle { reason },
            };
        }

        let step_id = self.next_step_id;
        self.next_step_id = self.next_step_id.wrapping_add(1);
        self.pending = Some(PendingStep {
            id: step_id,
            display,
            tick,
            stage: Stage::AwaitingPreview,
        });
        Response::Directive {
            step_id,
            directive: Directive::Preview,
        }
    }

    /// Stage two. The full frame is held natively and has not been encoded.
    fn preview_taken(&mut self, step_id: u64, luma: &[u8]) -> Response {
        let Some(pending) = self.pending.take() else {
            return self.stale(step_id);
        };
        if pending.id != step_id || pending.stage != Stage::AwaitingPreview {
            // Put the real step back: an out-of-order message must not cancel
            // the step that is genuinely in flight.
            self.pending = Some(pending);
            return self.stale(step_id);
        }

        let Some(hash) = PreviewHash::from_luma(luma) else {
            // No preview means no capture happened, which on macOS is what a
            // withdrawn screen-recording grant looks like.
            self.last_skip_reason = Some(SkipReason::NoPermission);
            return Response::Directive {
                step_id,
                directive: Directive::Discard {
                    reason: SkipReason::NoPermission,
                },
            };
        };

        let policy = self
            .policies
            .entry(pending.display.id.clone())
            .or_insert_with(|| {
                CapturePolicy::new(PolicyConfig::default(), self.settings.privacy.clone())
            });
        if let Some(reason) = policy.evaluate_preview(&pending.tick, hash).reason() {
            policy.record_skipped_preview(&pending.tick, hash);
            self.last_skip_reason = Some(reason);
            // The full frame is still sitting in native memory, unencoded. Drop it.
            return Response::Directive {
                step_id,
                directive: Directive::Discard { reason },
            };
        }

        let recognize_text = self.settings.privacy.read_on_screen_text;
        self.pending = Some(PendingStep {
            id: pending.id,
            display: pending.display,
            tick: pending.tick,
            stage: Stage::AwaitingEncode { hash },
        });
        Response::Directive {
            step_id,
            directive: Directive::Encode { recognize_text },
        }
    }

    /// Stage three. These bytes exist only because stage two asked for them.
    fn frame_encoded(&mut self, step_id: u64, jpeg: &[u8], ocr_text: Option<String>) -> Response {
        let Some(pending) = self.pending.take() else {
            return self.stale(step_id);
        };
        let Stage::AwaitingEncode { hash } = pending.stage else {
            self.pending = Some(pending);
            return self.stale(step_id);
        };
        if pending.id != step_id {
            self.pending = Some(pending);
            return self.stale(step_id);
        }

        if jpeg.is_empty() {
            self.last_skip_reason = Some(SkipReason::NoPermission);
            return Response::Directive {
                step_id,
                directive: Directive::Idle {
                    reason: SkipReason::NoPermission,
                },
            };
        }
        if jpeg.len() > MAX_FRAME_BYTES {
            self.last_skip_reason = Some(SkipReason::Busy);
            return Response::Directive {
                step_id,
                directive: Directive::Idle {
                    reason: SkipReason::Busy,
                },
            };
        }

        let title = if self.settings.privacy.record_window_titles {
            pending.tick.context.window_title.clone()
        } else {
            None
        };
        let ocr_text = if self.settings.privacy.read_on_screen_text {
            ocr_text
        } else {
            None
        };
        let written = self.store.write(
            jpeg,
            NewFrame {
                captured_at_ms: pending.tick.now_ms,
                hash: hash.to_hex(),
                display: pending.display.clone(),
                app_name: pending.tick.context.app_name.clone(),
                bundle_id: pending.tick.context.bundle_id.clone(),
                window_title: title,
                ocr_text,
            },
            self.settings.retention,
        );
        if written.is_err() {
            // The bytes exist but could not be filed. That is a storage fault,
            // not a policy skip, and the next tick starts over rather than
            // leaving the heartbeat pinned to a frame nobody has.
            self.last_skip_reason = Some(SkipReason::Busy);
            return Response::Directive {
                step_id,
                directive: Directive::Idle {
                    reason: SkipReason::Busy,
                },
            };
        }
        if let Some(policy) = self.policies.get_mut(&pending.display.id) {
            policy.record_capture(&pending.tick, hash);
        }
        self.last_capture_at_ms = Some(pending.tick.now_ms);
        self.last_skip_reason = None;
        self.captured_this_session = self.captured_this_session.saturating_add(1);
        Response::Directive {
            step_id,
            directive: Directive::Stored,
        }
    }

    /// An answer for a step the engine is not waiting on. The safe instruction
    /// is always "drop whatever you are holding": a held frame with no step
    /// behind it can never become a stored frame, so it must not stay in
    /// memory.
    fn stale(&self, step_id: u64) -> Response {
        Response::Directive {
            step_id,
            directive: Directive::Discard {
                reason: SkipReason::Busy,
            },
        }
    }

    fn set_enabled(&mut self, enabled: bool) -> Response {
        if self.settings.enabled == enabled {
            return self.status();
        }
        let mut next = self.settings.clone();
        next.enabled = enabled;
        next.paused = false;
        self.persist(next);
        self.policies.values_mut().for_each(CapturePolicy::reset);
        self.pending = None;
        self.status()
    }

    fn set_paused(&mut self, paused: bool) -> Response {
        if self.settings.paused == paused {
            return self.status();
        }
        let mut next = self.settings.clone();
        next.paused = paused;
        self.persist(next);
        self.policies.values_mut().for_each(CapturePolicy::reset);
        self.pending = None;
        self.status()
    }

    fn set_retention(&mut self, max_age_days: i64, max_bytes: u64, now_ms: i64) -> Response {
        let retention = Retention::from_json(Some(&serde_json::json!({
            "maxAgeDays": max_age_days,
            "maxBytes": max_bytes,
        })));
        let mut next = self.settings.clone();
        next.retention = retention;
        self.persist(next);
        // A tightened bound applies to what is already on disk, immediately.
        // Deferring it to the next write would leave the user looking at a
        // setting that has not happened yet.
        self.store.enforce(retention, now_ms);
        self.status()
    }

    fn set_privacy(&mut self, privacy: PrivacySettings) -> Response {
        let mut next = self.settings.clone();
        next.privacy = privacy.clone();
        self.persist(next);
        for policy in self.policies.values_mut() {
            policy.privacy = privacy.clone();
        }
        self.status()
    }

    fn persist(&mut self, next: Settings) {
        self.settings = next;
        let _ = self.settings_file.write(&self.settings);
    }

    /// Picks up a change made by the other engine (the settings window and the
    /// capture loop are separate isolates sharing one settings file).
    fn refresh_settings(&mut self) {
        let Some(next) = self.settings_file.read_if_changed() else {
            return;
        };
        if next == self.settings {
            return;
        }
        let was_recording = self.settings.recording();
        self.settings = next;
        for policy in self.policies.values_mut() {
            policy.privacy = self.settings.privacy.clone();
        }
        if was_recording != self.settings.recording() {
            self.policies.values_mut().for_each(CapturePolicy::reset);
            self.pending = None;
        }
    }

    fn status(&self) -> Response {
        Response::Status(Box::new(Status {
            enabled: self.settings.enabled,
            paused: self.settings.paused,
            recording: self.settings.recording() && self.permitted && !self.locked,
            retention: self.settings.retention,
            privacy: self.settings.privacy.clone(),
            last_skip_reason: self.last_skip_reason,
            last_capture_at_ms: self.last_capture_at_ms,
            captured_this_session: self.captured_this_session,
            frame_count: self.store.frames().len() as u64,
            total_bytes: self.store.total_bytes(),
            oldest_capture_at_ms: self
                .store
                .frames()
                .first()
                .map(|frame| frame.captured_at_ms),
            permitted: self.permitted,
            locked: self.locked,
            root: self.store.root().to_string_lossy().into_owned(),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::{Directive, Engine, Request, Response, Status};
    use crate::rewind::dhash::PREVIEW_LENGTH;
    use crate::rewind::models::{Display, WindowContext};
    use crate::rewind::privacy::SkipReason;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    /// 2026-07-23T09:00 UTC, the instant the Dart service suite counted from.
    const START: i64 = 1_784_797_200_000;

    struct Scratch(PathBuf);

    impl Scratch {
        fn new() -> Self {
            let id = COUNTER.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir()
                .join(format!("rewind_engine_test_{}_{id}", std::process::id()));
            let _ = std::fs::remove_dir_all(&root);
            let _ = std::fs::create_dir_all(&root);
            Self(root)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn terminal() -> WindowContext {
        WindowContext {
            bundle_id: Some("com.apple.Terminal".to_owned()),
            app_name: Some("Terminal".to_owned()),
            window_title: Some("zsh".to_owned()),
        }
    }

    fn preview(seed: usize) -> Vec<u8> {
        (0..PREVIEW_LENGTH)
            .map(|index| u8::try_from((index * seed) % 251).unwrap_or_default())
            .collect()
    }

    fn directive(response: &Response) -> Directive {
        match response {
            Response::Directive { directive, .. } => *directive,
            _ => panic!("expected a directive"),
        }
    }

    fn step_id(response: &Response) -> u64 {
        match response {
            Response::Directive { step_id, .. } => *step_id,
            _ => panic!("expected a directive"),
        }
    }

    fn status(response: &Response) -> Status {
        match response {
            Response::Status(status) => (**status).clone(),
            _ => panic!("expected a status"),
        }
    }

    /// Drives one whole capture: tick, preview, encode. Returns the terminal
    /// directive so a test can assert how far the frame got. `encoder` returns
    /// the bytes the encoder would have produced, and is not called at all
    /// when the policy never asks for an encode — which is the property the
    /// frame-economy invariant is about.
    fn run_step(
        engine: &mut Engine,
        now_ms: i64,
        luma: Vec<u8>,
        encodes: &mut u32,
        discards: &mut u32,
    ) -> Directive {
        let first = engine.handle(
            Request::Tick {
                context: terminal(),
                display: Display::default(),
                idle_ms: 0,
                locked: false,
                permitted: true,
            },
            now_ms,
        );
        let id = step_id(&first);
        match directive(&first) {
            Directive::Preview => {}
            terminal_directive => return terminal_directive,
        }
        let second = engine.handle(Request::PreviewTaken { step_id: id, luma }, now_ms);
        match directive(&second) {
            Directive::Encode { .. } => {}
            other => {
                if matches!(other, Directive::Discard { .. }) {
                    *discards += 1;
                }
                return other;
            }
        }
        *encodes += 1;
        let third = engine.handle(
            Request::FrameEncoded {
                step_id: id,
                jpeg: vec![7; 32],
                ocr_text: Some("flutter analyze".to_owned()),
            },
            now_ms,
        );
        directive(&third)
    }

    fn enable(engine: &mut Engine) {
        let _ = engine.handle(Request::SetEnabled(true), START);
    }

    #[test]
    fn captures_nothing_until_the_user_turns_it_on() {
        let scratch = Scratch::new();
        let mut engine = Engine::open(scratch.0.clone());
        let (mut encodes, mut discards) = (0, 0);
        assert_eq!(
            run_step(&mut engine, START, preview(3), &mut encodes, &mut discards),
            Directive::Idle {
                reason: SkipReason::Paused
            }
        );
        let status = status(&engine.handle(Request::Status, START));
        assert_eq!(status.frame_count, 0);
        assert_eq!(status.last_skip_reason, Some(SkipReason::Paused));
        assert!(!status.enabled);
        assert_eq!(encodes, 0);
    }

    #[test]
    fn stores_a_frame_with_its_on_device_text_once_enabled() {
        let scratch = Scratch::new();
        let mut engine = Engine::open(scratch.0.clone());
        enable(&mut engine);
        let (mut encodes, mut discards) = (0, 0);
        assert_eq!(
            run_step(&mut engine, START, preview(3), &mut encodes, &mut discards),
            Directive::Stored
        );
        let Response::Frames(frames) = engine.handle(Request::ListFrames { limit: 10 }, START)
        else {
            panic!("expected frames");
        };
        assert_eq!(frames.len(), 1);
        let Some(frame) = frames.first() else {
            panic!("one frame was stored");
        };
        assert_eq!(frame.ocr_text.as_deref(), Some("flutter analyze"));
        assert_eq!(frame.window_title.as_deref(), Some("zsh"));
        assert!(status(&engine.handle(Request::Status, START)).enabled);
    }

    #[test]
    fn never_encodes_a_frame_the_similarity_gate_rejects() {
        let scratch = Scratch::new();
        let mut engine = Engine::open(scratch.0.clone());
        enable(&mut engine);
        let (mut encodes, mut discards) = (0, 0);
        assert_eq!(
            run_step(&mut engine, START, preview(3), &mut encodes, &mut discards),
            Directive::Stored
        );
        assert_eq!(encodes, 1);

        let later = START + 60_000;
        assert_eq!(
            run_step(&mut engine, later, preview(3), &mut encodes, &mut discards),
            Directive::Discard {
                reason: SkipReason::Unchanged
            }
        );
        // The held frame was dropped without ever becoming bytes.
        assert_eq!(encodes, 1);
        assert!(discards > 0);
        let status = status(&engine.handle(Request::Status, later));
        assert_eq!(status.frame_count, 1);
        assert_eq!(status.last_skip_reason, Some(SkipReason::Unchanged));
    }

    #[test]
    fn pausing_stops_capture_and_says_so() {
        let scratch = Scratch::new();
        let mut engine = Engine::open(scratch.0.clone());
        enable(&mut engine);
        let _ = engine.handle(Request::SetPaused(true), START);
        let later = START + 60_000;
        let (mut encodes, mut discards) = (0, 0);
        assert_eq!(
            run_step(&mut engine, later, preview(3), &mut encodes, &mut discards),
            Directive::Idle {
                reason: SkipReason::Paused
            }
        );
        let status = status(&engine.handle(Request::Status, later));
        assert_eq!(status.frame_count, 0);
        assert!(status.paused);
        assert!(!status.recording);
        assert_eq!(encodes, 0);
    }

    #[test]
    fn an_excluded_app_is_never_photographed() {
        let scratch = Scratch::new();
        let mut engine = Engine::open(scratch.0.clone());
        enable(&mut engine);
        let _ = engine.handle(
            Request::DenyBundleId("com.apple.Terminal".to_owned()),
            START,
        );
        let (mut encodes, mut discards) = (0, 0);
        assert_eq!(
            run_step(&mut engine, START, preview(3), &mut encodes, &mut discards),
            Directive::Idle {
                reason: SkipReason::DeniedApp
            }
        );
        assert_eq!(encodes, 0);
        assert_eq!(
            status(&engine.handle(Request::Status, START)).frame_count,
            0
        );
    }

    #[test]
    fn a_locked_screen_halts_capture() {
        let scratch = Scratch::new();
        let mut engine = Engine::open(scratch.0.clone());
        enable(&mut engine);
        let response = engine.handle(
            Request::Tick {
                context: terminal(),
                display: Display::default(),
                idle_ms: 0,
                locked: true,
                permitted: true,
            },
            START,
        );
        assert_eq!(
            directive(&response),
            Directive::Idle {
                reason: SkipReason::ScreenLocked
            }
        );
        let status = status(&engine.handle(Request::Status, START));
        assert_eq!(status.frame_count, 0);
        assert!(!status.recording);
        assert!(status.locked);
    }

    #[test]
    fn turning_off_on_device_text_recognition_stops_transcribing() {
        let scratch = Scratch::new();
        let mut engine = Engine::open(scratch.0.clone());
        enable(&mut engine);
        let _ = engine.handle(
            Request::SetPrivacyFlags {
                skip_private_browsing: true,
                record_window_titles: true,
                read_on_screen_text: false,
            },
            START,
        );
        let first = engine.handle(
            Request::Tick {
                context: terminal(),
                display: Display::default(),
                idle_ms: 0,
                locked: false,
                permitted: true,
            },
            START,
        );
        let id = step_id(&first);
        let second = engine.handle(
            Request::PreviewTaken {
                step_id: id,
                luma: preview(3),
            },
            START,
        );
        assert_eq!(
            directive(&second),
            Directive::Encode {
                recognize_text: false
            }
        );
        // Even if the platform hands text back anyway, it is not stored.
        let _ = engine.handle(
            Request::FrameEncoded {
                step_id: id,
                jpeg: vec![7; 32],
                ocr_text: Some("flutter analyze".to_owned()),
            },
            START,
        );
        let Response::Frames(frames) = engine.handle(Request::ListFrames { limit: 10 }, START)
        else {
            panic!("expected frames");
        };
        assert_eq!(
            frames.first().and_then(|frame| frame.ocr_text.clone()),
            None
        );
    }

    #[test]
    fn window_titles_can_be_kept_out_of_the_store() {
        let scratch = Scratch::new();
        let mut engine = Engine::open(scratch.0.clone());
        enable(&mut engine);
        let _ = engine.handle(
            Request::SetPrivacyFlags {
                skip_private_browsing: true,
                record_window_titles: false,
                read_on_screen_text: true,
            },
            START,
        );
        let (mut encodes, mut discards) = (0, 0);
        assert_eq!(
            run_step(&mut engine, START, preview(3), &mut encodes, &mut discards),
            Directive::Stored
        );
        let Response::Frames(frames) = engine.handle(Request::ListFrames { limit: 10 }, START)
        else {
            panic!("expected frames");
        };
        let Some(frame) = frames.first() else {
            panic!("one frame was stored");
        };
        assert_eq!(frame.window_title, None);
        assert_eq!(frame.app_name.as_deref(), Some("Terminal"));
    }

    #[test]
    fn deleting_everything_really_removes_the_frames() {
        let scratch = Scratch::new();
        let mut engine = Engine::open(scratch.0.clone());
        enable(&mut engine);
        let (mut encodes, mut discards) = (0, 0);
        assert_eq!(
            run_step(&mut engine, START, preview(3), &mut encodes, &mut discards),
            Directive::Stored
        );
        let Response::Frames(frames) = engine.handle(Request::ListFrames { limit: 10 }, START)
        else {
            panic!("expected frames");
        };
        let Some(frame) = frames.first() else {
            panic!("one frame was stored");
        };
        let path = scratch.0.join(&frame.relative_path);
        assert!(path.exists());
        let after = status(&engine.handle(Request::DeleteAll, START));
        assert_eq!(after.frame_count, 0);
        assert!(!path.exists());
    }

    #[test]
    fn retention_is_applied_the_moment_it_is_tightened() {
        let scratch = Scratch::new();
        let mut engine = Engine::open(scratch.0.clone());
        enable(&mut engine);
        let (mut encodes, mut discards) = (0, 0);
        assert_eq!(
            run_step(&mut engine, START, preview(3), &mut encodes, &mut discards),
            Directive::Stored
        );
        let three_days_later = START + 3 * 24 * 60 * 60 * 1000;
        let after = status(&engine.handle(
            Request::SetRetention {
                max_age_days: 1,
                max_bytes: 1 << 30,
            },
            three_days_later,
        ));
        assert_eq!(after.frame_count, 0);
    }

    #[test]
    fn a_second_tick_while_a_frame_is_held_is_backpressure_not_a_rival_capture() {
        let scratch = Scratch::new();
        let mut engine = Engine::open(scratch.0.clone());
        enable(&mut engine);
        let first = engine.handle(
            Request::Tick {
                context: terminal(),
                display: Display::default(),
                idle_ms: 0,
                locked: false,
                permitted: true,
            },
            START,
        );
        assert_eq!(directive(&first), Directive::Preview);
        let held = step_id(&first);

        let second = engine.handle(
            Request::Tick {
                context: terminal(),
                display: Display::default(),
                idle_ms: 0,
                locked: false,
                permitted: true,
            },
            START + 10_000,
        );
        assert_eq!(
            directive(&second),
            Directive::Idle {
                reason: SkipReason::Busy
            }
        );
        // The open step survives, so the frame it is holding still has a way
        // to become a stored frame rather than being orphaned.
        let third = engine.handle(
            Request::PreviewTaken {
                step_id: held,
                luma: preview(3),
            },
            START,
        );
        assert_eq!(
            directive(&third),
            Directive::Encode {
                recognize_text: true
            }
        );
    }

    #[test]
    fn an_encode_cannot_be_reached_without_passing_the_similarity_gate() {
        let scratch = Scratch::new();
        let mut engine = Engine::open(scratch.0.clone());
        enable(&mut engine);
        let first = engine.handle(
            Request::Tick {
                context: terminal(),
                display: Display::default(),
                idle_ms: 0,
                locked: false,
                permitted: true,
            },
            START,
        );
        let id = step_id(&first);
        // Jumping straight to stage three with the id the engine handed out
        // for stage two is refused, and the answer is "drop what you hold".
        let jumped = engine.handle(
            Request::FrameEncoded {
                step_id: id,
                jpeg: vec![7; 32],
                ocr_text: None,
            },
            START,
        );
        assert_eq!(
            directive(&jumped),
            Directive::Discard {
                reason: SkipReason::Busy
            }
        );
        assert_eq!(
            status(&engine.handle(Request::Status, START)).frame_count,
            0
        );
    }

    #[test]
    fn a_failed_preview_reads_as_a_withdrawn_permission_and_drops_the_frame() {
        let scratch = Scratch::new();
        let mut engine = Engine::open(scratch.0.clone());
        enable(&mut engine);
        let first = engine.handle(
            Request::Tick {
                context: terminal(),
                display: Display::default(),
                idle_ms: 0,
                locked: false,
                permitted: true,
            },
            START,
        );
        let id = step_id(&first);
        let second = engine.handle(
            Request::PreviewTaken {
                step_id: id,
                luma: Vec::new(),
            },
            START,
        );
        assert_eq!(
            directive(&second),
            Directive::Discard {
                reason: SkipReason::NoPermission
            }
        );
    }

    #[test]
    fn an_empty_encode_result_stores_nothing() {
        let scratch = Scratch::new();
        let mut engine = Engine::open(scratch.0.clone());
        enable(&mut engine);
        let first = engine.handle(
            Request::Tick {
                context: terminal(),
                display: Display::default(),
                idle_ms: 0,
                locked: false,
                permitted: true,
            },
            START,
        );
        let id = step_id(&first);
        let _ = engine.handle(
            Request::PreviewTaken {
                step_id: id,
                luma: preview(3),
            },
            START,
        );
        let third = engine.handle(
            Request::FrameEncoded {
                step_id: id,
                jpeg: Vec::new(),
                ocr_text: None,
            },
            START,
        );
        assert_eq!(
            directive(&third),
            Directive::Idle {
                reason: SkipReason::NoPermission
            }
        );
        assert_eq!(
            status(&engine.handle(Request::Status, START)).frame_count,
            0
        );
    }

    #[test]
    fn settings_survive_a_reopen_and_the_deny_list_keeps_its_defaults() {
        let scratch = Scratch::new();
        let mut engine = Engine::open(scratch.0.clone());
        enable(&mut engine);
        let _ = engine.handle(Request::DenyBundleId("com.example.app".to_owned()), START);
        drop(engine);

        let reopened = Engine::open(scratch.0.clone());
        assert!(reopened.settings().enabled);
        assert!(
            reopened
                .settings()
                .privacy
                .denied_bundle_ids
                .contains("com.example.app")
        );
        assert!(
            reopened
                .settings()
                .privacy
                .denied_bundle_ids
                .contains("com.1password.1password")
        );
    }

    #[test]
    fn a_settings_change_from_the_other_engine_is_picked_up_on_the_next_tick() {
        let scratch = Scratch::new();
        let mut engine = Engine::open(scratch.0.clone());
        enable(&mut engine);
        // The settings window is a second engine over the same file.
        let mut other = Engine::open(scratch.0.clone());
        std::thread::sleep(std::time::Duration::from_millis(20));
        let _ = other.handle(Request::SetPaused(true), START);

        let response = engine.handle(
            Request::Tick {
                context: terminal(),
                display: Display::default(),
                idle_ms: 0,
                locked: false,
                permitted: true,
            },
            START,
        );
        assert_eq!(
            directive(&response),
            Directive::Idle {
                reason: SkipReason::Paused
            }
        );
    }

    #[test]
    fn search_and_delete_last_reach_the_stored_timeline() {
        let scratch = Scratch::new();
        let mut engine = Engine::open(scratch.0.clone());
        enable(&mut engine);
        let (mut encodes, mut discards) = (0, 0);
        assert_eq!(
            run_step(&mut engine, START, preview(3), &mut encodes, &mut discards),
            Directive::Stored
        );
        let Response::Frames(hits) = engine.handle(
            Request::Search {
                query: "flutter".to_owned(),
                limit: 200,
            },
            START,
        ) else {
            panic!("expected frames");
        };
        assert_eq!(hits.len(), 1);

        let after = status(&engine.handle(
            Request::DeleteLast {
                window_ms: 60 * 60 * 1000,
            },
            START + 1_000,
        ));
        assert_eq!(after.frame_count, 0);
    }
}
