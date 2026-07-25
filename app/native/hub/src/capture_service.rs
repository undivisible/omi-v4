//! The runtime seam between the client and the pendant capture pipeline.
//!
//! BLE stays on the client — Flutter owns the Android and iOS background
//! Bluetooth lifecycle — but everything downstream of a decoded audio frame
//! lives here: the write-ahead log, the gap accounting, and the pump that
//! drains sealed segments into the batch transcription endpoint.
//!
//! ## Why the hub and not the isolate
//!
//! The log is the thing that stands between a killed process and lost
//! recordings, so it wants two properties the Dart isolate could not give it:
//! writes that reach the operating system without waiting behind a garbage
//! collection, and a lifetime that is not the isolate's. Here the log is owned
//! by a dedicated thread with its own single-threaded runtime, so a slow write
//! stalls nothing but capture, and an upload in flight never stalls a write.
//!
//! ## Ordering
//!
//! Everything the client asks for arrives on one channel and is handled in
//! order, which is what the ring depends on: an append that overtook the seal
//! before it would land in the wrong segment, and a segment id handed out
//! before its predecessor was sealed would break the upload ordering. Uploads
//! are deliberately *outside* that ordering — they take the log only for the
//! moment each read or delete needs it.

use crate::capture_gap_log::{CaptureGapLog, CaptureGapRecord, DEFAULT_GAP_LIMIT};
use crate::capture_upload::{
    CaptureUploadTransport, UnavailableCaptureUploadTransport, WorkerCaptureUploadTransport,
};
use crate::capture_wal::{CaptureWal, CaptureWalBounds, Clock};
use crate::capture_wal_uploader::{DEFAULT_MAX_ATTEMPTS_PER_PASS, drain};
use crate::signals::{
    AudioEncoding, CaptureAudioAppended, CaptureGap, CaptureGaps, CaptureSegmentBegun,
    CaptureWalOpened, CaptureWalState, NativeEvent,
};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tokio::sync::{Mutex, mpsc};

/// How often the pump drains on its own. Matches the Dart uploader's minute
/// tick: often enough that a phone that came back online does not sit on a
/// queue, rare enough that a phone that is still offline is not woken for it.
const DRAIN_INTERVAL: Duration = Duration::from_secs(60);

/// Depth of the control channel. Capture appends land here at roughly one per
/// audio frame, so the queue absorbs several seconds of frames while a seal or
/// an eviction is in progress.
const CAPTURE_QUEUE_CAPACITY: usize = 512;

/// The subdirectory of the shared `.omi` data directory the log lives in.
const WAL_SUBDIRECTORY: &str = "capture-wal";

/// The gap log sits beside the write-ahead log, not in the client's key-value
/// store: a gap only means anything against the segments either side of it.
const GAP_FILE: &str = "capture-gaps.json";

/// One request from the client, in the order the client made it.
///
/// Deliberately not `Debug`-derived: one variant carries an account credential
/// and another carries raw captured audio, and neither belongs in a log line.
pub enum CaptureControl {
    Open {
        request_id: String,
        /// The shared `.omi` data directory. The client resolves it because
        /// only the client knows where the platform put it on mobile; empty
        /// falls back to `$HOME/.omi`.
        directory: String,
        max_bytes: Option<u64>,
        max_age_ms: Option<i64>,
        max_segment_bytes: Option<u64>,
    },
    ConfigureUpload {
        endpoint: Option<String>,
        firebase_token: Option<String>,
    },
    BeginSegment {
        request_id: String,
        device_id: String,
        audio_stream_id: String,
        encoding: AudioEncoding,
        sample_rate_hz: u32,
        channels: u8,
        gap_before: bool,
    },
    Append {
        request_id: String,
        bytes: Vec<u8>,
    },
    Seal {
        request_id: String,
    },
    Drain {
        request_id: String,
    },
    ReadState {
        request_id: String,
    },
    Close {
        request_id: String,
    },
    RecordGap {
        device_id: String,
        reason: String,
        ended_at_ms: i64,
        ended_stream_id: String,
    },
    RecordResume {
        device_id: String,
        at_ms: i64,
        stream_id: String,
    },
    ReadGaps {
        request_id: String,
    },
}

/// The encoding name written into a segment header.
///
/// These are the client's own `AudioEncoding` names rather than anything new,
/// because segments written by the previous Dart log carry exactly these
/// strings and the packaging step matches on them.
pub fn encoding_name(encoding: AudioEncoding) -> &'static str {
    match encoding {
        AudioEncoding::PcmS16Le => "pcmS16Le",
        AudioEncoding::PcmU8 => "pcmU8",
        AudioEncoding::Opus => "opus",
    }
}

/// Starts the capture thread and returns the channel that drives it.
///
/// The thread carries its own current-thread runtime so that the log's
/// blocking writes never sit in front of the assistant, the transcription
/// socket, or anything else on the hub's main runtime.
pub fn spawn() -> mpsc::Sender<CaptureControl> {
    let (sender, receiver) = mpsc::channel(CAPTURE_QUEUE_CAPACITY);
    let started = std::thread::Builder::new()
        .name("omi-capture-wal".into())
        .spawn(move || {
            let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            else {
                return;
            };
            runtime.block_on(CaptureService::new(Arc::new(now_ms)).run(receiver));
        });
    if started.is_err() {
        // No thread means no log. Capture still works — the client keeps
        // streaming to the transcription socket — it simply has no durability,
        // which is what every command below then reports.
        NativeEvent::CaptureWalOpened(CaptureWalOpened {
            request_id: String::new(),
            directory: None,
            error: Some("capture thread could not be started".to_owned()),
        })
        .send();
    }
    sender
}

fn now_ms() -> i64 {
    crate::approval::unix_time_ms()
}

struct CaptureService {
    now_ms: Clock,
    wal: Arc<Mutex<Option<CaptureWal>>>,
    gaps: CaptureGapLog,
    transport: Arc<dyn CaptureUploadTransport>,
    draining: Arc<AtomicBool>,
}

impl CaptureService {
    fn new(now_ms: Clock) -> Self {
        Self {
            now_ms,
            wal: Arc::new(Mutex::new(None)),
            gaps: CaptureGapLog::volatile(DEFAULT_GAP_LIMIT),
            transport: Arc::new(UnavailableCaptureUploadTransport),
            draining: Arc::new(AtomicBool::new(false)),
        }
    }

    async fn run(mut self, mut receiver: mpsc::Receiver<CaptureControl>) {
        let mut ticker = tokio::time::interval(DRAIN_INTERVAL);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        // The first tick of a tokio interval fires immediately; a drain before
        // the client has even opened the log would be pure noise.
        ticker.tick().await;
        loop {
            tokio::select! {
                control = receiver.recv() => match control {
                    Some(control) => self.handle(control).await,
                    None => break,
                },
                _ = ticker.tick() => self.start_drain(String::new()),
            }
        }
        if let Some(wal) = self.wal.lock().await.as_mut() {
            let _ = wal.close();
        }
    }

    async fn handle(&mut self, control: CaptureControl) {
        match control {
            CaptureControl::Open {
                request_id,
                directory,
                max_bytes,
                max_age_ms,
                max_segment_bytes,
            } => {
                self.open(
                    &request_id,
                    &directory,
                    max_bytes,
                    max_age_ms,
                    max_segment_bytes,
                )
                .await;
            }
            CaptureControl::ConfigureUpload {
                endpoint,
                firebase_token,
            } => {
                self.transport = build_transport(endpoint.as_deref(), firebase_token.as_deref());
            }
            CaptureControl::BeginSegment {
                request_id,
                device_id,
                audio_stream_id,
                encoding,
                sample_rate_hz,
                channels,
                gap_before,
            } => {
                let begun = match self.wal.lock().await.as_mut() {
                    Some(wal) => wal
                        .begin_segment(
                            &device_id,
                            &audio_stream_id,
                            encoding_name(encoding),
                            sample_rate_hz,
                            channels,
                            gap_before,
                        )
                        .map_err(|error| error.to_string()),
                    None => Err("capture log is not open".to_owned()),
                };
                let (segment_id, error) = match begun {
                    Ok(id) => (Some(id), None),
                    Err(error) => (None, Some(error)),
                };
                NativeEvent::CaptureSegmentBegun(CaptureSegmentBegun {
                    request_id,
                    segment_id,
                    error,
                })
                .send();
            }
            CaptureControl::Append { request_id, bytes } => {
                // Answered even when there is no log and even when the write
                // failed: the client is waiting on this before it hands the
                // same frame to the transcription socket, and a frame that is
                // never acknowledged is a capture path that stops.
                let error = match self.wal.lock().await.as_mut() {
                    Some(wal) => wal.append(&bytes).err().map(|error| error.to_string()),
                    None => None,
                };
                NativeEvent::CaptureAudioAppended(CaptureAudioAppended { request_id, error })
                    .send();
            }
            CaptureControl::Seal { request_id } => {
                let error = match self.wal.lock().await.as_mut() {
                    Some(wal) => wal.seal().err().map(|error| error.to_string()),
                    None => None,
                };
                self.publish_state(request_id, 0, error).await;
            }
            CaptureControl::Drain { request_id } => self.start_drain(request_id),
            CaptureControl::ReadState { request_id } => {
                self.publish_state(request_id, 0, None).await;
            }
            CaptureControl::Close { request_id } => {
                let error = match self.wal.lock().await.as_mut() {
                    Some(wal) => wal.close().err().map(|error| error.to_string()),
                    None => None,
                };
                self.publish_state(request_id, 0, error).await;
            }
            CaptureControl::RecordGap {
                device_id,
                reason,
                ended_at_ms,
                ended_stream_id,
            } => {
                self.gaps.record(CaptureGapRecord {
                    device_id,
                    reason,
                    ended_at_ms,
                    ended_stream_id,
                    resumed_at_ms: None,
                    resumed_stream_id: None,
                });
            }
            CaptureControl::RecordResume {
                device_id,
                at_ms,
                stream_id,
            } => self.gaps.record_resume(&device_id, at_ms, &stream_id),
            CaptureControl::ReadGaps { request_id } => {
                NativeEvent::CaptureGaps(CaptureGaps {
                    request_id,
                    gaps: self.gaps.read().iter().map(gap_signal).collect(),
                })
                .send();
            }
        }
    }

    async fn open(
        &mut self,
        request_id: &str,
        directory: &str,
        max_bytes: Option<u64>,
        max_age_ms: Option<i64>,
        max_segment_bytes: Option<u64>,
    ) {
        if let Some(wal) = self.wal.lock().await.as_mut() {
            let _ = wal.close();
        }
        let root = data_root(directory);
        let defaults = CaptureWalBounds::default();
        let bounds = CaptureWalBounds {
            max_bytes: max_bytes.unwrap_or(defaults.max_bytes),
            max_age_ms: max_age_ms.unwrap_or(defaults.max_age_ms),
            max_segment_bytes: max_segment_bytes.unwrap_or(defaults.max_segment_bytes),
        };
        let wal_directory = root.join(WAL_SUBDIRECTORY);
        let opened = CaptureWal::open(&wal_directory, bounds, Arc::clone(&self.now_ms));
        let event = match opened {
            Ok(wal) => {
                *self.wal.lock().await = Some(wal);
                self.gaps = CaptureGapLog::open(root.join(GAP_FILE), DEFAULT_GAP_LIMIT);
                CaptureWalOpened {
                    request_id: request_id.to_owned(),
                    directory: Some(wal_directory.to_string_lossy().into_owned()),
                    error: None,
                }
            }
            // Read-only storage, no space, a directory that is a file: reported
            // and skipped rather than blocking capture.
            Err(error) => {
                *self.wal.lock().await = None;
                CaptureWalOpened {
                    request_id: request_id.to_owned(),
                    directory: None,
                    error: Some(error.to_string()),
                }
            }
        };
        NativeEvent::CaptureWalOpened(event).send();
    }

    /// Runs one upload pass off the control loop, so appends keep landing
    /// while the network is slow. Concurrent requests share one pass, exactly
    /// as the Dart uploader did.
    fn start_drain(&self, request_id: String) {
        if self.draining.swap(true, Ordering::SeqCst) {
            return;
        }
        let wal = Arc::clone(&self.wal);
        let transport = Arc::clone(&self.transport);
        let draining = Arc::clone(&self.draining);
        tokio::spawn(async move {
            let outcome = drain(&wal, transport.as_ref(), DEFAULT_MAX_ATTEMPTS_PER_PASS).await;
            let stats = wal
                .lock()
                .await
                .as_ref()
                .map(CaptureWal::stats)
                .unwrap_or_default();
            draining.store(false, Ordering::SeqCst);
            NativeEvent::CaptureWalState(CaptureWalState {
                request_id,
                pending_segments: stats.segments,
                pending_bytes: stats.bytes,
                oldest_started_at_ms: stats.oldest_started_at_ms,
                uploaded: outcome.uploaded,
                last_error: outcome.last_error,
            })
            .send();
        });
    }

    async fn publish_state(&self, request_id: String, uploaded: u64, last_error: Option<String>) {
        let stats = self
            .wal
            .lock()
            .await
            .as_ref()
            .map(CaptureWal::stats)
            .unwrap_or_default();
        NativeEvent::CaptureWalState(CaptureWalState {
            request_id,
            pending_segments: stats.segments,
            pending_bytes: stats.bytes,
            oldest_started_at_ms: stats.oldest_started_at_ms,
            uploaded,
            last_error,
        })
        .send();
    }
}

/// Chooses the transport for the credentials the client last supplied. Missing
/// either half means no reachable endpoint, and the log then keeps every
/// segment until it ages or size-evicts out rather than dropping audio because
/// nobody was signed in.
fn build_transport(
    endpoint: Option<&str>,
    firebase_token: Option<&str>,
) -> Arc<dyn CaptureUploadTransport> {
    match (endpoint, firebase_token) {
        (Some(endpoint), Some(token)) if !endpoint.is_empty() && !token.is_empty() => {
            WorkerCaptureUploadTransport::new(endpoint, token).map_or_else(
                || Arc::new(UnavailableCaptureUploadTransport) as Arc<dyn CaptureUploadTransport>,
                |transport| Arc::new(transport) as Arc<dyn CaptureUploadTransport>,
            )
        }
        _ => Arc::new(UnavailableCaptureUploadTransport),
    }
}

/// The one durable home for Omi's local data, as the client resolved it. On
/// desktop that is `~/.omi`; on mobile it is a `.omi` folder inside the
/// platform's private application-support area, which only the client can
/// name — so an empty value falls back to the desktop convention rather than
/// inventing a location.
fn data_root(directory: &str) -> PathBuf {
    if !directory.is_empty() {
        return PathBuf::from(directory);
    }
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .unwrap_or_default();
    if home.is_empty() {
        std::env::temp_dir().join(".omi")
    } else {
        PathBuf::from(home).join(".omi")
    }
}

fn gap_signal(gap: &CaptureGapRecord) -> CaptureGap {
    CaptureGap {
        device_id: gap.device_id.clone(),
        reason: gap.reason.clone(),
        ended_at_ms: gap.ended_at_ms,
        ended_stream_id: gap.ended_stream_id.clone(),
        resumed_at_ms: gap.resumed_at_ms,
        resumed_stream_id: gap.resumed_stream_id.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        CaptureControl, CaptureService, build_transport, data_root, encoding_name, gap_signal,
    };
    use crate::capture_gap_log::CaptureGapRecord;
    use crate::capture_wal::random_id;
    use crate::signals::{AudioEncoding, NativeEvent, test_events};
    use std::path::PathBuf;
    use std::sync::Arc;

    struct Sandbox {
        directory: PathBuf,
    }

    impl Sandbox {
        fn new(label: &str) -> Self {
            let directory = std::env::temp_dir().join(format!(
                "omi-capture-{label}-{}-{}",
                std::process::id(),
                random_id()
            ));
            let _ = std::fs::create_dir_all(&directory);
            Self { directory }
        }

        fn path(&self) -> String {
            self.directory.to_string_lossy().into_owned()
        }
    }

    impl Drop for Sandbox {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.directory);
        }
    }

    fn service() -> CaptureService {
        CaptureService::new(Arc::new(|| 1_767_225_600_000))
    }

    async fn open(service: &mut CaptureService, sandbox: &Sandbox) {
        service
            .handle(CaptureControl::Open {
                request_id: "open-1".to_owned(),
                directory: sandbox.path(),
                max_bytes: Some(4096),
                max_age_ms: Some(3_600_000),
                max_segment_bytes: Some(1024),
            })
            .await;
    }

    #[tokio::test]
    async fn opening_reports_the_directory_it_settled_on() {
        let sandbox = Sandbox::new("open");
        let mut service = service();
        let _ = test_events::take();

        open(&mut service, &sandbox).await;

        let events = test_events::take();
        let Some(NativeEvent::CaptureWalOpened(opened)) = events.first() else {
            panic!("an open event is sent");
        };
        assert_eq!(opened.error, None);
        assert!(
            opened
                .directory
                .as_deref()
                .is_some_and(|value| value.ends_with("capture-wal"))
        );
        assert!(sandbox.directory.join("capture-wal").is_dir());
    }

    #[tokio::test]
    async fn a_segment_reports_the_idempotency_key_it_minted() {
        let sandbox = Sandbox::new("segment");
        let mut service = service();
        open(&mut service, &sandbox).await;
        let _ = test_events::take();

        service
            .handle(CaptureControl::BeginSegment {
                request_id: "begin-1".to_owned(),
                device_id: "device-1".to_owned(),
                audio_stream_id: "stream-1".to_owned(),
                encoding: AudioEncoding::Opus,
                sample_rate_hz: 16_000,
                channels: 1,
                gap_before: true,
            })
            .await;

        let events = test_events::take();
        let Some(NativeEvent::CaptureSegmentBegun(begun)) = events.first() else {
            panic!("a segment event is sent");
        };
        assert_eq!(begun.error, None);
        assert_eq!(begun.segment_id.as_deref().map(str::len), Some(32));
    }

    #[tokio::test]
    async fn a_segment_without_an_open_log_reports_rather_than_fails() {
        let mut service = service();
        let _ = test_events::take();

        service
            .handle(CaptureControl::BeginSegment {
                request_id: "begin-1".to_owned(),
                device_id: "device-1".to_owned(),
                audio_stream_id: "stream-1".to_owned(),
                encoding: AudioEncoding::PcmU8,
                sample_rate_hz: 8_000,
                channels: 1,
                gap_before: false,
            })
            .await;
        // An append with nowhere to go must also be survivable.
        service
            .handle(CaptureControl::Append {
                request_id: "append-1".to_owned(),
                bytes: vec![1, 2, 3],
            })
            .await;

        let events = test_events::take();
        let Some(NativeEvent::CaptureSegmentBegun(begun)) = events.first() else {
            panic!("a segment event is sent");
        };
        assert_eq!(begun.segment_id, None);
        assert_eq!(begun.error.as_deref(), Some("capture log is not open"));
        // Still acknowledged: a frame that is never answered is a capture path
        // that stops waiting for it.
        let Some(NativeEvent::CaptureAudioAppended(appended)) = events.get(1) else {
            panic!("an append acknowledgement is sent");
        };
        assert_eq!(appended.request_id, "append-1");
        assert_eq!(appended.error, None);
    }

    #[tokio::test]
    async fn sealing_publishes_what_is_waiting_to_upload() {
        let sandbox = Sandbox::new("seal");
        let mut service = service();
        open(&mut service, &sandbox).await;
        service
            .handle(CaptureControl::BeginSegment {
                request_id: "begin-1".to_owned(),
                device_id: "device-1".to_owned(),
                audio_stream_id: "stream-1".to_owned(),
                encoding: AudioEncoding::PcmU8,
                sample_rate_hz: 8_000,
                channels: 1,
                gap_before: false,
            })
            .await;
        service
            .handle(CaptureControl::Append {
                request_id: "append-1".to_owned(),
                bytes: vec![7; 64],
            })
            .await;
        let _ = test_events::take();

        service
            .handle(CaptureControl::Seal {
                request_id: "seal-1".to_owned(),
            })
            .await;

        let events = test_events::take();
        let Some(NativeEvent::CaptureWalState(state)) = events.first() else {
            panic!("a state event is sent");
        };
        assert_eq!(state.pending_segments, 1);
        assert_eq!(state.pending_bytes, 64);
        assert_eq!(state.oldest_started_at_ms, Some(1_767_225_600_000));
        assert_eq!(state.last_error, None);
    }

    #[tokio::test]
    async fn gaps_round_trip_through_the_log_the_segments_live_beside() {
        let sandbox = Sandbox::new("gaps");
        let mut service = service();
        open(&mut service, &sandbox).await;
        service
            .handle(CaptureControl::RecordGap {
                device_id: "device-1".to_owned(),
                reason: "packetDiscontinuity".to_owned(),
                ended_at_ms: 100,
                ended_stream_id: "stream-1".to_owned(),
            })
            .await;
        service
            .handle(CaptureControl::RecordResume {
                device_id: "device-1".to_owned(),
                at_ms: 300,
                stream_id: "stream-2".to_owned(),
            })
            .await;
        let _ = test_events::take();

        service
            .handle(CaptureControl::ReadGaps {
                request_id: "gaps-1".to_owned(),
            })
            .await;

        let events = test_events::take();
        let Some(NativeEvent::CaptureGaps(gaps)) = events.first() else {
            panic!("a gaps event is sent");
        };
        assert_eq!(gaps.gaps.len(), 1);
        assert_eq!(gaps.gaps[0].ended_stream_id, "stream-1");
        assert_eq!(gaps.gaps[0].resumed_stream_id.as_deref(), Some("stream-2"));
        assert!(sandbox.directory.join("capture-gaps.json").is_file());
    }

    #[tokio::test]
    async fn reopening_the_log_seals_what_the_last_run_left_open() {
        let sandbox = Sandbox::new("reopen");
        let mut first = service();
        open(&mut first, &sandbox).await;
        first
            .handle(CaptureControl::BeginSegment {
                request_id: "begin-1".to_owned(),
                device_id: "device-1".to_owned(),
                audio_stream_id: "stream-1".to_owned(),
                encoding: AudioEncoding::PcmU8,
                sample_rate_hz: 8_000,
                channels: 1,
                gap_before: false,
            })
            .await;
        first
            .handle(CaptureControl::Append {
                request_id: "append-1".to_owned(),
                bytes: vec![3; 48],
            })
            .await;
        drop(first);

        let mut second = service();
        open(&mut second, &sandbox).await;
        let _ = test_events::take();
        second
            .handle(CaptureControl::ReadState {
                request_id: "state-1".to_owned(),
            })
            .await;

        let events = test_events::take();
        let Some(NativeEvent::CaptureWalState(state)) = events.first() else {
            panic!("a state event is sent");
        };
        assert_eq!(state.pending_segments, 1);
        assert_eq!(state.pending_bytes, 48);
    }

    #[test]
    fn encoding_names_match_what_the_packaging_step_matches_on() {
        assert_eq!(encoding_name(AudioEncoding::PcmS16Le), "pcmS16Le");
        assert_eq!(encoding_name(AudioEncoding::PcmU8), "pcmU8");
        assert_eq!(encoding_name(AudioEncoding::Opus), "opus");
    }

    #[test]
    fn an_empty_directory_falls_back_rather_than_inventing_a_location() {
        let resolved = data_root("");
        assert!(resolved.ends_with(".omi"));
        assert_eq!(data_root("/tmp/example"), PathBuf::from("/tmp/example"));
    }

    #[tokio::test]
    async fn half_configured_credentials_never_reach_the_network() {
        // Every one of these must keep the audio rather than post it nowhere.
        for (endpoint, token) in [
            (None, None),
            (Some("https://api.example.test"), None),
            (None, Some("token")),
            (Some(""), Some("token")),
            (Some("https://api.example.test"), Some("")),
            (Some("http://api.example.test"), Some("token")),
        ] {
            let transport = build_transport(endpoint, token);
            let segment = crate::capture_wal::CaptureWalSegment {
                id: "a".repeat(32),
                sequence: 0,
                device_id: "device-1".to_owned(),
                audio_stream_id: "stream-1".to_owned(),
                encoding: "pcmU8".to_owned(),
                framing: crate::capture_wal::CaptureWalFraming::Raw,
                sample_rate_hz: 8_000,
                channels: 1,
                started_at_ms: 0,
                gap_before: false,
                audio_bytes: 4,
            };
            let result = transport.upload(&segment, &[1, 2, 3, 4]).await;
            assert_eq!(
                result.message.as_deref(),
                Some("Batch transcription upload is not configured."),
                "{endpoint:?}/{token:?}"
            );
        }
    }

    #[test]
    fn a_gap_crosses_the_bridge_with_both_sides_of_the_discontinuity() {
        let signal = gap_signal(&CaptureGapRecord {
            device_id: "device-1".to_owned(),
            reason: "frameTooLarge".to_owned(),
            ended_at_ms: 10,
            ended_stream_id: "stream-1".to_owned(),
            resumed_at_ms: Some(40),
            resumed_stream_id: Some("stream-2".to_owned()),
        });

        assert_eq!(signal.reason, "frameTooLarge");
        assert_eq!(signal.ended_at_ms, 10);
        assert_eq!(signal.resumed_at_ms, Some(40));
        assert_ne!(
            signal.ended_stream_id,
            signal.resumed_stream_id.unwrap_or_default()
        );
    }
}
