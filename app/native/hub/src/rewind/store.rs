//! The on-disk timeline: JPEG frames under `~/.omi/rewind/frames`, and a
//! newline-delimited index beside them. Retention is enforced on every write,
//! oldest first, against both bounds — age and total bytes — and enforcing it
//! deletes the file, it does not merely drop the index row. "Deleted" here
//! means the bytes are gone.
//!
//! The store never decodes anything. It is handed encoded bytes that the
//! policy has already decided to keep, writes them, and forgets them; the only
//! thing it ever reads back is the index.

use serde_json::Value;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

use super::models::{Frame, Retention};

const INDEX_NAME: &str = "index.jsonl";
const FRAMES_DIR_NAME: &str = "frames";

/// Everything about a frame except its bytes and its path, which the store
/// derives. Grouped into one value rather than a long argument list because
/// the four optional fields are exactly the ones the privacy settings suppress
/// — passing them positionally is how a title ends up in the wrong slot.
#[derive(Clone, Debug, Default)]
pub struct NewFrame {
    pub captured_at_ms: i64,
    pub hash: String,
    pub app_name: Option<String>,
    pub bundle_id: Option<String>,
    pub window_title: Option<String>,
    pub ocr_text: Option<String>,
}

pub struct Store {
    root: PathBuf,
    /// Frames oldest first.
    frames: Vec<Frame>,
    total_bytes: u64,
    loaded: bool,
}

impl Store {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            frames: Vec::new(),
            total_bytes: 0,
            loaded: false,
        }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn index_file(&self) -> PathBuf {
        self.root.join(INDEX_NAME)
    }

    pub fn frames_directory(&self) -> PathBuf {
        self.root.join(FRAMES_DIR_NAME)
    }

    /// Frames oldest first.
    pub fn frames(&self) -> &[Frame] {
        &self.frames
    }

    pub fn total_bytes(&self) -> u64 {
        self.total_bytes
    }

    pub fn file_for(&self, frame: &Frame) -> PathBuf {
        self.root.join(&frame.relative_path)
    }

    /// Reads the index once. A line that will not parse is skipped rather than
    /// aborting the load: one truncated write at the tail of the file must not
    /// cost the user every frame in front of it.
    pub fn load(&mut self) {
        if self.loaded {
            return;
        }
        self.loaded = true;
        let _ = fs::create_dir_all(&self.root);
        let Ok(file) = File::open(self.index_file()) else {
            return;
        };
        for line in BufReader::new(file).lines().map_while(Result::ok) {
            if line.trim().is_empty() {
                continue;
            }
            let Ok(decoded) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            let Some(frame) = Frame::from_json(&decoded) else {
                continue;
            };
            self.total_bytes = self.total_bytes.saturating_add(frame.bytes);
            self.frames.push(frame);
        }
        self.frames.sort_by_key(|frame| frame.captured_at_ms);
    }

    /// Writes one frame and returns it, after enforcing `retention`. The caller
    /// owns the encoded bytes; nothing is decoded here.
    pub fn write(
        &mut self,
        jpeg: &[u8],
        record: NewFrame,
        retention: Retention,
    ) -> std::io::Result<Frame> {
        self.load();
        let captured_at_ms = record.captured_at_ms;
        let relative = format!(
            "{FRAMES_DIR_NAME}/{}/{captured_at_ms}.jpg",
            day(captured_at_ms)
        );
        let path = self.root.join(&relative);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&path, jpeg)?;
        let frame = Frame {
            captured_at_ms,
            relative_path: relative,
            bytes: jpeg.len() as u64,
            hash: record.hash,
            app_name: record.app_name,
            bundle_id: record.bundle_id,
            window_title: record.window_title,
            ocr_text: record.ocr_text,
        };
        self.total_bytes = self.total_bytes.saturating_add(frame.bytes);
        self.frames.push(frame.clone());
        self.append_index(&frame)?;
        self.enforce(retention, captured_at_ms);
        Ok(frame)
    }

    /// Applies both retention bounds, deleting oldest first. Returns the number
    /// of frames removed.
    pub fn enforce(&mut self, retention: Retention, now_ms: i64) -> usize {
        self.load();
        let cutoff =
            now_ms.saturating_sub(i64::try_from(retention.max_age.as_millis()).unwrap_or(i64::MAX));
        let mut removed = 0;
        while !self.frames.is_empty() {
            let too_old = self
                .frames
                .first()
                .is_some_and(|frame| frame.captured_at_ms < cutoff);
            if !too_old && self.total_bytes <= retention.max_bytes {
                break;
            }
            let frame = self.frames.remove(0);
            self.total_bytes = self.total_bytes.saturating_sub(frame.bytes);
            self.delete_file(&frame);
            removed += 1;
        }
        if removed > 0 {
            let _ = self.rewrite_index();
            self.prune_empty_days();
        }
        removed
    }

    /// Searches the recognized text, app names and window titles. Newest first,
    /// and never more than `limit` results. Matching happens entirely here —
    /// nothing about the query or the timeline leaves the machine.
    pub fn search(&self, query: &str, limit: usize) -> Vec<Frame> {
        let needle = query.trim().to_lowercase();
        if needle.is_empty() {
            return Vec::new();
        }
        let mut results = Vec::new();
        for frame in self.frames.iter().rev() {
            let haystack = [
                frame.ocr_text.as_deref(),
                frame.app_name.as_deref(),
                frame.window_title.as_deref(),
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<&str>>()
            .join("\n")
            .to_lowercase();
            if haystack.contains(&needle) {
                results.push(frame.clone());
            }
            if results.len() >= limit {
                break;
            }
        }
        results
    }

    /// Deletes a single frame — the timeline's per-frame delete.
    pub fn delete(&mut self, relative_path: &str) -> bool {
        self.load();
        let Some(index) = self
            .frames
            .iter()
            .position(|frame| frame.relative_path == relative_path)
        else {
            return false;
        };
        let frame = self.frames.remove(index);
        self.total_bytes = self.total_bytes.saturating_sub(frame.bytes);
        self.delete_file(&frame);
        let _ = self.rewrite_index();
        self.prune_empty_days();
        true
    }

    /// Deletes every frame captured in the inclusive range — "forget the last
    /// hour".
    pub fn delete_range(&mut self, from_ms: i64, to_ms: i64) -> usize {
        self.load();
        let doomed: Vec<Frame> = self
            .frames
            .iter()
            .filter(|frame| frame.captured_at_ms >= from_ms && frame.captured_at_ms <= to_ms)
            .cloned()
            .collect();
        for frame in &doomed {
            if let Some(index) = self.frames.iter().position(|kept| kept == frame) {
                self.frames.remove(index);
            }
            self.total_bytes = self.total_bytes.saturating_sub(frame.bytes);
            self.delete_file(frame);
        }
        if !doomed.is_empty() {
            let _ = self.rewrite_index();
            self.prune_empty_days();
        }
        doomed.len()
    }

    /// Removes every frame and the index itself.
    pub fn delete_all(&mut self) {
        self.load();
        self.frames.clear();
        self.total_bytes = 0;
        let frames_directory = self.frames_directory();
        if frames_directory.exists() {
            let _ = fs::remove_dir_all(&frames_directory);
        }
        let index = self.index_file();
        if index.exists() {
            let _ = fs::remove_file(index);
        }
    }

    fn delete_file(&self, frame: &Frame) {
        // A frame that is already gone is the state we wanted anyway.
        let _ = fs::remove_file(self.file_for(frame));
    }

    fn append_index(&self, frame: &Frame) -> std::io::Result<()> {
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.index_file())?;
        writeln!(file, "{}", frame.to_json())?;
        file.flush()
    }

    fn rewrite_index(&self) -> std::io::Result<()> {
        let mut buffer = String::new();
        for frame in &self.frames {
            buffer.push_str(&frame.to_json().to_string());
            buffer.push('\n');
        }
        fs::write(self.index_file(), buffer)
    }

    fn prune_empty_days(&self) {
        let frames_directory = self.frames_directory();
        let Ok(entries) = fs::read_dir(&frames_directory) else {
            return;
        };
        for entry in entries.flatten() {
            if !entry.path().is_dir() {
                continue;
            }
            let empty = fs::read_dir(entry.path()).is_ok_and(|mut day| day.next().is_none());
            if empty {
                let _ = fs::remove_dir(entry.path());
            }
        }
    }
}

/// Frames are filed by local calendar day, which is how a person looks for
/// them; the row inside the index still carries the exact UTC instant.
fn day(captured_at_ms: i64) -> String {
    chrono::DateTime::from_timestamp_millis(captured_at_ms)
        .map(|at| {
            at.with_timezone(&chrono::Local)
                .format("%Y-%m-%d")
                .to_string()
        })
        .unwrap_or_else(|| "unknown".to_owned())
}

#[cfg(test)]
mod tests {
    use super::{NewFrame, Store};
    use crate::rewind::models::Retention;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::Duration;

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    struct Scratch(PathBuf);

    impl Scratch {
        fn new() -> Self {
            let id = COUNTER.fetch_add(1, Ordering::Relaxed);
            let root =
                std::env::temp_dir().join(format!("rewind_store_test_{}_{id}", std::process::id()));
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

    /// 2026-07-23T10:00 UTC, the instant the Dart suite counted from.
    const BASE: i64 = 1_784_800_800_000;

    fn open(scratch: &Scratch) -> Store {
        let mut store = Store::new(scratch.0.clone());
        store.load();
        store
    }

    fn bytes(length: usize) -> Vec<u8> {
        vec![0x42; length]
    }

    fn minutes(value: i64) -> i64 {
        value * 60 * 1000
    }

    fn hours(value: i64) -> i64 {
        minutes(value * 60)
    }

    fn days(value: i64) -> i64 {
        hours(value * 24)
    }

    fn record(captured_at_ms: i64, hash: &str) -> NewFrame {
        NewFrame {
            captured_at_ms,
            hash: hash.to_owned(),
            ..NewFrame::default()
        }
    }

    fn retention(max_age_days: u64, max_bytes: u64) -> Retention {
        Retention {
            max_age: Duration::from_secs(max_age_days * 24 * 60 * 60),
            max_bytes,
        }
    }

    #[test]
    fn writes_a_frame_and_reads_it_back_from_the_index() {
        let scratch = Scratch::new();
        let mut store = open(&scratch);
        assert!(
            store
                .write(
                    &bytes(64),
                    NewFrame {
                        captured_at_ms: BASE,
                        hash: "0123456789abcdef".to_owned(),
                        app_name: Some("Terminal".to_owned()),
                        bundle_id: Some("com.apple.Terminal".to_owned()),
                        window_title: Some("zsh".to_owned()),
                        ocr_text: Some("flutter analyze".to_owned()),
                    },
                    Retention::default(),
                )
                .is_ok()
        );
        let mut reopened = Store::new(scratch.0.clone());
        reopened.load();
        assert_eq!(reopened.frames().len(), 1);
        let Some(frame) = reopened.frames().first() else {
            panic!("the frame just written is in the index");
        };
        assert_eq!(frame.ocr_text.as_deref(), Some("flutter analyze"));
        assert_eq!(reopened.total_bytes(), 64);
        assert!(reopened.file_for(frame).exists());
    }

    #[test]
    fn evicts_oldest_first_once_the_byte_bound_is_exceeded() {
        let scratch = Scratch::new();
        let mut store = open(&scratch);
        let bound = retention(365, 200);
        let mut paths = Vec::new();
        for index in 0..4 {
            let Ok(frame) = store.write(
                &bytes(100),
                record(BASE + minutes(index), &index.to_string()),
                bound,
            ) else {
                panic!("writing a frame succeeds");
            };
            paths.push(store.file_for(&frame));
        }
        assert_eq!(store.frames().len(), 2);
        assert!(store.total_bytes() <= 200);
        // Eviction is real deletion, not an index edit.
        let (Some(first), Some(last)) = (paths.first(), paths.last()) else {
            panic!("four frames were written");
        };
        assert!(!first.exists());
        assert!(last.exists());
    }

    #[test]
    fn evicts_anything_older_than_the_age_bound() {
        let scratch = Scratch::new();
        let mut store = open(&scratch);
        assert!(
            store
                .write(
                    &bytes(10),
                    record(BASE - days(3), "old"),
                    retention(365, 1 << 30),
                )
                .is_ok()
        );
        assert!(
            store
                .write(&bytes(10), record(BASE, "new"), retention(1, 1 << 30))
                .is_ok()
        );
        assert_eq!(store.frames().len(), 1);
        assert_eq!(
            store.frames().first().map(|frame| frame.hash.as_str()),
            Some("new")
        );
    }

    #[test]
    fn delete_all_removes_every_file_and_the_index() {
        let scratch = Scratch::new();
        let mut store = open(&scratch);
        assert!(
            store
                .write(&bytes(10), record(BASE, "a"), Retention::default())
                .is_ok()
        );
        store.delete_all();
        assert!(store.frames().is_empty());
        assert_eq!(store.total_bytes(), 0);
        assert!(!store.frames_directory().exists());
        assert!(!store.index_file().exists());
    }

    #[test]
    fn delete_range_forgets_a_window_of_time() {
        let scratch = Scratch::new();
        let mut store = open(&scratch);
        for index in 0..3 {
            assert!(
                store
                    .write(
                        &bytes(10),
                        record(BASE + hours(index), &index.to_string()),
                        Retention::default(),
                    )
                    .is_ok()
            );
        }
        let removed = store.delete_range(BASE + minutes(30), BASE + hours(2) + minutes(30));
        assert_eq!(removed, 2);
        assert_eq!(store.frames().len(), 1);
        assert_eq!(
            store.frames().first().map(|frame| frame.hash.as_str()),
            Some("0")
        );
    }

    #[test]
    fn search_reads_the_on_device_text_newest_first() {
        let scratch = Scratch::new();
        let mut store = open(&scratch);
        assert!(
            store
                .write(
                    &bytes(10),
                    NewFrame {
                        ocr_text: Some("deploy the worker".to_owned()),
                        ..record(BASE, "a")
                    },
                    Retention::default(),
                )
                .is_ok()
        );
        assert!(
            store
                .write(
                    &bytes(10),
                    NewFrame {
                        ocr_text: Some("DEPLOY failed".to_owned()),
                        ..record(BASE + minutes(5), "b")
                    },
                    Retention::default(),
                )
                .is_ok()
        );
        let results = store.search("deploy", 200);
        assert_eq!(results.len(), 2);
        assert_eq!(results.first().map(|frame| frame.hash.as_str()), Some("b"));
        assert!(store.search("nothing here", 200).is_empty());
        assert!(store.search("   ", 200).is_empty());
    }

    #[test]
    fn a_corrupt_index_line_is_skipped_rather_than_losing_the_rest() {
        let scratch = Scratch::new();
        let mut store = open(&scratch);
        assert!(
            store
                .write(&bytes(10), record(BASE, "a"), Retention::default())
                .is_ok()
        );
        let index = store.index_file();
        let Ok(existing) = std::fs::read_to_string(&index) else {
            panic!("the index exists after a write");
        };
        assert!(std::fs::write(&index, format!("{existing}not json\n")).is_ok());
        let mut reopened = Store::new(scratch.0.clone());
        reopened.load();
        assert_eq!(reopened.frames().len(), 1);
    }

    #[test]
    fn deleting_one_frame_removes_its_bytes_and_its_row() {
        let scratch = Scratch::new();
        let mut store = open(&scratch);
        let Ok(frame) = store.write(&bytes(10), record(BASE, "a"), Retention::default()) else {
            panic!("writing a frame succeeds");
        };
        let path = store.file_for(&frame);
        assert!(store.delete(&frame.relative_path));
        assert!(!path.exists());
        assert_eq!(store.total_bytes(), 0);
        assert!(!store.delete(&frame.relative_path));

        let mut reopened = Store::new(scratch.0.clone());
        reopened.load();
        assert!(reopened.frames().is_empty());
    }

    #[test]
    fn an_emptied_day_directory_is_pruned() {
        let scratch = Scratch::new();
        let mut store = open(&scratch);
        let Ok(frame) = store.write(&bytes(10), record(BASE, "a"), Retention::default()) else {
            panic!("writing a frame succeeds");
        };
        let Some(day) = store.file_for(&frame).parent().map(PathBuf::from) else {
            panic!("every frame lives in a day directory");
        };
        assert!(day.exists());
        assert!(store.delete(&frame.relative_path));
        assert!(!day.exists());
    }

    #[test]
    fn search_never_returns_more_than_the_limit() {
        let scratch = Scratch::new();
        let mut store = open(&scratch);
        for index in 0..5 {
            assert!(
                store
                    .write(
                        &bytes(10),
                        NewFrame {
                            ocr_text: Some("deploy".to_owned()),
                            ..record(BASE + minutes(index), &index.to_string())
                        },
                        Retention::default(),
                    )
                    .is_ok()
            );
        }
        assert_eq!(store.search("deploy", 2).len(), 2);
    }
}
