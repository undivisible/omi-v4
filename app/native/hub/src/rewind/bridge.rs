//! Translation between the bridge's signal types and the engine's own.
//!
//! The engine is written against plain values so its rules can be tested
//! without a Dart end attached, and the signal types are shaped by what the
//! bridge can carry. Keeping the mapping in one file is what lets both stay
//! honest: nothing in [`super::engine`] knows a MethodChannel exists, and
//! nothing in [`crate::signals`] knows what a heartbeat is.

use std::path::Path;

use super::engine::{Directive, Request, Response, Status};
use super::models::{Frame, Retention, WindowContext};
use super::privacy::SkipReason;
use crate::signals::{
    RewindDirective, RewindFrameRecord, RewindPayload, RewindRequest, RewindRetentionOption,
    RewindSkipReason, RewindStatus, RewindWindowContext,
};

impl From<RewindWindowContext> for WindowContext {
    fn from(context: RewindWindowContext) -> Self {
        Self {
            bundle_id: trimmed(context.bundle_id),
            app_name: trimmed(context.app_name),
            window_title: trimmed(context.window_title),
        }
    }
}

/// A blank field is the absence of a fact, not the empty string. The Swift
/// side already trims, but normalizing here means a stray space can never make
/// two identical screens look like a context change and earn a needless frame.
fn trimmed(value: Option<String>) -> Option<String> {
    value
        .map(|text| text.trim().to_owned())
        .filter(|text| !text.is_empty())
}

/// Converts one request. Returns `None` for [`RewindRequest::Open`], which is
/// not something the engine handles — it is what creates the engine — so the
/// caller has to deal with it before this point.
pub fn request_from_signal(request: RewindRequest) -> Option<Request> {
    Some(match request {
        RewindRequest::Open { .. } => return None,
        RewindRequest::Tick {
            context,
            idle_ms,
            locked,
            permitted,
        } => Request::Tick {
            context: context.into(),
            idle_ms: idle_ms.max(0),
            locked,
            permitted,
        },
        RewindRequest::PreviewTaken { step_id, luma } => Request::PreviewTaken { step_id, luma },
        RewindRequest::FrameEncoded {
            step_id,
            jpeg,
            ocr_text,
        } => Request::FrameEncoded {
            step_id,
            jpeg,
            ocr_text: trimmed(ocr_text),
        },
        RewindRequest::SetEnabled { enabled } => Request::SetEnabled(enabled),
        RewindRequest::SetPaused { paused } => Request::SetPaused(paused),
        RewindRequest::SetRetention {
            max_age_days,
            max_bytes,
        } => Request::SetRetention {
            max_age_days,
            max_bytes,
        },
        RewindRequest::SetPrivacyFlags {
            skip_private_browsing,
            record_window_titles,
            read_on_screen_text,
        } => Request::SetPrivacyFlags {
            skip_private_browsing,
            record_window_titles,
            read_on_screen_text,
        },
        RewindRequest::DenyBundleId { bundle_id } => Request::DenyBundleId(bundle_id),
        RewindRequest::AllowBundleId { bundle_id } => Request::AllowBundleId(bundle_id),
        RewindRequest::ListFrames { limit } => Request::ListFrames {
            limit: bounded(limit),
        },
        RewindRequest::Search { query, limit } => Request::Search {
            query,
            limit: bounded(limit),
        },
        RewindRequest::DeleteAll => Request::DeleteAll,
        RewindRequest::DeleteLast { window_ms } => Request::DeleteLast {
            window_ms: window_ms.max(0),
        },
        RewindRequest::DeleteFrame { relative_path } => Request::DeleteFrame { relative_path },
        RewindRequest::Status => Request::Status,
    })
}

/// The timeline is drawn a page at a time, so an unbounded limit is a client
/// mistake rather than a request. Zero means "the default page".
const DEFAULT_FRAME_LIMIT: usize = 200;
const MAX_FRAME_LIMIT: usize = 2_000;

fn bounded(limit: u32) -> usize {
    match limit as usize {
        0 => DEFAULT_FRAME_LIMIT,
        value => value.min(MAX_FRAME_LIMIT),
    }
}

pub fn payload_from_response(response: Response, root: &Path) -> RewindPayload {
    match response {
        Response::Directive { step_id, directive } => RewindPayload::Directive {
            step_id,
            directive: directive_to_signal(directive),
        },
        Response::Status(status) => RewindPayload::Status(status_to_signal(&status)),
        Response::Frames(frames) => RewindPayload::Frames {
            frames: frames
                .iter()
                .map(|frame| frame_to_signal(frame, root))
                .collect(),
        },
    }
}

fn directive_to_signal(directive: Directive) -> RewindDirective {
    match directive {
        Directive::Preview => RewindDirective::Preview,
        Directive::Idle { reason } => RewindDirective::Idle {
            reason: reason_to_signal(reason),
        },
        Directive::Encode { recognize_text } => RewindDirective::Encode { recognize_text },
        Directive::Discard { reason } => RewindDirective::Discard {
            reason: reason_to_signal(reason),
        },
        Directive::Stored => RewindDirective::Stored,
    }
}

fn reason_to_signal(reason: SkipReason) -> RewindSkipReason {
    match reason {
        SkipReason::DeniedApp => RewindSkipReason::DeniedApp,
        SkipReason::PrivateWindow => RewindSkipReason::PrivateWindow,
        SkipReason::ScreenLocked => RewindSkipReason::ScreenLocked,
        SkipReason::Paused => RewindSkipReason::Paused,
        SkipReason::Idle => RewindSkipReason::Idle,
        SkipReason::Heartbeat => RewindSkipReason::Heartbeat,
        SkipReason::MinimumInterval => RewindSkipReason::MinimumInterval,
        SkipReason::Busy => RewindSkipReason::Busy,
        SkipReason::Unchanged => RewindSkipReason::Unchanged,
        SkipReason::NoPermission => RewindSkipReason::NoPermission,
    }
}

fn status_to_signal(status: &Status) -> RewindStatus {
    RewindStatus {
        enabled: status.enabled,
        paused: status.paused,
        recording: status.recording,
        retention_max_age_days: status.retention.max_age_days(),
        retention_max_bytes: status.retention.max_bytes,
        retention_options: Retention::OPTIONS
            .iter()
            .map(|option| RewindRetentionOption {
                max_age_days: option.max_age_days(),
                max_bytes: option.max_bytes,
                label: option.label(),
            })
            .collect(),
        denied_bundle_ids: status.privacy.denied_bundle_ids.iter().cloned().collect(),
        skip_private_browsing: status.privacy.skip_private_browsing,
        record_window_titles: status.privacy.record_window_titles,
        read_on_screen_text: status.privacy.read_on_screen_text,
        last_skip_reason: status.last_skip_reason.map(reason_to_signal),
        last_capture_at_ms: status.last_capture_at_ms,
        captured_this_session: status.captured_this_session,
        frame_count: status.frame_count,
        total_bytes: status.total_bytes,
        oldest_capture_at_ms: status.oldest_capture_at_ms,
        permitted: status.permitted,
        locked: status.locked,
    }
}

fn frame_to_signal(frame: &Frame, root: &Path) -> RewindFrameRecord {
    RewindFrameRecord {
        captured_at_ms: frame.captured_at_ms,
        relative_path: frame.relative_path.clone(),
        absolute_path: root
            .join(&frame.relative_path)
            .to_string_lossy()
            .into_owned(),
        bytes: frame.bytes,
        hash: frame.hash.clone(),
        app_name: frame.app_name.clone(),
        bundle_id: frame.bundle_id.clone(),
        window_title: frame.window_title.clone(),
        ocr_text: frame.ocr_text.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::{bounded, request_from_signal, trimmed};
    use crate::rewind::engine::Request;
    use crate::signals::{RewindRequest, RewindWindowContext};

    #[test]
    fn open_is_not_something_the_engine_handles() {
        assert!(
            request_from_signal(RewindRequest::Open {
                root: "/tmp/rewind".to_owned()
            })
            .is_none()
        );
    }

    #[test]
    fn a_blank_field_is_the_absence_of_a_fact() {
        assert_eq!(trimmed(Some("  ".to_owned())), None);
        assert_eq!(trimmed(Some("  zsh ".to_owned())), Some("zsh".to_owned()));
        assert_eq!(trimmed(None), None);
    }

    #[test]
    fn a_tick_normalizes_a_negative_idle_clock() {
        let Some(Request::Tick {
            idle_ms, context, ..
        }) = request_from_signal(RewindRequest::Tick {
            context: RewindWindowContext {
                bundle_id: Some("com.apple.Terminal".to_owned()),
                app_name: Some(" Terminal ".to_owned()),
                window_title: Some("   ".to_owned()),
            },
            idle_ms: -5,
            locked: false,
            permitted: true,
        })
        else {
            panic!("a tick converts");
        };
        assert_eq!(idle_ms, 0);
        assert_eq!(context.app_name.as_deref(), Some("Terminal"));
        assert_eq!(context.window_title, None);
    }

    #[test]
    fn a_page_size_is_always_bounded() {
        assert_eq!(bounded(0), 200);
        assert_eq!(bounded(10), 10);
        assert_eq!(bounded(u32::MAX), 2_000);
    }
}
