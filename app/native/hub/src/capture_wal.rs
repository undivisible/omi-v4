//! Bounded on-disk write-ahead log for pendant audio.
//!
//! Every frame handed to the hub is also appended here, so audio that was in
//! flight when a packet dropped, the socket died, or the process was killed is
//! still on disk and can be uploaded later.
//!
//! ## Storage layout
//!
//! One file per segment under the log directory. The name carries the ordering
//! and the idempotency key: `<20-digit sequence>-<id>.seg` once sealed,
//! `.open` while still being appended to. Each file is a single JSON header
//! line, a newline, then the raw audio bytes in the pendant's own encoding.
//!
//! ## Eviction policy
//!
//! Sealed segments are evicted **oldest first** whenever either bound is
//! exceeded, and the bounds are re-applied on open, on every seal, and on
//! every append that crosses a segment boundary:
//!
//!  * **Age** — any sealed segment whose start time is older than `max_age_ms`
//!    is deleted, whether or not the log is over its size bound. This is what
//!    stops a phone that has been offline for days from holding audio that is
//!    no longer worth transcribing.
//!  * **Size** — while the sealed total exceeds `max_bytes`, the oldest sealed
//!    segment is deleted.
//!
//! The segment currently being appended to is never evicted, but it is capped
//! at `max_segment_bytes` and auto-sealed on reaching it, so total on-disk
//! usage is bounded by `max_bytes + max_segment_bytes` and never grows without
//! limit. Eviction is silent data loss by design: the alternative — refusing
//! to record — loses the *newest* audio, which is the audio the user is most
//! likely to care about.
//!
//! ## Durability
//!
//! The log lives in the hub rather than in the Dart isolate precisely so that
//! writes reach the operating system on a thread that is never stalled by a
//! garbage collection, and so that the handle outlives the isolate. Every
//! append is a single unbuffered `write` (nothing sits in a user-space buffer
//! waiting for a flush that a killed process will never make), and a segment
//! is `fsync`ed before it is renamed into its sealed name, so a segment that
//! is visible as `.seg` is a segment whose bytes are on the medium.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

/// Reads the current wall clock in milliseconds since the Unix epoch. Injected
/// so eviction can be driven from a test clock rather than from real time.
pub type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;

pub const DEFAULT_MAX_BYTES: u64 = 64 * 1024 * 1024;
pub const DEFAULT_MAX_AGE_MS: i64 = 48 * 60 * 60 * 1000;
pub const DEFAULT_MAX_SEGMENT_BYTES: u64 = 1024 * 1024;

/// Width of the zero-padded sequence prefix in a segment file name. Twenty
/// digits is exactly the widest [`u64`], so the lexical order of the names is
/// the numeric order of the sequences for every sequence the log can reach.
const SEQUENCE_DIGITS: usize = 20;

const OPEN_SUFFIX: &str = ".open";
const SEALED_SUFFIX: &str = ".seg";

/// How the audio bytes of a segment are delimited.
///
/// Opus packets are variable length and carry no length of their own, so a run
/// of them concatenated on disk cannot be split back into packets and cannot be
/// containerised for upload. Segments in such an encoding therefore store each
/// packet behind a big-endian uint16 length. Everything else is a fixed-width
/// or otherwise self-describing stream and is stored verbatim.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CaptureWalFraming {
    Raw,
    Len16,
}

impl CaptureWalFraming {
    pub fn for_encoding(encoding: &str) -> Self {
        if encoding == "opus" {
            Self::Len16
        } else {
            Self::Raw
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Raw => "raw",
            Self::Len16 => "len16",
        }
    }

    /// Older segments predate the field, and anything the log does not
    /// recognise is read back as [`CaptureWalFraming::Raw`] — the framing that
    /// stores bytes verbatim, and therefore the only one that cannot
    /// mis-describe what is already on disk.
    pub fn parse(value: &str) -> Self {
        if value == Self::Len16.as_str() {
            Self::Len16
        } else {
            Self::Raw
        }
    }
}

/// A sealed unit of captured audio waiting to be uploaded.
///
/// The `id` is generated once, before the first byte is written, and lives in
/// the file name. It is therefore stable across process death and is the
/// client-supplied idempotency key the transcription endpoint deduplicates on:
/// a retry after a dropped response re-sends the same id and cannot produce a
/// second transcription or a second charge.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CaptureWalSegment {
    /// Client-supplied idempotency key for the upload.
    pub id: String,
    /// Monotonic ring position. Ordering key for both upload and eviction.
    pub sequence: u64,
    pub device_id: String,
    /// The STT session this audio belonged to. A gap-recording restart mints a
    /// new one, so segments either side of a gap are never presented as a
    /// single continuous stream.
    pub audio_stream_id: String,
    pub encoding: String,
    pub framing: CaptureWalFraming,
    pub sample_rate_hz: u32,
    pub channels: u8,
    pub started_at_ms: i64,
    /// True when a recorded discontinuity immediately precedes this segment.
    pub gap_before: bool,
    pub audio_bytes: u64,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct CaptureWalStats {
    pub segments: u64,
    pub bytes: u64,
    pub oldest_started_at_ms: Option<i64>,
}

/// The header line at the top of every segment file.
///
/// The field order is the order the Dart log wrote them in, so a segment
/// written by either implementation reads back byte-identically under the
/// other. Only the fields the reader validates are required; `framing` and
/// `gapBefore` are tolerated as missing because segments written before those
/// fields existed are still worth uploading.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct SegmentHeader {
    id: String,
    sequence: u64,
    device_id: String,
    audio_stream_id: String,
    encoding: String,
    #[serde(default)]
    framing: Option<String>,
    sample_rate_hz: u32,
    channels: u8,
    started_at_ms: i64,
    #[serde(default)]
    gap_before: bool,
}

struct OpenSegment {
    id: String,
    sequence: u64,
    file: File,
    framing: CaptureWalFraming,
    audio_bytes: u64,
}

pub struct CaptureWal {
    directory: PathBuf,
    max_bytes: u64,
    max_age_ms: i64,
    max_segment_bytes: u64,
    now_ms: Clock,
    next_sequence: u64,
    open: Option<OpenSegment>,
}

/// Bounds a caller asked for. Every field is optional so the Dart side can ask
/// for the defaults without restating them, which keeps the two ends from
/// drifting apart when a default changes.
#[derive(Clone, Copy, Debug)]
pub struct CaptureWalBounds {
    pub max_bytes: u64,
    pub max_age_ms: i64,
    pub max_segment_bytes: u64,
}

impl Default for CaptureWalBounds {
    fn default() -> Self {
        Self {
            max_bytes: DEFAULT_MAX_BYTES,
            max_age_ms: DEFAULT_MAX_AGE_MS,
            max_segment_bytes: DEFAULT_MAX_SEGMENT_BYTES,
        }
    }
}

impl CaptureWal {
    /// Opens (creating if needed) the log at `directory`.
    ///
    /// Any segment left `.open` by a previous process is sealed rather than
    /// discarded — the whole point of the log is that a killed process does not
    /// lose the audio it had already written — and the bounds are applied
    /// before the first new byte is accepted.
    pub fn open(
        directory: impl Into<PathBuf>,
        bounds: CaptureWalBounds,
        now_ms: Clock,
    ) -> io::Result<Self> {
        let directory = directory.into();
        if bounds.max_bytes == 0 || bounds.max_segment_bytes == 0 || bounds.max_age_ms <= 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "CaptureWal bounds must be positive.",
            ));
        }
        fs::create_dir_all(&directory)?;
        let mut next_sequence = 0_u64;
        for entry in fs::read_dir(&directory)? {
            let Ok(entry) = entry else { continue };
            if !entry.file_type().is_ok_and(|kind| kind.is_file()) {
                continue;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(sequence) = sequence_of(&name) else {
                continue;
            };
            if sequence >= next_sequence {
                next_sequence = sequence.saturating_add(1);
            }
            if let Some(stem) = name.strip_suffix(OPEN_SUFFIX) {
                let sealed = directory.join(format!("{stem}{SEALED_SUFFIX}"));
                let _ = fs::rename(entry.path(), sealed);
            }
        }
        let mut wal = Self {
            directory,
            max_bytes: bounds.max_bytes,
            max_age_ms: bounds.max_age_ms,
            max_segment_bytes: bounds.max_segment_bytes,
            now_ms,
            next_sequence,
            open: None,
        };
        wal.evict();
        Ok(wal)
    }

    /// Seals whatever is open and starts a new segment, returning the id that
    /// will be the upload's idempotency key.
    pub fn begin_segment(
        &mut self,
        device_id: &str,
        audio_stream_id: &str,
        encoding: &str,
        sample_rate_hz: u32,
        channels: u8,
        gap_before: bool,
    ) -> io::Result<String> {
        let id = random_id();
        self.begin_segment_with_id(
            id,
            device_id,
            audio_stream_id,
            encoding,
            sample_rate_hz,
            channels,
            (self.now_ms)(),
            gap_before,
        )
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "the segment header is the immutable capture identity"
    )]
    fn begin_segment_with_id(
        &mut self,
        id: String,
        device_id: &str,
        audio_stream_id: &str,
        encoding: &str,
        sample_rate_hz: u32,
        channels: u8,
        started_at_ms: i64,
        gap_before: bool,
    ) -> io::Result<String> {
        let framing = CaptureWalFraming::for_encoding(encoding);
        self.seal_open()?;
        let sequence = self.next_sequence;
        self.next_sequence = self.next_sequence.saturating_add(1);
        let header = SegmentHeader {
            id: id.clone(),
            sequence,
            device_id: device_id.to_owned(),
            audio_stream_id: audio_stream_id.to_owned(),
            encoding: encoding.to_owned(),
            framing: Some(framing.as_str().to_owned()),
            sample_rate_hz,
            channels,
            started_at_ms,
            gap_before,
        };
        let line = serde_json::to_string(&header)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        let path = self.path(sequence, &id, false);
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&path)?;
        // Durability is the whole point: a header still sitting in a user-space
        // buffer when the process dies leaves an unreadable segment behind.
        file.write_all(line.as_bytes())?;
        file.write_all(b"\n")?;
        file.flush()?;
        self.open = Some(OpenSegment {
            id: id.clone(),
            sequence,
            file,
            framing,
            audio_bytes: 0,
        });
        Ok(id)
    }

    pub fn import_opus_range(
        &mut self,
        source_id: &str,
        device_id: &str,
        started_at_ms: i64,
        frames: &[Vec<u8>],
    ) -> io::Result<bool> {
        let mut digest = Sha256::new();
        digest.update(device_id.as_bytes());
        digest.update([0]);
        digest.update(source_id.as_bytes());
        let id = format!("{:x}", digest.finalize());
        let mut audio = Vec::new();
        for frame in frames {
            let length = u16::try_from(frame.len()).map_err(|_| {
                io::Error::new(io::ErrorKind::InvalidInput, "Opus frame is too large.")
            })?;
            audio.extend_from_slice(&length.to_be_bytes());
            audio.extend_from_slice(frame);
        }
        if let Some(existing) = self.pending().into_iter().find(|segment| segment.id == id) {
            let matches = existing.device_id == device_id
                && existing.audio_stream_id == source_id
                && existing.encoding == "opus"
                && self
                    .read_audio(&existing)
                    .is_some_and(|bytes| bytes == audio);
            return if matches {
                Ok(false)
            } else {
                Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "Immutable ring range conflicts with its durable copy.",
                ))
            };
        }
        self.begin_segment_with_id(
            id,
            device_id,
            source_id,
            "opus",
            16_000,
            1,
            started_at_ms,
            false,
        )?;
        for frame in frames {
            self.append(frame)?;
        }
        self.seal()?;
        Ok(true)
    }

    /// Appends captured audio to the open segment. A no-op when no segment is
    /// open, so a caller that failed to start one never fails mid-capture.
    pub fn append(&mut self, bytes: &[u8]) -> io::Result<()> {
        let Some(open) = self.open.as_mut() else {
            return Ok(());
        };
        if bytes.is_empty() {
            return Ok(());
        }
        if open.framing == CaptureWalFraming::Len16 {
            // A packet that cannot be described by the length prefix cannot be
            // recovered from the segment either, so it is refused rather than
            // written unframed and corrupting every packet after it.
            let Ok(length) = u16::try_from(bytes.len()) else {
                return Ok(());
            };
            open.file.write_all(&length.to_be_bytes())?;
            open.audio_bytes = open.audio_bytes.saturating_add(2);
        }
        open.file.write_all(bytes)?;
        // Flush every append. A killed process must lose at most the frame that
        // was in flight, not everything written since the segment opened.
        open.file.flush()?;
        open.audio_bytes = open.audio_bytes.saturating_add(bytes.len() as u64);
        if open.audio_bytes >= self.max_segment_bytes {
            self.seal_open()?;
            self.evict();
        }
        Ok(())
    }

    /// Seals the open segment so it becomes uploadable, then re-applies bounds.
    pub fn seal(&mut self) -> io::Result<()> {
        self.seal_open()?;
        self.evict();
        Ok(())
    }

    /// Sealed segments, oldest first. The open segment is deliberately
    /// excluded: uploading a segment that is still growing would give the
    /// endpoint a partial body under an id that later means something longer.
    pub fn pending(&self) -> Vec<CaptureWalSegment> {
        self.sealed_segments()
    }

    /// The audio payload of `segment`, or `None` when it has since been
    /// evicted.
    pub fn read_audio(&self, segment: &CaptureWalSegment) -> Option<Vec<u8>> {
        let path = self.path(segment.sequence, &segment.id, true);
        let bytes = fs::read(path).ok()?;
        let split = bytes.iter().position(|byte| *byte == b'\n')?;
        Some(bytes[split + 1..].to_vec())
    }

    /// Drops `segment` after a confirmed upload. Idempotent.
    pub fn remove(&self, segment: &CaptureWalSegment) {
        let _ = fs::remove_file(self.path(segment.sequence, &segment.id, true));
    }

    pub fn stats(&self) -> CaptureWalStats {
        let segments = self.sealed_segments();
        CaptureWalStats {
            segments: segments.len() as u64,
            bytes: segments
                .iter()
                .fold(0_u64, |total, segment| total + segment.audio_bytes),
            oldest_started_at_ms: segments.first().map(|segment| segment.started_at_ms),
        }
    }

    /// Applies the age and size bounds. Returns the number of segments deleted.
    pub fn evict(&mut self) -> u64 {
        let mut removed = 0_u64;
        let cutoff = (self.now_ms)().saturating_sub(self.max_age_ms);
        let mut survivors = Vec::new();
        for segment in self.sealed_segments() {
            if segment.started_at_ms < cutoff {
                self.remove(&segment);
                removed += 1;
            } else {
                survivors.push(segment);
            }
        }
        let mut total = survivors
            .iter()
            .fold(0_u64, |sum, segment| sum + segment.audio_bytes);
        let mut index = 0;
        while total > self.max_bytes && index < survivors.len() {
            let segment = &survivors[index];
            index += 1;
            self.remove(segment);
            total = total.saturating_sub(segment.audio_bytes);
            removed += 1;
        }
        removed
    }

    /// Seals the open segment and releases the file handle.
    pub fn close(&mut self) -> io::Result<()> {
        self.seal_open()
    }

    fn seal_open(&mut self) -> io::Result<()> {
        let Some(open) = self.open.take() else {
            return Ok(());
        };
        open.file.sync_data()?;
        drop(open.file);
        fs::rename(
            self.path(open.sequence, &open.id, false),
            self.path(open.sequence, &open.id, true),
        )
    }

    fn sealed_segments(&self) -> Vec<CaptureWalSegment> {
        let mut segments = Vec::new();
        let Ok(entries) = fs::read_dir(&self.directory) else {
            return segments;
        };
        for entry in entries {
            let Ok(entry) = entry else { continue };
            if !entry.file_type().is_ok_and(|kind| kind.is_file()) {
                continue;
            }
            if !entry.file_name().to_string_lossy().ends_with(SEALED_SUFFIX) {
                continue;
            }
            if let Some(segment) = read_segment(&entry.path()) {
                segments.push(segment);
            }
        }
        segments.sort_by_key(|segment| segment.sequence);
        segments
    }

    fn path(&self, sequence: u64, id: &str, sealed: bool) -> PathBuf {
        let suffix = if sealed { SEALED_SUFFIX } else { OPEN_SUFFIX };
        let width = SEQUENCE_DIGITS;
        self.directory
            .join(format!("{sequence:0width$}-{id}{suffix}"))
    }
}

/// Reads one sealed segment's header, or `None` when the file is unreadable,
/// truncated before its newline, or carrying a header that does not describe a
/// segment. An unreadable segment is skipped rather than raised: one corrupt
/// file must not stop every intact segment behind it from being uploaded.
fn read_segment(path: &Path) -> Option<CaptureWalSegment> {
    let bytes = fs::read(path).ok()?;
    let split = bytes.iter().position(|byte| *byte == b'\n')?;
    if split == 0 {
        return None;
    }
    let header: SegmentHeader = serde_json::from_slice(&bytes[..split]).ok()?;
    Some(CaptureWalSegment {
        id: header.id,
        sequence: header.sequence,
        device_id: header.device_id,
        audio_stream_id: header.audio_stream_id,
        encoding: header.encoding,
        framing: header
            .framing
            .as_deref()
            .map_or(CaptureWalFraming::Raw, CaptureWalFraming::parse),
        sample_rate_hz: header.sample_rate_hz,
        channels: header.channels,
        started_at_ms: header.started_at_ms,
        gap_before: header.gap_before,
        audio_bytes: (bytes.len() - split - 1) as u64,
    })
}

fn sequence_of(name: &str) -> Option<u64> {
    if name.len() < SEQUENCE_DIGITS + 1 {
        return None;
    }
    name.get(..SEQUENCE_DIGITS)?.parse().ok()
}

/// Sixteen cryptographically random bytes, lowercase hex — the same shape the
/// Dart log minted, and inside the `[A-Za-z0-9._:-]{8,120}` the transcription
/// endpoint accepts as a client message id.
///
/// A platform that cannot produce randomness falls back to the process id, the
/// clock and a monotonic counter. That is not collision-proof across devices,
/// but it is collision-proof within a process, which is what stops one device
/// from silently overwriting its own queued segment.
pub fn random_id() -> String {
    let mut bytes = [0_u8; 16];
    if getrandom::fill(&mut bytes).is_err() {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        bytes[..4].copy_from_slice(&std::process::id().to_be_bytes());
        bytes[4..12].copy_from_slice(&crate::approval::unix_time_ms().to_be_bytes());
        bytes[12..].copy_from_slice(&(counter as u32).to_be_bytes());
    }
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::{
        CaptureWal, CaptureWalBounds, CaptureWalFraming, CaptureWalSegment, Clock, random_id,
    };
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicI64, Ordering};

    struct Sandbox {
        directory: PathBuf,
    }

    impl Sandbox {
        fn new(label: &str) -> Self {
            let directory = std::env::temp_dir().join(format!(
                "omi-wal-{label}-{}-{}",
                std::process::id(),
                super::random_id()
            ));
            let _ = std::fs::create_dir_all(&directory);
            Self { directory }
        }
    }

    impl Drop for Sandbox {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.directory);
        }
    }

    fn fixed_clock(value: i64) -> (Arc<AtomicI64>, Clock) {
        let cell = Arc::new(AtomicI64::new(value));
        let handle = Arc::clone(&cell);
        (cell, Arc::new(move || handle.load(Ordering::Relaxed)))
    }

    fn open(sandbox: &Sandbox, bounds: CaptureWalBounds, clock: Clock) -> CaptureWal {
        CaptureWal::open(sandbox.directory.clone(), bounds, clock)
            .unwrap_or_else(|error| panic!("wal opens: {error}"))
    }

    fn bounds(max_bytes: u64, max_age_ms: i64, max_segment_bytes: u64) -> CaptureWalBounds {
        CaptureWalBounds {
            max_bytes,
            max_age_ms,
            max_segment_bytes,
        }
    }

    fn write(wal: &mut CaptureWal, bytes: &[u8], stream_id: &str) {
        wal.begin_segment("device-1", stream_id, "pcmU8", 8_000, 1, false)
            .unwrap_or_else(|error| panic!("segment begins: {error}"));
        wal.append(bytes)
            .unwrap_or_else(|error| panic!("append succeeds: {error}"));
        wal.seal()
            .unwrap_or_else(|error| panic!("seal succeeds: {error}"));
    }

    fn filled(length: usize, fill: u8) -> Vec<u8> {
        vec![fill; length]
    }

    fn audio(wal: &CaptureWal, segment: &CaptureWalSegment) -> Vec<u8> {
        wal.read_audio(segment)
            .unwrap_or_else(|| panic!("segment audio is readable"))
    }

    #[test]
    fn keeps_the_newest_segments_and_evicts_the_oldest_over_max_bytes() {
        let sandbox = Sandbox::new("evict-bytes");
        let (_clock, now) = fixed_clock(1_000);
        let mut wal = open(&sandbox, bounds(900, 3_600_000, 4096), now);
        for index in 0..5_u8 {
            write(&mut wal, &filled(300, index), "stream-1");
        }

        let pending = wal.pending();
        // 5 * 300 = 1500 bytes written; the 900-byte bound leaves the newest 3.
        assert_eq!(pending.len(), 3);
        assert!(pending.iter().all(|segment| segment.audio_bytes == 300));
        assert_eq!(
            audio(&wal, &pending[0]).first(),
            Some(&2),
            "segments 0 and 1 evicted oldest first"
        );
        assert!(wal.stats().bytes <= 900);
    }

    #[test]
    fn evicts_by_age_even_when_well_under_the_size_bound() {
        let sandbox = Sandbox::new("evict-age");
        let (clock, now) = fixed_clock(1_767_268_800_000);
        let mut wal = open(&sandbox, bounds(1 << 20, 2 * 3_600_000, 1024), now);
        write(&mut wal, &filled(64, 7), "stream-1");
        let later = clock.load(Ordering::Relaxed) + 3 * 3_600_000;
        clock.store(later, Ordering::Relaxed);
        write(&mut wal, &filled(64, 7), "stream-2");

        let pending = wal.pending();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].started_at_ms, later);
    }

    #[test]
    fn never_grows_without_limit_while_offline_for_days() {
        let sandbox = Sandbox::new("offline");
        let (clock, now) = fixed_clock(1_767_225_600_000);
        let mut wal = open(&sandbox, bounds(2048, 2 * 86_400_000, 512), now);
        // Three days of capture with nothing ever uploaded.
        for minute in 0..(72 * 6) {
            clock.fetch_add(10 * 60 * 1000, Ordering::Relaxed);
            wal.begin_segment(
                "device-1",
                &format!("stream-{minute}"),
                "pcmU8",
                8_000,
                1,
                false,
            )
            .unwrap_or_else(|error| panic!("segment begins: {error}"));
            wal.append(&filled(600, 7))
                .unwrap_or_else(|error| panic!("append succeeds: {error}"));
        }
        wal.seal()
            .unwrap_or_else(|error| panic!("seal succeeds: {error}"));

        assert!(wal.stats().bytes <= 2048 + 600);
        let on_disk = std::fs::read_dir(&sandbox.directory)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|entry| entry.metadata().ok())
            .filter(|metadata| metadata.is_file())
            .fold(0_u64, |total, metadata| total + metadata.len());
        assert!(on_disk < 8192, "{on_disk} bytes left on disk");
    }

    #[test]
    fn auto_seals_the_open_segment_at_max_segment_bytes() {
        let sandbox = Sandbox::new("auto-seal");
        let (_clock, now) = fixed_clock(1_000);
        let mut wal = open(&sandbox, bounds(4096, 3_600_000, 100), now);
        wal.begin_segment("device-1", "stream-1", "pcmU8", 8_000, 1, false)
            .unwrap_or_else(|error| panic!("segment begins: {error}"));
        wal.append(&filled(150, 7))
            .unwrap_or_else(|error| panic!("append succeeds: {error}"));

        assert_eq!(wal.pending().len(), 1);
    }

    #[test]
    fn seals_an_unclosed_segment_on_reopen_and_keeps_its_audio() {
        let sandbox = Sandbox::new("reopen-seal");
        let (_clock, now) = fixed_clock(1_000);
        let mut first = open(&sandbox, CaptureWalBounds::default(), Arc::clone(&now));
        first
            .begin_segment("device-1", "stream-1", "pcmU8", 8_000, 1, true)
            .unwrap_or_else(|error| panic!("segment begins: {error}"));
        first
            .append(&filled(48, 3))
            .unwrap_or_else(|error| panic!("append succeeds: {error}"));
        // No seal, no close: the process died here.
        drop(first);

        let second = open(&sandbox, CaptureWalBounds::default(), now);
        let pending = second.pending();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].audio_bytes, 48);
        assert!(pending[0].gap_before);
        assert_eq!(pending[0].audio_stream_id, "stream-1");
        assert_eq!(audio(&second, &pending[0]).first(), Some(&3));
    }

    #[test]
    fn keeps_segment_ids_stable_across_a_reopen() {
        let sandbox = Sandbox::new("stable-ids");
        let (_clock, now) = fixed_clock(1_000);
        let mut first = open(&sandbox, CaptureWalBounds::default(), Arc::clone(&now));
        write(&mut first, &filled(32, 7), "stream-1");
        let before = first.pending()[0].id.clone();
        first
            .close()
            .unwrap_or_else(|error| panic!("close succeeds: {error}"));

        let second = open(&sandbox, CaptureWalBounds::default(), now);
        assert_eq!(second.pending()[0].id, before);
    }

    #[test]
    fn does_not_reuse_a_sequence_number_after_a_restart() {
        let sandbox = Sandbox::new("sequences");
        let (_clock, now) = fixed_clock(1_000);
        let mut first = open(&sandbox, CaptureWalBounds::default(), Arc::clone(&now));
        write(&mut first, &filled(32, 7), "stream-1");
        first
            .close()
            .unwrap_or_else(|error| panic!("close succeeds: {error}"));

        let mut second = open(&sandbox, CaptureWalBounds::default(), now);
        write(&mut second, &filled(32, 7), "stream-2");
        let sequences: Vec<u64> = second
            .pending()
            .iter()
            .map(|segment| segment.sequence)
            .collect();
        assert_eq!(sequences, vec![0, 1]);
    }

    #[test]
    fn opus_segments_store_every_packet_behind_a_length() {
        let sandbox = Sandbox::new("len16");
        let (_clock, now) = fixed_clock(1_000);
        let mut wal = open(&sandbox, CaptureWalBounds::default(), now);
        wal.begin_segment("device-1", "stream-1", "opus", 16_000, 1, false)
            .unwrap_or_else(|error| panic!("segment begins: {error}"));
        wal.append(&[1, 2, 3])
            .unwrap_or_else(|error| panic!("append succeeds: {error}"));
        wal.append(&[4, 5])
            .unwrap_or_else(|error| panic!("append succeeds: {error}"));
        wal.seal()
            .unwrap_or_else(|error| panic!("seal succeeds: {error}"));

        let pending = wal.pending();
        assert_eq!(pending[0].framing, CaptureWalFraming::Len16);
        assert_eq!(audio(&wal, &pending[0]), vec![0, 3, 1, 2, 3, 0, 2, 4, 5]);
        assert_eq!(pending[0].audio_bytes, 9);
    }

    #[test]
    fn ring_range_import_is_immutable_and_idempotent() {
        let sandbox = Sandbox::new("ring-import");
        let (_clock, now) = fixed_clock(1_000);
        let mut wal = open(&sandbox, CaptureWalBounds::default(), now);
        let frames = vec![vec![1, 2, 3], vec![4, 5]];

        assert!(
            wal.import_opus_range("ring_10_12", "device-1", 1_000, &frames)
                .unwrap_or_else(|error| panic!("range imports: {error}"))
        );
        assert!(
            !wal.import_opus_range("ring_10_12", "device-1", 2_000, &frames)
                .unwrap_or_else(|error| panic!("range retry succeeds: {error}"))
        );
        assert_eq!(wal.pending().len(), 1);
    }

    #[test]
    fn ring_range_import_rejects_an_identity_collision() {
        let sandbox = Sandbox::new("ring-collision");
        let (_clock, now) = fixed_clock(1_000);
        let mut wal = open(&sandbox, CaptureWalBounds::default(), now);
        wal.import_opus_range("ring_10_12", "device-1", 1_000, &[vec![1]])
            .unwrap_or_else(|error| panic!("range imports: {error}"));

        assert!(
            wal.import_opus_range("ring_10_12", "device-1", 1_000, &[vec![2]])
                .is_err()
        );
    }

    #[test]
    fn a_packet_too_long_to_frame_is_refused_rather_than_written_unframed() {
        let sandbox = Sandbox::new("len16-refuse");
        let (_clock, now) = fixed_clock(1_000);
        let mut wal = open(&sandbox, bounds(1 << 20, 3_600_000, 1 << 20), now);
        wal.begin_segment("device-1", "stream-1", "opus", 16_000, 1, false)
            .unwrap_or_else(|error| panic!("segment begins: {error}"));
        wal.append(&filled(0x1_0000, 9))
            .unwrap_or_else(|error| panic!("append succeeds: {error}"));
        wal.append(&[7])
            .unwrap_or_else(|error| panic!("append succeeds: {error}"));
        wal.seal()
            .unwrap_or_else(|error| panic!("seal succeeds: {error}"));

        let pending = wal.pending();
        assert_eq!(audio(&wal, &pending[0]), vec![0, 1, 7]);
    }

    #[test]
    fn raw_framing_stores_bytes_verbatim() {
        let sandbox = Sandbox::new("raw");
        let (_clock, now) = fixed_clock(1_000);
        let mut wal = open(&sandbox, CaptureWalBounds::default(), now);
        write(&mut wal, &[1, 2, 3], "stream-1");

        let pending = wal.pending();
        assert_eq!(pending[0].framing, CaptureWalFraming::Raw);
        assert_eq!(audio(&wal, &pending[0]), vec![1, 2, 3]);
    }

    #[test]
    fn appending_without_an_open_segment_is_a_no_op() {
        let sandbox = Sandbox::new("no-open");
        let (_clock, now) = fixed_clock(1_000);
        let mut wal = open(&sandbox, CaptureWalBounds::default(), now);

        assert!(wal.append(&[1, 2, 3]).is_ok());
        assert!(wal.pending().is_empty());
    }

    #[test]
    fn removing_a_segment_twice_is_idempotent() {
        let sandbox = Sandbox::new("remove");
        let (_clock, now) = fixed_clock(1_000);
        let mut wal = open(&sandbox, CaptureWalBounds::default(), now);
        write(&mut wal, &filled(16, 1), "stream-1");
        let segment = wal.pending()[0].clone();

        wal.remove(&segment);
        wal.remove(&segment);
        assert!(wal.pending().is_empty());
        assert!(wal.read_audio(&segment).is_none());
    }

    #[test]
    fn non_positive_bounds_are_refused() {
        let sandbox = Sandbox::new("bounds");
        let (_clock, now) = fixed_clock(1_000);
        assert!(
            CaptureWal::open(sandbox.directory.clone(), bounds(0, 1, 1), Arc::clone(&now)).is_err()
        );
        assert!(
            CaptureWal::open(sandbox.directory.clone(), bounds(1, 0, 1), Arc::clone(&now)).is_err()
        );
        assert!(CaptureWal::open(sandbox.directory.clone(), bounds(1, 1, 0), now).is_err());
    }

    #[test]
    fn stats_report_the_oldest_sealed_segment() {
        let sandbox = Sandbox::new("stats");
        let (clock, now) = fixed_clock(1_000);
        let mut wal = open(&sandbox, CaptureWalBounds::default(), now);
        write(&mut wal, &filled(10, 1), "stream-1");
        clock.fetch_add(5_000, Ordering::Relaxed);
        write(&mut wal, &filled(20, 2), "stream-2");

        let stats = wal.stats();
        assert_eq!(stats.segments, 2);
        assert_eq!(stats.bytes, 30);
        assert_eq!(stats.oldest_started_at_ms, Some(1_000));
    }

    #[test]
    fn a_corrupt_segment_is_skipped_rather_than_failing_the_listing() {
        let sandbox = Sandbox::new("corrupt");
        let (_clock, now) = fixed_clock(1_000);
        let mut wal = open(&sandbox, CaptureWalBounds::default(), now);
        write(&mut wal, &filled(8, 1), "stream-1");
        let _ = std::fs::write(
            sandbox.directory.join(format!("{:020}-broken.seg", 99_u64)),
            b"not json\nbody",
        );

        assert_eq!(wal.pending().len(), 1);
    }

    #[test]
    fn ids_are_unique_and_endpoint_shaped() {
        let first = random_id();
        let second = random_id();
        assert_ne!(first, second);
        assert_eq!(first.len(), 32);
        assert!(first.chars().all(|value| value.is_ascii_hexdigit()));
    }
}
