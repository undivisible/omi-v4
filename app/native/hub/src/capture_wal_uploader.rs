//! Drains the write-ahead log into the batch transcription endpoint.
//!
//! Segments go up oldest first so a listener reconstructing a day sees them in
//! capture order. Every upload carries the segment's own id as the idempotency
//! key, so a request that succeeded server-side but whose response was lost is
//! safe to repeat: the retry is deduplicated rather than transcribed twice.
//!
//! A segment leaves the log in exactly three ways — accepted, recognised as a
//! duplicate, or permanently rejected. A retryable failure stops the pass and
//! leaves the whole queue intact, because uploading past a stuck segment would
//! reorder the audio.

use crate::capture_upload::{CaptureUploadOutcome, CaptureUploadTransport};
use crate::capture_wal::CaptureWal;
use tokio::sync::Mutex;

/// How many times one segment may fail retryably inside a single pass before
/// the pass gives up and waits for the next tick. Bounds the work done while
/// the network is down; it never drops the segment.
pub const DEFAULT_MAX_ATTEMPTS_PER_PASS: u32 = 3;

/// What one pass achieved.
///
/// `pending` is what the UI surfaces as "N clips waiting to upload": durability
/// the user cannot see is durability they will not trust.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CaptureDrain {
    pub uploaded: u64,
    pub pending: u64,
    pub last_error: Option<String>,
}

/// Uploads everything currently sealed, oldest first.
///
/// The log is taken and released around each individual read, so an upload in
/// flight never blocks the capture path from appending to the open segment —
/// the only ordering the ring depends on is between log operations, not
/// between a log operation and the network.
pub async fn drain(
    wal: &Mutex<Option<CaptureWal>>,
    transport: &dyn CaptureUploadTransport,
    max_attempts_per_pass: u32,
) -> CaptureDrain {
    let attempts = max_attempts_per_pass.max(1);
    let segments = match wal.lock().await.as_ref() {
        Some(wal) => wal.pending(),
        None => return CaptureDrain::default(),
    };
    let mut pending = segments.len() as u64;
    let mut uploaded = 0_u64;
    let mut last_error = None;
    for segment in &segments {
        let audio = wal
            .lock()
            .await
            .as_ref()
            .and_then(|wal| wal.read_audio(segment));
        let Some(audio) = audio else {
            // Evicted between listing and reading. Nothing to send.
            continue;
        };
        let mut attempt = 0_u32;
        let mut result = transport.upload(segment, &audio).await;
        attempt += 1;
        while result.outcome == CaptureUploadOutcome::Retry && attempt < attempts {
            result = transport.upload(segment, &audio).await;
            attempt += 1;
        }
        if result.outcome == CaptureUploadOutcome::Retry {
            last_error = result.message;
            break;
        }
        if result.done() {
            uploaded += 1;
        } else {
            // Permanently rejected. It still leaves the log — keeping it would
            // block every segment behind it in the ring — but the reason is
            // surfaced rather than swallowed.
            last_error = result.message;
        }
        if let Some(wal) = wal.lock().await.as_ref() {
            wal.remove(segment);
        }
        pending = pending.saturating_sub(1);
    }
    CaptureDrain {
        uploaded,
        pending,
        last_error,
    }
}

#[cfg(test)]
mod tests {
    use super::{DEFAULT_MAX_ATTEMPTS_PER_PASS, drain};
    use crate::capture_upload::{
        CaptureUploadOutcome, CaptureUploadResult, CaptureUploadTransport,
    };
    use crate::capture_wal::{CaptureWal, CaptureWalBounds, CaptureWalSegment, Clock, random_id};
    use std::future::Future;
    use std::path::PathBuf;
    use std::pin::Pin;
    use std::sync::{Arc, Mutex as StdMutex};
    use tokio::sync::Mutex;

    struct Sandbox {
        directory: PathBuf,
    }

    impl Sandbox {
        fn new(label: &str) -> Self {
            let directory = std::env::temp_dir().join(format!(
                "omi-uploader-{label}-{}-{}",
                std::process::id(),
                random_id()
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

    #[derive(Default)]
    struct Recorded {
        outcomes: Vec<CaptureUploadOutcome>,
        keys: Vec<String>,
        streams: Vec<String>,
    }

    #[derive(Default)]
    struct ScriptedTransport {
        recorded: StdMutex<Recorded>,
    }

    impl ScriptedTransport {
        fn with(outcomes: &[CaptureUploadOutcome]) -> Self {
            let transport = Self::default();
            if let Ok(mut recorded) = transport.recorded.lock() {
                recorded.outcomes = outcomes.to_vec();
            }
            transport
        }

        fn keys(&self) -> Vec<String> {
            self.recorded
                .lock()
                .map(|recorded| recorded.keys.clone())
                .unwrap_or_default()
        }

        fn streams(&self) -> Vec<String> {
            self.recorded
                .lock()
                .map(|recorded| recorded.streams.clone())
                .unwrap_or_default()
        }

        fn push(&self, outcomes: &[CaptureUploadOutcome]) {
            if let Ok(mut recorded) = self.recorded.lock() {
                recorded.outcomes.extend_from_slice(outcomes);
            }
        }
    }

    impl CaptureUploadTransport for ScriptedTransport {
        fn upload<'a>(
            &'a self,
            segment: &'a CaptureWalSegment,
            _audio: &'a [u8],
        ) -> Pin<Box<dyn Future<Output = CaptureUploadResult> + Send + 'a>> {
            let outcome = match self.recorded.lock() {
                Ok(mut recorded) => {
                    recorded.keys.push(segment.id.clone());
                    if recorded.streams.last() != Some(&segment.audio_stream_id) {
                        recorded.streams.push(segment.audio_stream_id.clone());
                    }
                    if recorded.outcomes.is_empty() {
                        CaptureUploadOutcome::Retry
                    } else {
                        recorded.outcomes.remove(0)
                    }
                }
                Err(_) => CaptureUploadOutcome::Retry,
            };
            Box::pin(async move { CaptureUploadResult::new(outcome, None) })
        }
    }

    fn clock() -> Clock {
        Arc::new(|| 1_767_225_600_000)
    }

    fn open(sandbox: &Sandbox) -> CaptureWal {
        CaptureWal::open(
            sandbox.directory.clone(),
            CaptureWalBounds::default(),
            clock(),
        )
        .unwrap_or_else(|error| panic!("wal opens: {error}"))
    }

    fn locked(wal: CaptureWal) -> Mutex<Option<CaptureWal>> {
        Mutex::new(Some(wal))
    }

    async fn pending(wal: &Mutex<Option<CaptureWal>>) -> Vec<CaptureWalSegment> {
        wal.lock()
            .await
            .as_ref()
            .map(CaptureWal::pending)
            .unwrap_or_default()
    }

    fn write(wal: &mut CaptureWal, bytes: &[u8], stream_id: &str) {
        wal.begin_segment("device-1", stream_id, "pcmU8", 8_000, 1, false)
            .unwrap_or_else(|error| panic!("segment begins: {error}"));
        wal.append(bytes)
            .unwrap_or_else(|error| panic!("append succeeds: {error}"));
        wal.seal()
            .unwrap_or_else(|error| panic!("seal succeeds: {error}"));
    }

    #[tokio::test]
    async fn a_retry_after_a_dropped_response_reuses_the_same_key() {
        let sandbox = Sandbox::new("same-key");
        let mut wal = open(&sandbox);
        write(&mut wal, &[7; 32], "stream-1");
        let transport = ScriptedTransport::with(&[
            CaptureUploadOutcome::Retry,
            CaptureUploadOutcome::Duplicate,
        ]);
        let wal = locked(wal);

        drain(&wal, &transport, 2).await;

        let keys = transport.keys();
        assert_eq!(keys.len(), 2);
        assert_eq!(keys.first(), keys.last());
        assert!(pending(&wal).await.is_empty());
    }

    #[tokio::test]
    async fn a_duplicate_is_treated_as_done_and_the_segment_is_dropped() {
        let sandbox = Sandbox::new("duplicate");
        let mut wal = open(&sandbox);
        write(&mut wal, &[7; 32], "stream-1");
        let transport = ScriptedTransport::with(&[CaptureUploadOutcome::Duplicate]);
        let wal = locked(wal);

        let outcome = drain(&wal, &transport, DEFAULT_MAX_ATTEMPTS_PER_PASS).await;

        assert_eq!(outcome.uploaded, 1);
        assert!(pending(&wal).await.is_empty());
    }

    #[tokio::test]
    async fn a_retryable_failure_keeps_every_segment_for_the_next_pass() {
        let sandbox = Sandbox::new("retryable");
        let mut wal = open(&sandbox);
        write(&mut wal, &[7; 32], "stream-1");
        write(&mut wal, &[7; 32], "stream-2");
        let transport = ScriptedTransport::default();
        let wal = locked(wal);

        drain(&wal, &transport, 1).await;
        assert_eq!(pending(&wal).await.len(), 2);

        transport.push(&[
            CaptureUploadOutcome::Accepted,
            CaptureUploadOutcome::Accepted,
        ]);
        let outcome = drain(&wal, &transport, 1).await;

        assert_eq!(outcome.uploaded, 2);
        assert!(pending(&wal).await.is_empty());
    }

    #[tokio::test]
    async fn the_pending_count_drops_to_zero_after_a_successful_pass() {
        let sandbox = Sandbox::new("pending");
        let mut wal = open(&sandbox);
        write(&mut wal, &[7; 32], "stream-1");
        write(&mut wal, &[7; 32], "stream-2");
        let transport = ScriptedTransport::with(&[
            CaptureUploadOutcome::Accepted,
            CaptureUploadOutcome::Accepted,
        ]);
        let wal = locked(wal);

        let outcome = drain(&wal, &transport, DEFAULT_MAX_ATTEMPTS_PER_PASS).await;

        assert_eq!(outcome.uploaded, 2);
        assert_eq!(outcome.pending, 0);
        assert_eq!(outcome.last_error, None);
    }

    #[tokio::test]
    async fn uploads_oldest_first() {
        let sandbox = Sandbox::new("oldest-first");
        let mut wal = open(&sandbox);
        write(&mut wal, &[1; 8], "a");
        write(&mut wal, &[2; 8], "b");
        let transport = ScriptedTransport::with(&[
            CaptureUploadOutcome::Accepted,
            CaptureUploadOutcome::Accepted,
        ]);
        let wal = locked(wal);

        drain(&wal, &transport, DEFAULT_MAX_ATTEMPTS_PER_PASS).await;

        assert_eq!(transport.streams(), vec!["a".to_owned(), "b".to_owned()]);
    }

    #[tokio::test]
    async fn a_permanently_rejected_segment_stops_blocking_the_queue() {
        let sandbox = Sandbox::new("rejected");
        let mut wal = open(&sandbox);
        write(&mut wal, &[1; 8], "a");
        write(&mut wal, &[2; 8], "b");
        let transport = ScriptedTransport::with(&[
            CaptureUploadOutcome::Rejected,
            CaptureUploadOutcome::Accepted,
        ]);
        let wal = locked(wal);

        let outcome = drain(&wal, &transport, DEFAULT_MAX_ATTEMPTS_PER_PASS).await;

        assert_eq!(outcome.uploaded, 1);
        assert!(pending(&wal).await.is_empty());
    }

    #[tokio::test]
    async fn a_stuck_segment_leaves_the_ones_behind_it_alone() {
        let sandbox = Sandbox::new("stuck");
        let mut wal = open(&sandbox);
        write(&mut wal, &[1; 8], "a");
        write(&mut wal, &[2; 8], "b");
        let transport = ScriptedTransport::with(&[CaptureUploadOutcome::Retry]);
        let wal = locked(wal);

        let outcome = drain(&wal, &transport, 1).await;

        assert_eq!(outcome.uploaded, 0);
        assert_eq!(outcome.pending, 2);
        // Only the head was tried: uploading past it would reorder the audio.
        assert_eq!(transport.keys().len(), 1);
        assert_eq!(pending(&wal).await.len(), 2);
    }

    #[tokio::test]
    async fn a_segment_already_gone_is_skipped_rather_than_uploaded_empty() {
        let sandbox = Sandbox::new("evicted");
        let mut wal = open(&sandbox);
        write(&mut wal, &[1; 8], "a");
        write(&mut wal, &[2; 8], "b");
        let head = wal.pending()[0].clone();
        wal.remove(&head);
        let transport = ScriptedTransport::with(&[CaptureUploadOutcome::Accepted]);
        let wal = locked(wal);

        let outcome = drain(&wal, &transport, DEFAULT_MAX_ATTEMPTS_PER_PASS).await;

        assert_eq!(outcome.uploaded, 1);
        assert_eq!(transport.streams(), vec!["b".to_owned()]);
        assert!(pending(&wal).await.is_empty());
    }
}
