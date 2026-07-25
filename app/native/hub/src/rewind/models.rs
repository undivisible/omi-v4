//! The value types the capture policy and the store are written against.
//!
//! Nothing here does I/O and nothing here talks to the bridge: these are the
//! facts a decision is made from and the row shape those decisions leave on
//! disk. The signal types in [`crate::signals`] are converted into and out of
//! these at the runtime boundary, so the engine can be tested without a Dart
//! end attached.

use serde_json::{Map, Value};
use std::time::Duration;

/// What Omi knows about the screen at the instant the policy is asked whether
/// to capture. Deliberately tiny: the frontmost app, its bundle id, and the
/// window title. Nothing here is stored unless a frame is stored.
#[derive(Clone, Default, Eq, PartialEq)]
pub struct WindowContext {
    pub bundle_id: Option<String>,
    pub app_name: Option<String>,
    pub window_title: Option<String>,
}

impl WindowContext {
    /// Two contexts are the "same screen" for heartbeat purposes when the app
    /// and the window title both match. A title change (new tab, new document)
    /// is a context change and earns an immediate capture.
    pub fn same_as(&self, other: &Self) -> bool {
        self.bundle_id == other.bundle_id
            && self.app_name == other.app_name
            && self.window_title == other.window_title
    }
}

/// Window titles name documents, tabs and correspondents, so the only thing
/// this prints is whether there was one.
impl std::fmt::Debug for WindowContext {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("WindowContext")
            .field("bundle_id", &self.bundle_id)
            .field("app_name", &self.app_name)
            .field(
                "window_title",
                &self.window_title.as_ref().map(|_| "[redacted]"),
            )
            .finish()
    }
}

/// How often an app is worth looking at. Slow-changing surfaces (a paused
/// video, an album cover, a page of a book) do not repay a fast heartbeat, and
/// capturing them at the interactive rate is what makes naive continuous
/// capture eat battery and disk.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AppTempo {
    Interactive,
    SlowChanging,
}

/// The knobs behind the capture policy. Every duration is a policy decision,
/// not an implementation detail, so they live in one place and tests can pin
/// them.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PolicyConfig {
    /// Heartbeat for an ordinary app the user is working in.
    pub interactive_heartbeat: Duration,
    /// Heartbeat for apps classified [`AppTempo::SlowChanging`].
    pub slow_changing_heartbeat: Duration,
    /// No input for this long means the user is not at the machine; the
    /// heartbeat stops entirely until input returns.
    pub idle_after: Duration,
    /// A floor under the capture rate, so a burst of context changes (rapid
    /// window switching) cannot turn into a burst of full-frame captures.
    pub minimum_interval: Duration,
    /// Maximum Hamming distance between consecutive preview hashes that still
    /// counts as "the screen did not meaningfully change".
    pub similarity_threshold: u32,
}

impl Default for PolicyConfig {
    fn default() -> Self {
        Self {
            interactive_heartbeat: Duration::from_secs(20),
            slow_changing_heartbeat: Duration::from_secs(3 * 60),
            idle_after: Duration::from_secs(2 * 60),
            minimum_interval: Duration::from_secs(3),
            similarity_threshold: 3,
        }
    }
}

impl PolicyConfig {
    pub fn heartbeat_for(&self, tempo: AppTempo) -> Duration {
        match tempo {
            AppTempo::Interactive => self.interactive_heartbeat,
            AppTempo::SlowChanging => self.slow_changing_heartbeat,
        }
    }
}

/// How long frames live and how much disk they may occupy. Both bounds are
/// enforced on every write, oldest-first, and both are user-visible.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Retention {
    pub max_age: Duration,
    pub max_bytes: u64,
}

const GIGABYTE: u64 = 1024 * 1024 * 1024;
const DAY: Duration = Duration::from_secs(24 * 60 * 60);

impl Default for Retention {
    fn default() -> Self {
        Self {
            max_age: Duration::from_secs(14 * 24 * 60 * 60),
            max_bytes: 4 * GIGABYTE,
        }
    }
}

impl Retention {
    /// The four bounds the settings dropdown offers, in the order it shows
    /// them. The list is here rather than in the Flutter widget because which
    /// bounds a user may pick is a policy decision about how much of their
    /// screen history exists at all.
    pub const OPTIONS: [Self; 4] = [
        Self {
            max_age: Duration::from_secs(24 * 60 * 60),
            max_bytes: 512 * 1024 * 1024,
        },
        Self {
            max_age: Duration::from_secs(7 * 24 * 60 * 60),
            max_bytes: 2 * GIGABYTE,
        },
        Self {
            max_age: Duration::from_secs(14 * 24 * 60 * 60),
            max_bytes: 4 * GIGABYTE,
        },
        Self {
            max_age: Duration::from_secs(30 * 24 * 60 * 60),
            max_bytes: 8 * GIGABYTE,
        },
    ];

    pub fn max_age_days(&self) -> i64 {
        i64::try_from(self.max_age.as_secs() / DAY.as_secs()).unwrap_or(i64::MAX)
    }

    pub fn label(&self) -> String {
        let days = self.max_age_days();
        // The bound is a handful of gigabytes, so an f64 renders it exactly;
        // this is presentation only and never feeds the eviction arithmetic,
        // which stays in whole bytes.
        let gigabytes = self.max_bytes as f64 / GIGABYTE as f64;
        let size = if gigabytes >= 1.0 {
            if (gigabytes - gigabytes.round()).abs() < f64::EPSILON {
                format!("{gigabytes:.0} GB")
            } else {
                format!("{gigabytes:.1} GB")
            }
        } else {
            let megabytes = self.max_bytes as f64 / (1024.0 * 1024.0);
            format!("{} MB", megabytes.round())
        };
        format!("{days} {} · {size}", if days == 1 { "day" } else { "days" })
    }

    pub fn to_json(self) -> Value {
        let mut map = Map::new();
        map.insert("maxAgeDays".into(), Value::from(self.max_age_days()));
        map.insert("maxBytes".into(), Value::from(self.max_bytes));
        Value::Object(map)
    }

    /// A stored bound that is missing, malformed or non-positive falls back to
    /// the default rather than to "unbounded" — a broken settings file must
    /// never widen how much screen history is kept.
    pub fn from_json(value: Option<&Value>) -> Self {
        let Some(Value::Object(map)) = value else {
            return Self::default();
        };
        let days = map.get("maxAgeDays").and_then(Value::as_i64);
        let bytes = map.get("maxBytes").and_then(Value::as_u64);
        match (days, bytes) {
            (Some(days), Some(bytes)) if days > 0 && bytes > 0 => Self {
                max_age: DAY.saturating_mul(u32::try_from(days).unwrap_or(u32::MAX)),
                max_bytes: bytes,
            },
            _ => Self::default(),
        }
    }
}

/// One stored screenshot, as recorded in the on-disk index.
#[derive(Clone, Eq, PartialEq)]
pub struct Frame {
    /// Milliseconds since the Unix epoch. The index writes this back out as a
    /// UTC ISO-8601 instant, which is the format the Dart engine wrote, so an
    /// existing `index.jsonl` keeps loading across the move.
    pub captured_at_ms: i64,
    pub relative_path: String,
    pub bytes: u64,
    /// The 64-bit dHash of the preview this frame was accepted from, as hex.
    pub hash: String,
    pub app_name: Option<String>,
    pub bundle_id: Option<String>,
    pub window_title: Option<String>,
    /// Text read off this frame by Apple's Vision framework, on-device. This is
    /// what search and any downstream model actually reads — the image itself
    /// never leaves the machine.
    pub ocr_text: Option<String>,
}

/// A frame row is a description of what was on someone's screen, so the two
/// fields that quote it are never printed.
impl std::fmt::Debug for Frame {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Frame")
            .field("captured_at_ms", &self.captured_at_ms)
            .field("relative_path", &self.relative_path)
            .field("bytes", &self.bytes)
            .field("hash", &self.hash)
            .field("app_name", &self.app_name)
            .field("bundle_id", &self.bundle_id)
            .field(
                "window_title",
                &self.window_title.as_ref().map(|_| "[redacted]"),
            )
            .field("ocr_text", &self.ocr_text.as_ref().map(|_| "[redacted]"))
            .finish()
    }
}

impl Frame {
    pub fn to_json(&self) -> Value {
        let mut map = Map::new();
        map.insert(
            "at".into(),
            Value::from(format_instant(self.captured_at_ms)),
        );
        map.insert("path".into(), Value::from(self.relative_path.clone()));
        map.insert("bytes".into(), Value::from(self.bytes));
        map.insert("hash".into(), Value::from(self.hash.clone()));
        insert_optional(&mut map, "app", self.app_name.as_ref());
        insert_optional(&mut map, "bundleId", self.bundle_id.as_ref());
        insert_optional(&mut map, "title", self.window_title.as_ref());
        insert_optional(&mut map, "text", self.ocr_text.as_ref());
        Value::Object(map)
    }

    /// Returns `None` for any row that cannot be trusted, so one bad line in
    /// the index costs that frame and not the rest of the timeline.
    pub fn from_json(value: &Value) -> Option<Self> {
        let map = value.as_object()?;
        let captured_at_ms = parse_instant(map.get("at")?.as_str()?)?;
        let relative_path = map.get("path")?.as_str()?.to_owned();
        if relative_path.is_empty() {
            return None;
        }
        let bytes = map.get("bytes")?.as_u64()?;
        let hash = map.get("hash")?.as_str()?.to_owned();
        Some(Self {
            captured_at_ms,
            relative_path,
            bytes,
            hash,
            app_name: optional_string(map.get("app")),
            bundle_id: optional_string(map.get("bundleId")),
            window_title: optional_string(map.get("title")),
            ocr_text: optional_string(map.get("text")),
        })
    }
}

fn insert_optional(map: &mut Map<String, Value>, key: &str, value: Option<&String>) {
    if let Some(value) = value {
        map.insert(key.to_owned(), Value::from(value.clone()));
    }
}

fn optional_string(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(str::to_owned)
}

/// The index's instant format: UTC, milliseconds, `Z`. This is exactly what
/// `DateTime.toUtc().toIso8601String()` produced, and matching it byte for
/// byte is what lets a timeline recorded by the Dart engine survive the move.
pub fn format_instant(millis: i64) -> String {
    chrono::DateTime::from_timestamp_millis(millis)
        .unwrap_or_default()
        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

pub fn parse_instant(text: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(text)
        .ok()
        .map(|at| at.timestamp_millis())
}

#[cfg(test)]
mod tests {
    use super::{Frame, Retention, format_instant, parse_instant};
    use serde_json::Value;

    #[test]
    fn retention_labels_read_the_way_the_settings_dropdown_shows_them() {
        let labels: Vec<String> = Retention::OPTIONS.iter().map(Retention::label).collect();
        assert_eq!(
            labels,
            vec![
                "1 day · 512 MB".to_owned(),
                "7 days · 2 GB".to_owned(),
                "14 days · 4 GB".to_owned(),
                "30 days · 8 GB".to_owned(),
            ]
        );
    }

    #[test]
    fn a_broken_retention_row_falls_back_to_the_default_rather_than_to_unbounded() {
        assert_eq!(Retention::from_json(None), Retention::default());
        assert_eq!(
            Retention::from_json(Some(&Value::String("nonsense".into()))),
            Retention::default()
        );
        let negative = serde_json::json!({ "maxAgeDays": -1, "maxBytes": 10 });
        assert_eq!(Retention::from_json(Some(&negative)), Retention::default());
        let zero_bytes = serde_json::json!({ "maxAgeDays": 3, "maxBytes": 0 });
        assert_eq!(
            Retention::from_json(Some(&zero_bytes)),
            Retention::default()
        );
        let good = serde_json::json!({ "maxAgeDays": 3, "maxBytes": 99 });
        let parsed = Retention::from_json(Some(&good));
        assert_eq!(parsed.max_age_days(), 3);
        assert_eq!(parsed.max_bytes, 99);
    }

    #[test]
    fn a_frame_row_round_trips_through_the_index_format() {
        let frame = Frame {
            captured_at_ms: 1_784_000_000_000,
            relative_path: "frames/2026-07-23/1784000000000.jpg".to_owned(),
            bytes: 64,
            hash: "0123456789abcdef".to_owned(),
            app_name: Some("Terminal".to_owned()),
            bundle_id: Some("com.apple.Terminal".to_owned()),
            window_title: Some("zsh".to_owned()),
            ocr_text: Some("flutter analyze".to_owned()),
        };
        let encoded = frame.to_json();
        assert_eq!(Frame::from_json(&encoded), Some(frame));
        // Absent optionals stay absent rather than becoming nulls, so the
        // index a Dart-era build wrote and the one this writes are the same
        // bytes for the same frame.
        let bare = serde_json::json!({
            "at": "2026-07-23T10:00:00.000Z",
            "path": "frames/2026-07-23/1.jpg",
            "bytes": 1,
            "hash": "a",
        });
        let Some(parsed) = Frame::from_json(&bare) else {
            panic!("a complete row parses");
        };
        assert_eq!(parsed.to_json(), bare);
    }

    #[test]
    fn a_row_missing_a_required_field_is_dropped_rather_than_guessed_at() {
        for broken in [
            serde_json::json!({ "path": "a", "bytes": 1, "hash": "a" }),
            serde_json::json!({ "at": "2026-07-23T10:00:00.000Z", "bytes": 1, "hash": "a" }),
            serde_json::json!({ "at": "2026-07-23T10:00:00.000Z", "path": "", "bytes": 1, "hash": "a" }),
            serde_json::json!({ "at": "not a date", "path": "a", "bytes": 1, "hash": "a" }),
            serde_json::json!({ "at": "2026-07-23T10:00:00.000Z", "path": "a", "bytes": -1, "hash": "a" }),
            serde_json::json!({ "at": "2026-07-23T10:00:00.000Z", "path": "a", "bytes": 1 }),
            Value::String("not an object".into()),
        ] {
            assert_eq!(Frame::from_json(&broken), None);
        }
    }

    #[test]
    fn instants_render_the_way_the_dart_engine_wrote_them() {
        assert_eq!(
            format_instant(1_784_800_800_000),
            "2026-07-23T10:00:00.000Z"
        );
        assert_eq!(
            parse_instant("2026-07-23T10:00:00.000Z"),
            Some(1_784_800_800_000)
        );
        assert_eq!(
            parse_instant("2026-07-23T12:00:00.000+02:00"),
            Some(1_784_800_800_000)
        );
        assert_eq!(parse_instant("nonsense"), None);
    }

    #[test]
    fn a_redacted_debug_never_quotes_the_screen() {
        let frame = Frame {
            captured_at_ms: 0,
            relative_path: "frames/a.jpg".to_owned(),
            bytes: 1,
            hash: "a".to_owned(),
            app_name: Some("Mail".to_owned()),
            bundle_id: None,
            window_title: Some("Re: severance terms".to_owned()),
            ocr_text: Some("account number 1234".to_owned()),
        };
        let debug = format!("{frame:?}");
        assert!(!debug.contains("severance"));
        assert!(!debug.contains("1234"));
        assert!(debug.contains("[redacted]"));
    }
}
