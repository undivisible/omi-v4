//! Turns frames Rewind already stored into things the assistant knows.
//!
//! The screen is where most of a working day happens, and until now none of it
//! reached memory: claim extraction is refused for [`CaptureSource::Screen`]
//! because frames arrive at interface rates and a model call per frame would
//! spend the machine on window titles. That reasoning holds against extraction
//! per frame. It does not hold against captioning *some* frames on device,
//! which is what this does.
//!
//! Three bounds keep it cheap, and all three are checked here rather than
//! trusted to the caller:
//!
//! 1. At most one caption per [`MIN_CAPTION_INTERVAL_MS`], so a machine
//!    filling the timeline quickly captions no faster than a machine that is
//!    not.
//! 2. A frame whose perceptual hash is within [`DUPLICATE_DISTANCE`] of the
//!    last captioned one is skipped. The hash is already computed and stored,
//!    so a static screen costs nothing.
//! 3. Only frames newer than the last one captioned are considered, so a
//!    restart re-reads the index without re-captioning it.
//!
//! Privacy is applied a second time here, at caption time, against the
//! settings as they stand now: a denied app, a private-browsing window, or
//! window titles the user switched off are refused again even though the frame
//! is already on disk. If the policy in [`crate::rewind::privacy`] says a
//! frame should not have been captured, it is not captioned either.

use crate::rewind::dhash::PreviewHash;
use crate::rewind::models::WindowContext;
use crate::rewind::privacy::{PrivacySettings, looks_private};
use crate::rewind::{Frame, SkipReason};

/// The floor under the interval between captions. Twelve an hour, worst case,
/// whatever the capture rate.
pub const MIN_CAPTION_INTERVAL_MS: i64 = 5 * 60 * 1000;

/// Hamming distance between two frame hashes that still counts as the same
/// screen. Matches the capture policy's own similarity threshold.
pub const DUPLICATE_DISTANCE: u32 = 3;

const MAX_CAPTION_BYTES: usize = 4 * 1024 * 1024;

/// What the last caption run left behind, so the next one can tell what is new
/// and what is the same screen again.
#[derive(Clone, Debug, Default)]
pub struct CaptionCursor {
    pub last_frame_at_ms: i64,
    pub last_caption_at_ms: i64,
    pub last_hash: Option<PreviewHash>,
}

impl CaptionCursor {
    fn duplicate_of_last(&self, frame: &Frame) -> bool {
        let (Some(last), Some(hash)) = (self.last_hash, PreviewHash::try_parse(&frame.hash)) else {
            return false;
        };
        last.distance_to(hash) <= DUPLICATE_DISTANCE
    }

    /// Records a frame as captioned. `now_ms` is when the caption was taken,
    /// which is what the interval is measured from.
    pub fn advance(&mut self, frame: &Frame, now_ms: i64) {
        self.last_frame_at_ms = self.last_frame_at_ms.max(frame.captured_at_ms);
        self.last_caption_at_ms = now_ms;
        self.last_hash = PreviewHash::try_parse(&frame.hash);
    }
}

/// Whether a frame may be described at all, judged against the privacy
/// settings as they stand now rather than as they stood when it was captured.
pub fn admissible(frame: &Frame, privacy: &PrivacySettings) -> bool {
    if frame.bytes == 0 || usize::try_from(frame.bytes).is_ok_and(|bytes| bytes > MAX_CAPTION_BYTES)
    {
        return false;
    }
    let context = WindowContext {
        bundle_id: frame.bundle_id.clone(),
        app_name: frame.app_name.clone(),
        window_title: frame.window_title.clone(),
    };
    match privacy.denial_for(&context) {
        Some(SkipReason::DeniedApp | SkipReason::PrivateWindow) => false,
        Some(_) | None => !looks_private(frame.window_title.as_deref()),
    }
}

/// The one frame worth a caption right now, or `None` when nothing is.
///
/// `frames` is the store's index in capture order; the newest admissible frame
/// wins, because what is on screen now is what the user would ask about.
pub fn next_target<'a>(
    frames: &'a [Frame],
    cursor: &CaptionCursor,
    privacy: &PrivacySettings,
    now_ms: i64,
) -> Option<&'a Frame> {
    if now_ms.saturating_sub(cursor.last_caption_at_ms) < MIN_CAPTION_INTERVAL_MS {
        return None;
    }
    frames
        .iter()
        .rev()
        .find(|frame| frame.captured_at_ms > cursor.last_frame_at_ms && admissible(frame, privacy))
        .filter(|frame| !cursor.duplicate_of_last(frame))
}

/// What the model is asked about the frame. Deliberately a description of what
/// is visible, not a guess about what it means: a caption is an observation
/// and is remembered as one.
pub fn caption_prompt(frame: &Frame, privacy: &PrivacySettings) -> String {
    let mut context = String::new();
    if let Some(app) = frame
        .app_name
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        context.push_str(&format!("\n\nThe app is {app}."));
    }
    if privacy.record_window_titles
        && let Some(title) = frame
            .window_title
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
    {
        context.push_str(&format!(" The window is titled \"{title}\"."));
    }
    format!(
        "This is a screenshot of one person's own screen. In one or two sentences, say what \
         they are working on and what is actually visible. Describe only what you can see; \
         never guess at anything outside the frame, and never invent names, numbers or \
         dates.{context}"
    )
}

/// The claim a caption becomes. `subject` names the surface it was seen on so
/// the memory reads as an observation of a screen rather than as something the
/// user said.
pub fn caption_claim(
    frame: &Frame,
    caption: &str,
    privacy: &PrivacySettings,
) -> Option<zkr::ClaimInput> {
    let caption = crate::extraction::bounded_field(caption);
    if caption.is_empty() {
        return None;
    }
    let app = frame
        .app_name
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("An app");
    let subject = match privacy
        .record_window_titles
        .then(|| {
            frame
                .window_title
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
        })
        .flatten()
    {
        Some(title) => crate::extraction::bounded_field(&format!("{app} — {title}")),
        None => crate::extraction::bounded_field(app),
    };
    Some(zkr::ClaimInput {
        subject,
        predicate: "on screen".to_owned(),
        value: caption,
        kind: zkr::ClaimKind::Fact,
        valid_from: frame.captured_at_ms,
        tier: zkr::MemoryTier::ShortTerm,
        processing_state: zkr::MemoryProcessingState::Processed,
    })
}

/// The ingestion key a captioned frame is remembered under. The frame's path is
/// unique within the timeline, so re-captioning one updates in place rather
/// than duplicating.
pub fn ingestion_key(frame: &Frame) -> String {
    format!("screen:{}", frame.relative_path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rewind::models::Display;

    fn frame(app: &str, title: Option<&str>, at_ms: i64, hash: u64) -> Frame {
        Frame {
            captured_at_ms: at_ms,
            relative_path: format!("frames/{at_ms}.jpg"),
            bytes: 2_048,
            hash: format!("{hash:016x}"),
            display: Display::default(),
            app_name: Some(app.to_owned()),
            bundle_id: Some(format!("com.example.{}", app.to_lowercase())),
            window_title: title.map(str::to_owned),
            ocr_text: None,
        }
    }

    #[test]
    fn the_newest_admissible_frame_is_the_target() {
        let frames = [
            frame("Xcode", Some("hub.rs"), 1_000, 0x0f0f_0f0f_0f0f_0f0f),
            frame("Mail", Some("Invoice"), 2_000, 0xf0f0_f0f0_f0f0_f0f0),
        ];
        let target = next_target(
            &frames,
            &CaptionCursor::default(),
            &PrivacySettings::default(),
            10_000_000,
        )
        .unwrap_or_else(|| panic!("a target exists"));
        assert_eq!(target.captured_at_ms, 2_000);
    }

    #[test]
    fn captions_are_rate_limited() {
        let frames = [frame("Xcode", None, 2_000, 1)];
        let cursor = CaptionCursor {
            last_caption_at_ms: 10_000,
            ..CaptionCursor::default()
        };
        let privacy = PrivacySettings::default();
        assert!(
            next_target(
                &frames,
                &cursor,
                &privacy,
                10_000 + MIN_CAPTION_INTERVAL_MS - 1
            )
            .is_none()
        );
        assert!(
            next_target(&frames, &cursor, &privacy, 10_000 + MIN_CAPTION_INTERVAL_MS).is_some()
        );
    }

    #[test]
    fn the_same_screen_again_is_not_captioned_again() {
        let mut cursor = CaptionCursor::default();
        let first = frame("Xcode", Some("hub.rs"), 1_000, 0x0f0f_0f0f_0f0f_0f0f);
        cursor.advance(&first, 1_000);
        let privacy = PrivacySettings::default();
        let same = [frame("Xcode", Some("hub.rs"), 2_000, 0x0f0f_0f0f_0f0f_0f0e)];
        assert!(next_target(&same, &cursor, &privacy, 1_000 + MIN_CAPTION_INTERVAL_MS).is_none());
        let changed = [frame("Xcode", Some("hub.rs"), 2_000, 0xf0f0_f0f0_f0f0_f0f0)];
        assert!(
            next_target(&changed, &cursor, &privacy, 1_000 + MIN_CAPTION_INTERVAL_MS).is_some()
        );
    }

    #[test]
    fn frames_already_captioned_are_not_reconsidered() {
        let frames = [frame("Xcode", None, 1_000, 1)];
        let cursor = CaptionCursor {
            last_frame_at_ms: 1_000,
            ..CaptionCursor::default()
        };
        assert!(next_target(&frames, &cursor, &PrivacySettings::default(), 10_000_000).is_none());
    }

    #[test]
    fn denied_apps_and_private_windows_are_never_captioned() {
        let mut privacy = PrivacySettings::default();
        privacy.deny("com.example.secrets");
        let frames = [
            frame("Notes", Some("Plan"), 1_000, 1),
            frame("Safari", Some("Private Browsing"), 2_000, 2),
            frame("Secrets", Some("Vault"), 3_000, 3),
        ];
        let target = next_target(&frames, &CaptionCursor::default(), &privacy, 10_000_000)
            .unwrap_or_else(|| panic!("the notes frame is admissible"));
        assert_eq!(target.captured_at_ms, 1_000);
    }

    #[test]
    fn an_oversized_or_empty_frame_is_refused() {
        let privacy = PrivacySettings::default();
        let mut empty = frame("Xcode", None, 1_000, 1);
        empty.bytes = 0;
        assert!(!admissible(&empty, &privacy));
        let mut huge = frame("Xcode", None, 1_000, 1);
        huge.bytes = 64 * 1024 * 1024;
        assert!(!admissible(&huge, &privacy));
    }

    #[test]
    fn a_caption_becomes_a_screen_observation() {
        let frame = frame("Xcode", Some("hub.rs"), 4_200, 1);
        let privacy = PrivacySettings::default();
        let claim = caption_claim(&frame, "  Editing  the capture path.\n", &privacy)
            .unwrap_or_else(|| panic!("a caption becomes a claim"));
        assert_eq!(claim.subject, "Xcode — hub.rs");
        assert_eq!(claim.predicate, "on screen");
        assert_eq!(claim.value, "Editing the capture path.");
        assert_eq!(claim.kind, zkr::ClaimKind::Fact);
        assert_eq!(claim.valid_from, 4_200);
        assert_eq!(
            claim.processing_state,
            zkr::MemoryProcessingState::Processed
        );
        assert!(caption_claim(&frame, "   ", &privacy).is_none());
        assert_eq!(ingestion_key(&frame), "screen:frames/4200.jpg");
    }

    #[test]
    fn window_titles_are_withheld_when_the_user_turned_them_off() {
        let privacy = PrivacySettings {
            record_window_titles: false,
            ..PrivacySettings::default()
        };
        let frame = frame("Notes", Some("Divorce"), 1_000, 1);
        let claim = caption_claim(&frame, "A note is open.", &privacy)
            .unwrap_or_else(|| panic!("a caption becomes a claim"));
        assert_eq!(claim.subject, "Notes");
        assert!(!caption_prompt(&frame, &privacy).contains("Divorce"));
        assert!(caption_prompt(&frame, &PrivacySettings::default()).contains("Divorce"));
    }
}
