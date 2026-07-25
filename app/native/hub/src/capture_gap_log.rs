//! Durable accounting for discontinuities in pendant capture.
//!
//! The evidence model requires every claim to carry a locator back to a real
//! time range, so a gap must be a first-class record: the audio either side of
//! it belongs to two different streams and must never be presented as one.
//!
//! The log lives next to the write-ahead log rather than in the client's
//! key-value store, because the two records only mean anything together — a
//! segment marked `gapBefore` is only interpretable against the gap that
//! precedes it, and a gap that survived a restart the segments did not would
//! describe a discontinuity in audio nobody has.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

/// How many gaps are kept. Old discontinuities stop being actionable long
/// before the ring they describe has been uploaded, and an unbounded log on a
/// device that flaps for days is its own failure.
pub const DEFAULT_GAP_LIMIT: usize = 100;

/// A recorded discontinuity in capture.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureGapRecord {
    pub device_id: String,
    /// The typed reason the previous session ended (a `DeviceAudioGapReason`
    /// name, or `sessionFailed` when the session died without a packet gap).
    pub reason: String,
    /// When the interrupted session stopped accepting audio.
    pub ended_at_ms: i64,
    /// The stream id that ended. Segments carrying it are closed for good.
    pub ended_stream_id: String,
    /// When capture resumed, or `None` while it has not.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resumed_at_ms: Option<i64>,
    /// The new stream id capture resumed under. Always different from
    /// `ended_stream_id`: a restart opens a new stream rather than continuing
    /// the old one, which is what makes the discontinuity impossible to
    /// re-splice.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resumed_stream_id: Option<String>,
}

impl CaptureGapRecord {
    pub fn resumed(&self, at_ms: i64, stream_id: &str) -> Self {
        Self {
            resumed_at_ms: Some(at_ms),
            resumed_stream_id: Some(stream_id.to_owned()),
            ..self.clone()
        }
    }
}

/// Bounded, restart-surviving gap log.
///
/// Recording must never fail the capture path, so every storage error is
/// swallowed: a gap that could not be written is a gap the UI cannot show, not
/// a reason to stop recording audio.
pub struct CaptureGapLog {
    /// Where the log is persisted, or `None` for a log that only lives as long
    /// as the process — what a build with no writable storage falls back to.
    path: Option<PathBuf>,
    limit: usize,
    gaps: Vec<CaptureGapRecord>,
}

impl CaptureGapLog {
    /// Opens the log at `path`, reading back whatever survived the last run. A
    /// file that cannot be read is treated as empty rather than fatal.
    pub fn open(path: impl Into<PathBuf>, limit: usize) -> Self {
        let path = path.into();
        let gaps = read_file(&path);
        Self {
            path: Some(path),
            limit: limit.max(1),
            gaps,
        }
    }

    pub fn volatile(limit: usize) -> Self {
        Self {
            path: None,
            limit: limit.max(1),
            gaps: Vec::new(),
        }
    }

    pub fn record(&mut self, gap: CaptureGapRecord) {
        self.gaps.push(gap);
        self.write();
    }

    /// Attaches the resume side to the most recent open gap for `device_id`.
    ///
    /// Most recent first, because a device that flapped repeatedly has several
    /// open gaps and only the last one is the gap this resume closes.
    pub fn record_resume(&mut self, device_id: &str, at_ms: i64, stream_id: &str) {
        let found = self
            .gaps
            .iter()
            .rposition(|gap| gap.device_id == device_id && gap.resumed_at_ms.is_none());
        let Some(index) = found else {
            return;
        };
        self.gaps[index] = self.gaps[index].resumed(at_ms, stream_id);
        self.write();
    }

    pub fn read(&self) -> &[CaptureGapRecord] {
        &self.gaps
    }

    fn write(&mut self) {
        if self.gaps.len() > self.limit {
            self.gaps.drain(..self.gaps.len() - self.limit);
        }
        let Some(path) = self.path.as_ref() else {
            return;
        };
        let Ok(encoded) = serde_json::to_vec(&self.gaps) else {
            return;
        };
        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let _ = fs::write(path, encoded);
    }
}

fn read_file(path: &Path) -> Vec<CaptureGapRecord> {
    fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::{CaptureGapLog, CaptureGapRecord, DEFAULT_GAP_LIMIT};
    use std::path::PathBuf;

    struct Sandbox {
        directory: PathBuf,
    }

    impl Sandbox {
        fn new(label: &str) -> Self {
            let directory = std::env::temp_dir().join(format!(
                "omi-gaps-{label}-{}-{}",
                std::process::id(),
                crate::capture_wal::random_id()
            ));
            let _ = std::fs::create_dir_all(&directory);
            Self { directory }
        }

        fn path(&self) -> PathBuf {
            self.directory.join("capture-gaps.json")
        }
    }

    impl Drop for Sandbox {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.directory);
        }
    }

    fn gap(device_id: &str, ended_at_ms: i64, stream: &str) -> CaptureGapRecord {
        CaptureGapRecord {
            device_id: device_id.to_owned(),
            reason: "packetDiscontinuity".to_owned(),
            ended_at_ms,
            ended_stream_id: stream.to_owned(),
            resumed_at_ms: None,
            resumed_stream_id: None,
        }
    }

    #[test]
    fn a_resume_closes_the_most_recent_open_gap_for_that_device() {
        let mut log = CaptureGapLog::volatile(DEFAULT_GAP_LIMIT);
        log.record(gap("device-1", 100, "stream-1"));
        log.record(gap("device-2", 150, "stream-2"));
        log.record(gap("device-1", 200, "stream-3"));

        log.record_resume("device-1", 260, "stream-4");

        let gaps = log.read();
        assert_eq!(gaps[0].resumed_at_ms, None);
        assert_eq!(gaps[1].resumed_at_ms, None);
        assert_eq!(gaps[2].resumed_at_ms, Some(260));
        assert_eq!(gaps[2].resumed_stream_id.as_deref(), Some("stream-4"));
    }

    #[test]
    fn a_resume_with_no_open_gap_changes_nothing() {
        let mut log = CaptureGapLog::volatile(DEFAULT_GAP_LIMIT);
        log.record(gap("device-1", 100, "stream-1").resumed(120, "stream-2"));

        log.record_resume("device-1", 300, "stream-9");

        assert_eq!(log.read()[0].resumed_at_ms, Some(120));
    }

    #[test]
    fn an_already_resumed_gap_is_not_reopened_by_another_device() {
        let mut log = CaptureGapLog::volatile(DEFAULT_GAP_LIMIT);
        log.record(gap("device-1", 100, "stream-1"));

        log.record_resume("device-2", 200, "stream-2");

        assert_eq!(log.read()[0].resumed_at_ms, None);
    }

    #[test]
    fn the_log_survives_a_restart() {
        let sandbox = Sandbox::new("restart");
        let mut first = CaptureGapLog::open(sandbox.path(), DEFAULT_GAP_LIMIT);
        first.record(gap("device-1", 100, "stream-1"));
        first.record_resume("device-1", 180, "stream-2");
        drop(first);

        let second = CaptureGapLog::open(sandbox.path(), DEFAULT_GAP_LIMIT);
        let gaps = second.read();
        assert_eq!(gaps.len(), 1);
        assert_eq!(gaps[0].ended_stream_id, "stream-1");
        assert_eq!(gaps[0].resumed_stream_id.as_deref(), Some("stream-2"));
    }

    #[test]
    fn the_log_is_bounded_and_keeps_the_newest() {
        let sandbox = Sandbox::new("bounded");
        let mut log = CaptureGapLog::open(sandbox.path(), 3);
        for index in 0..10_i64 {
            log.record(gap("device-1", index, &format!("stream-{index}")));
        }

        let gaps = log.read();
        assert_eq!(gaps.len(), 3);
        assert_eq!(gaps[0].ended_at_ms, 7);
        assert_eq!(gaps[2].ended_at_ms, 9);
    }

    #[test]
    fn an_unreadable_file_reads_back_as_an_empty_log() {
        let sandbox = Sandbox::new("corrupt");
        let _ = std::fs::write(sandbox.path(), b"not json at all");

        let log = CaptureGapLog::open(sandbox.path(), DEFAULT_GAP_LIMIT);

        assert!(log.read().is_empty());
    }

    #[test]
    fn a_volatile_log_never_touches_the_disk() {
        let sandbox = Sandbox::new("volatile");
        let mut log = CaptureGapLog::volatile(DEFAULT_GAP_LIMIT);
        log.record(gap("device-1", 100, "stream-1"));

        assert_eq!(log.read().len(), 1);
        assert!(!sandbox.path().exists());
    }
}
