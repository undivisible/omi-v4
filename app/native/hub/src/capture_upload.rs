//! Repackaging sealed write-ahead-log segments and posting them to the
//! Worker's batch transcription endpoint.
//!
//! The segment's own id is the client-supplied idempotency key, so the seam
//! between the log and the server is deliberately narrow: one sealed segment,
//! one key, one outcome. Anything that honours a caller-supplied message id can
//! be dropped in here without the log or the uploader changing.

use crate::capture_wal::{CaptureWalFraming, CaptureWalSegment};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::future::Future;
use std::pin::Pin;
use std::sync::LazyLock;
use std::time::Duration;

/// The route `clientMessageId` reservations are made against.
pub const DEFAULT_UPLOAD_PATH: &str = "/api/v1/speech/transcriptions";

/// The pendant's frame length. Fixed in firmware at 320 samples of 16 kHz
/// audio; Ogg Opus granule positions are always counted at 48 kHz.
const OPUS_FRAME_MS: usize = 20;
const OPUS_FRAME_GRANULE: u64 = 960;
const OPUS_SERIAL: u32 = 0x4f4d_4901;
const OGG_MAX_LACES: usize = 255;
const OGG_MAX_PAGE_BYTES: usize = 4096;
const MILLISECONDS_PER_SECOND: usize = 1000;

const UPLOAD_TIMEOUT: Duration = Duration::from_secs(60);

/// What the server did with an uploaded segment.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CaptureUploadOutcome {
    /// Stored and queued for transcription. The segment can be deleted.
    Accepted,
    /// The idempotency key was already known, so this was a retry of a request
    /// the server had already processed. Indistinguishable from
    /// [`CaptureUploadOutcome::Accepted`] for the client, and deliberately so —
    /// that is what makes retry-after-drop safe.
    Duplicate,
    /// A transient failure (offline, 5xx, 429). Keep the segment and try again.
    Retry,
    /// The server refused this segment and will keep refusing it. Dropping it
    /// is the only way to stop it blocking every segment behind it in the ring.
    Rejected,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CaptureUploadResult {
    pub outcome: CaptureUploadOutcome,
    pub message: Option<String>,
}

impl CaptureUploadResult {
    pub fn new(outcome: CaptureUploadOutcome, message: Option<String>) -> Self {
        Self { outcome, message }
    }

    pub fn done(&self) -> bool {
        matches!(
            self.outcome,
            CaptureUploadOutcome::Accepted | CaptureUploadOutcome::Duplicate
        )
    }
}

/// A sealed segment repackaged into something a transcription model will
/// actually accept, plus the exact duration it covers.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CaptureUploadPayload {
    /// The container name the endpoint is given: `wav` or `ogg`.
    pub format: &'static str,
    pub bytes: Vec<u8>,
    pub duration_seconds: u64,
}

/// The one seam between the write-ahead log and the server.
///
/// The contract is deliberately narrow: one sealed segment, one client-chosen
/// idempotency key, one outcome. The futures are boxed so the uploader can hold
/// whichever transport the build configured behind one handle.
pub trait CaptureUploadTransport: Send + Sync {
    fn upload<'a>(
        &'a self,
        segment: &'a CaptureWalSegment,
        audio: &'a [u8],
    ) -> Pin<Box<dyn Future<Output = CaptureUploadResult> + Send + 'a>>;
}

/// Repackages a segment's raw payload into an uploadable container, or returns
/// `None` when it cannot be — an unknown encoding, an Opus segment written
/// before the log recorded packet boundaries, or an empty payload.
///
/// The pendant streams bare Opus packets (16 kHz mono, 20 ms frames, 32 kbps —
/// `firmware/BLE_CONTRACTS.md` §2.2) and the log stores them in that encoding.
/// No transcription model takes bare Opus packets, so they are Ogg-encapsulated
/// here, on the phone, rather than shipped to an endpoint that would reject
/// every one of them. PCM is likewise wrapped in a WAV header.
pub fn capture_upload_payload(
    segment: &CaptureWalSegment,
    audio: &[u8],
) -> Option<CaptureUploadPayload> {
    if audio.is_empty() {
        return None;
    }
    let channels = if segment.channels < 1 {
        1
    } else {
        segment.channels
    };
    let sample_rate_hz = segment.sample_rate_hz;
    if sample_rate_hz == 0 {
        return None;
    }
    match segment.encoding.as_str() {
        "pcmS16Le" | "pcmU8" => {
            let bits_per_sample: u16 = if segment.encoding == "pcmU8" { 8 } else { 16 };
            let bytes_per_second =
                sample_rate_hz as usize * channels as usize * (bits_per_sample as usize / 8);
            Some(CaptureUploadPayload {
                format: "wav",
                bytes: wav(audio, sample_rate_hz, channels, bits_per_sample),
                duration_seconds: at_least_one_second(audio.len(), bytes_per_second),
            })
        }
        "opus" => {
            if segment.framing != CaptureWalFraming::Len16 {
                return None;
            }
            let packets = unframe(audio);
            if packets.is_empty() {
                return None;
            }
            let duration_seconds =
                at_least_one_second(packets.len() * OPUS_FRAME_MS, MILLISECONDS_PER_SECOND);
            Some(CaptureUploadPayload {
                format: "ogg",
                bytes: ogg_opus(&packets, sample_rate_hz, channels),
                duration_seconds,
            })
        }
        _ => None,
    }
}

/// A segment always reserves at least one second: the endpoint's admission
/// reservation is denominated in whole seconds and a zero-second reservation
/// would admit unbounded audio.
fn at_least_one_second(quantity: usize, per_second: usize) -> u64 {
    if per_second == 0 {
        return 1;
    }
    let seconds = quantity.div_ceil(per_second);
    if seconds < 1 { 1 } else { seconds as u64 }
}

/// Splits a `len16`-framed payload back into packets. A truncated tail — the
/// last frame a killed process was mid-write on — is dropped rather than
/// failing the whole segment.
fn unframe(audio: &[u8]) -> Vec<&[u8]> {
    let mut packets = Vec::new();
    let mut offset = 0_usize;
    while offset + 2 <= audio.len() {
        let length = usize::from(u16::from_be_bytes([audio[offset], audio[offset + 1]]));
        if length == 0 || offset + 2 + length > audio.len() {
            break;
        }
        packets.push(&audio[offset + 2..offset + 2 + length]);
        offset += 2 + length;
    }
    packets
}

fn wav(samples: &[u8], sample_rate_hz: u32, channels: u8, bits_per_sample: u16) -> Vec<u8> {
    let block_align = u32::from(channels) * u32::from(bits_per_sample / 8);
    let mut out = Vec::with_capacity(44 + samples.len());
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36_u32.saturating_add(samples.len() as u32)).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16_u32.to_le_bytes());
    out.extend_from_slice(&1_u16.to_le_bytes());
    out.extend_from_slice(&u16::from(channels).to_le_bytes());
    out.extend_from_slice(&sample_rate_hz.to_le_bytes());
    out.extend_from_slice(&sample_rate_hz.saturating_mul(block_align).to_le_bytes());
    out.extend_from_slice(&(block_align as u16).to_le_bytes());
    out.extend_from_slice(&bits_per_sample.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&(samples.len() as u32).to_le_bytes());
    out.extend_from_slice(samples);
    out
}

/// Ogg's CRC is the unreflected CRC-32/MPEG-2 polynomial with a zero initial
/// value and no final inversion, computed over the page with its own checksum
/// field zeroed.
fn ogg_crc(page: &[u8]) -> u32 {
    static TABLE: LazyLock<[u32; 256]> = LazyLock::new(|| {
        let mut table = [0_u32; 256];
        for (index, slot) in table.iter_mut().enumerate() {
            let mut value = (index as u32) << 24;
            for _ in 0..8 {
                value = if value & 0x8000_0000 != 0 {
                    (value << 1) ^ 0x04c1_1db7
                } else {
                    value << 1
                };
            }
            *slot = value;
        }
        table
    });
    let mut crc = 0_u32;
    for byte in page {
        crc = (crc << 8) ^ TABLE[usize::from(((crc >> 24) as u8) ^ byte)];
    }
    crc
}

fn ogg_page(packets: &[&[u8]], header_type: u8, granule: u64, page: u32) -> Vec<u8> {
    let mut laces: Vec<u8> = Vec::new();
    for packet in packets {
        let mut remaining = packet.len();
        while remaining >= 255 {
            laces.push(255);
            remaining -= 255;
        }
        laces.push(remaining as u8);
    }
    let mut bytes = Vec::new();
    bytes.extend_from_slice(b"OggS");
    bytes.push(0);
    bytes.push(header_type);
    bytes.extend_from_slice(&granule.to_le_bytes());
    bytes.extend_from_slice(&OPUS_SERIAL.to_le_bytes());
    bytes.extend_from_slice(&page.to_le_bytes());
    bytes.extend_from_slice(&0_u32.to_le_bytes());
    bytes.push(laces.len() as u8);
    bytes.extend_from_slice(&laces);
    for packet in packets {
        bytes.extend_from_slice(packet);
    }
    let checksum = ogg_crc(&bytes).to_le_bytes();
    bytes[22..26].copy_from_slice(&checksum);
    bytes
}

fn ogg_opus(packets: &[&[u8]], sample_rate_hz: u32, channels: u8) -> Vec<u8> {
    let mut head = Vec::new();
    head.extend_from_slice(b"OpusHead");
    head.push(1);
    head.push(channels);
    head.extend_from_slice(&0_u16.to_le_bytes());
    head.extend_from_slice(&sample_rate_hz.to_le_bytes());
    head.extend_from_slice(&0_u16.to_le_bytes());
    head.push(0);
    let vendor = b"omi";
    let mut tags = Vec::new();
    tags.extend_from_slice(b"OpusTags");
    tags.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
    tags.extend_from_slice(vendor);
    tags.extend_from_slice(&0_u32.to_le_bytes());

    let mut output = ogg_page(&[head.as_slice()], 0x02, 0, 0);
    output.extend_from_slice(&ogg_page(&[tags.as_slice()], 0, 0, 1));
    let mut page = 2_u32;
    let mut granule = 0_u64;
    let mut index = 0_usize;
    while index < packets.len() {
        let mut batch: Vec<&[u8]> = Vec::new();
        let mut laces = 0_usize;
        let mut bytes = 0_usize;
        while index < packets.len() {
            let packet = packets[index];
            let packet_laces = packet.len() / 255 + 1;
            if !batch.is_empty()
                && (laces + packet_laces > OGG_MAX_LACES
                    || bytes + packet.len() > OGG_MAX_PAGE_BYTES)
            {
                break;
            }
            batch.push(packet);
            laces += packet_laces;
            bytes += packet.len();
            index += 1;
        }
        granule += batch.len() as u64 * OPUS_FRAME_GRANULE;
        let header_type = if index >= packets.len() { 0x04 } else { 0 };
        output.extend_from_slice(&ogg_page(&batch, header_type, granule, page));
        page += 1;
    }
    output
}

/// The request body the batch transcription route reserves against.
///
/// The segment id travels as `clientMessageId`, which is what
/// `POST /api/v1/speech/transcriptions` derives its admission reservation from:
/// a retry after a dropped response replays the stored transcript instead of
/// calling upstream, so it neither re-charges the account nor duplicates the
/// segment. The raw BLE device id never leaves the phone — it is SHA-256'd
/// first, exactly as the live managed-STT path does.
pub fn upload_body(segment: &CaptureWalSegment, payload: &CaptureUploadPayload) -> Value {
    json!({
        "clientMessageId": segment.id,
        "format": payload.format,
        "durationSeconds": payload.duration_seconds,
        "audio": BASE64.encode(&payload.bytes),
        // Provenance the evidence model needs: which stream the audio came
        // from, and whether a recorded discontinuity precedes it.
        "deviceId": hashed_device_id(&segment.device_id),
        "audioStreamId": segment.audio_stream_id,
        "gapBefore": segment.gap_before,
        "startedAt": iso8601_utc(segment.started_at_ms),
    })
}

fn hashed_device_id(device_id: &str) -> String {
    Sha256::digest(device_id.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// The exact shape the Dart log sent: UTC, millisecond precision, `Z` suffix.
/// The endpoint parses it as the segment's start instant, so a different
/// precision would move every locator the evidence model derives from it.
fn iso8601_utc(milliseconds: i64) -> String {
    chrono::DateTime::from_timestamp_millis(milliseconds).map_or_else(
        || "1970-01-01T00:00:00.000Z".to_owned(),
        |value| value.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string(),
    )
}

/// Turns one HTTP answer into the four outcomes the uploader knows how to act
/// on. Split out from the transport so the classification — which is what
/// decides whether audio is kept, dropped, or replayed under the same key — is
/// testable without a socket.
pub fn classify(status: u16, body: Option<&Value>) -> CaptureUploadResult {
    let message = body
        .and_then(|body| body.get("error"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    if matches!(status, 200 | 201 | 202 | 204) {
        // A server that recognises the key says so explicitly; either way the
        // client is finished with the segment.
        let duplicate = body.is_some_and(|body| {
            body.get("idempotentReplay") == Some(&Value::Bool(true))
                || body.get("duplicate") == Some(&Value::Bool(true))
        });
        return CaptureUploadResult::new(
            if duplicate {
                CaptureUploadOutcome::Duplicate
            } else {
                CaptureUploadOutcome::Accepted
            },
            message,
        );
    }
    if status == 409 {
        // Two different 409s: the same id still being processed, which resolves
        // itself, and the same id carrying different audio, which never will.
        let retry = message
            .as_deref()
            .is_some_and(|message| message.contains("in progress"));
        return CaptureUploadResult::new(
            if retry {
                CaptureUploadOutcome::Retry
            } else {
                CaptureUploadOutcome::Rejected
            },
            message,
        );
    }
    if matches!(status, 401 | 403 | 408 | 425 | 429) || status >= 500 {
        // Entitlement and auth can come back; the audio outlives both.
        return CaptureUploadResult::new(CaptureUploadOutcome::Retry, message);
    }
    let message = message.unwrap_or_else(|| format!("Upload rejected ({status})"));
    CaptureUploadResult::new(CaptureUploadOutcome::Rejected, Some(message))
}

/// Posts sealed segments to the Worker's batch transcription endpoint.
pub struct WorkerCaptureUploadTransport {
    client: reqwest::Client,
    origin: String,
    firebase_token: String,
    path: String,
}

impl WorkerCaptureUploadTransport {
    /// Builds a transport for `origin`, or `None` when the origin is not an
    /// absolute HTTPS URL or the HTTP client cannot be built. A transport that
    /// cannot be built is not an error the audio should die for: the caller
    /// falls back to [`UnavailableCaptureUploadTransport`], which keeps every
    /// segment.
    pub fn new(origin: &str, firebase_token: &str) -> Option<Self> {
        let parsed = url::Url::parse(origin).ok()?;
        if parsed.scheme() != "https" {
            return None;
        }
        let client = reqwest::Client::builder()
            .timeout(UPLOAD_TIMEOUT)
            .build()
            .ok()?;
        Some(Self {
            client,
            origin: parsed.origin().ascii_serialization(),
            firebase_token: firebase_token.to_owned(),
            path: DEFAULT_UPLOAD_PATH.to_owned(),
        })
    }
}

impl CaptureUploadTransport for WorkerCaptureUploadTransport {
    fn upload<'a>(
        &'a self,
        segment: &'a CaptureWalSegment,
        audio: &'a [u8],
    ) -> Pin<Box<dyn Future<Output = CaptureUploadResult> + Send + 'a>> {
        Box::pin(async move {
            let Some(payload) = capture_upload_payload(segment, audio) else {
                // Nothing a later pass could do differently, and keeping it
                // would block every segment behind it.
                return CaptureUploadResult::new(
                    CaptureUploadOutcome::Rejected,
                    Some("Segment cannot be packaged for upload.".to_owned()),
                );
            };
            let response = self
                .client
                .post(format!("{}{}", self.origin, self.path))
                .bearer_auth(&self.firebase_token)
                .json(&upload_body(segment, &payload))
                .send()
                .await;
            let response = match response {
                Ok(response) => response,
                // Offline, DNS, TLS, timeout: the audio is still worth keeping.
                Err(error) => {
                    return CaptureUploadResult::new(
                        CaptureUploadOutcome::Retry,
                        Some(error.to_string()),
                    );
                }
            };
            let status = response.status().as_u16();
            let body = response.json::<Value>().await.ok();
            classify(status, body.as_ref())
        })
    }
}

/// A transport for builds where the endpoint is not reachable — no signed-in
/// account, or no configured Worker. Every segment stays in the log until it
/// ages or size-evicts out; nothing is ever silently discarded because the
/// upload route is missing.
pub struct UnavailableCaptureUploadTransport;

impl CaptureUploadTransport for UnavailableCaptureUploadTransport {
    fn upload<'a>(
        &'a self,
        _segment: &'a CaptureWalSegment,
        _audio: &'a [u8],
    ) -> Pin<Box<dyn Future<Output = CaptureUploadResult> + Send + 'a>> {
        Box::pin(async {
            CaptureUploadResult::new(
                CaptureUploadOutcome::Retry,
                Some("Batch transcription upload is not configured.".to_owned()),
            )
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{
        CaptureUploadOutcome, CaptureUploadTransport, UnavailableCaptureUploadTransport,
        WorkerCaptureUploadTransport, capture_upload_payload, classify, upload_body,
    };
    use crate::capture_wal::{CaptureWalFraming, CaptureWalSegment};
    use serde_json::json;

    fn segment(encoding: &str, framing: CaptureWalFraming, gap_before: bool) -> CaptureWalSegment {
        CaptureWalSegment {
            id: "a".repeat(32),
            sequence: 3,
            device_id: "AA:BB:CC:DD:EE:FF".to_owned(),
            audio_stream_id: "omi-AA:BB:CC-1712345678901234".to_owned(),
            encoding: encoding.to_owned(),
            framing,
            sample_rate_hz: 16_000,
            channels: 1,
            // 2026-07-23T09:15:00Z
            started_at_ms: 1_784_798_100_000,
            gap_before,
            audio_bytes: 0,
        }
    }

    fn opus_segment() -> CaptureWalSegment {
        segment("opus", CaptureWalFraming::Len16, false)
    }

    /// The on-disk shape of a `len16` segment: each Opus packet behind a
    /// big-endian uint16 length.
    fn framed(lengths: &[usize]) -> Vec<u8> {
        let mut out = Vec::new();
        for (index, length) in lengths.iter().enumerate() {
            out.extend_from_slice(&(*length as u16).to_be_bytes());
            out.extend(std::iter::repeat_n((index + 1) as u8, *length));
        }
        out
    }

    fn tag(bytes: &[u8], offset: usize, length: usize) -> String {
        String::from_utf8_lossy(&bytes[offset..offset + length]).into_owned()
    }

    fn positions(haystack: &[u8], needle: &[u8]) -> Vec<usize> {
        (0..haystack.len().saturating_sub(needle.len() - 1))
            .filter(|index| &haystack[*index..*index + needle.len()] == needle)
            .collect()
    }

    #[test]
    fn wraps_framed_opus_packets_in_an_ogg_stream() {
        let audio = framed(&[60, 57, 62]);
        let payload = capture_upload_payload(&opus_segment(), &audio)
            .unwrap_or_else(|| panic!("opus packages"));

        assert_eq!(payload.format, "ogg");
        // Three 20 ms frames round up to one second of reservable audio.
        assert_eq!(payload.duration_seconds, 1);
        assert_eq!(tag(&payload.bytes, 0, 4), "OggS");
        assert_eq!(tag(&payload.bytes, 28, 8), "OpusHead");
        assert!(payload.bytes.len() > 60 + 57 + 62);
        // The identification header declares the pendant's own mono 16 kHz
        // stream.
        assert_eq!(payload.bytes[37], 1);
        let rate = u32::from_le_bytes([
            payload.bytes[40],
            payload.bytes[41],
            payload.bytes[42],
            payload.bytes[43],
        ]);
        assert_eq!(rate, 16_000);
    }

    #[test]
    fn opens_the_comment_header_and_closes_the_stream() {
        let audio = framed(&[40, 40]);
        let payload = capture_upload_payload(&opus_segment(), &audio)
            .unwrap_or_else(|| panic!("opus packages"));

        assert!(!positions(&payload.bytes, b"OpusTags").is_empty());
        // Exactly one begin-of-stream page and one end-of-stream page.
        assert_eq!(payload.bytes[5], 0x02);
        let pages = positions(&payload.bytes, b"OggS");
        assert_eq!(pages.len(), 3);
        let last = pages[pages.len() - 1];
        assert_eq!(payload.bytes[last + 5], 0x04);
    }

    #[test]
    fn splits_a_long_opus_run_across_pages_and_ends_only_the_last() {
        // 300 packets of 60 bytes is 18 000 bytes: well past the 4 096-byte
        // page cap, so the run has to page and only the final page may carry
        // the end-of-stream flag.
        let audio = framed(&[60; 300]);
        let payload = capture_upload_payload(&opus_segment(), &audio)
            .unwrap_or_else(|| panic!("opus packages"));

        let pages = positions(&payload.bytes, b"OggS");
        assert!(pages.len() > 4, "{} pages", pages.len());
        let terminal: Vec<usize> = pages
            .iter()
            .copied()
            .filter(|start| payload.bytes[start + 5] == 0x04)
            .collect();
        assert_eq!(terminal.len(), 1);
        assert_eq!(terminal[0], pages[pages.len() - 1]);
        assert_eq!(payload.duration_seconds, 6);
    }

    #[test]
    fn wraps_pcm_in_a_wav_header_and_measures_it_from_the_sample_rate() {
        let payload = capture_upload_payload(
            &segment("pcmS16Le", CaptureWalFraming::Raw, false),
            &vec![0_u8; 32_000 * 3],
        )
        .unwrap_or_else(|| panic!("pcm packages"));

        assert_eq!(payload.format, "wav");
        assert_eq!(tag(&payload.bytes, 0, 4), "RIFF");
        assert_eq!(tag(&payload.bytes, 8, 4), "WAVE");
        assert_eq!(payload.duration_seconds, 3);
        assert_eq!(payload.bytes.len(), 32_000 * 3 + 44);
    }

    #[test]
    fn refuses_opus_written_before_the_log_recorded_frame_lengths() {
        assert!(
            capture_upload_payload(&segment("opus", CaptureWalFraming::Raw, false), &[0_u8; 64])
                .is_none()
        );
    }

    #[test]
    fn refuses_an_unknown_encoding_and_an_empty_payload() {
        assert!(
            capture_upload_payload(
                &segment("flac", CaptureWalFraming::Len16, false),
                &framed(&[20])
            )
            .is_none()
        );
        assert!(capture_upload_payload(&opus_segment(), &[]).is_none());
    }

    #[test]
    fn drops_a_truncated_tail_rather_than_failing_the_segment() {
        let mut audio = framed(&[20, 20]);
        // The last frame a killed process was mid-write on.
        audio.extend_from_slice(&[0, 40, 1, 2, 3]);
        let payload = capture_upload_payload(&opus_segment(), &audio)
            .unwrap_or_else(|| panic!("opus packages"));

        // Two whole packets survived; the partial third contributed nothing.
        assert_eq!(payload.duration_seconds, 1);
    }

    #[test]
    fn builds_the_body_the_idempotent_transcription_route_expects() {
        let segment = segment("opus", CaptureWalFraming::Len16, true);
        let audio = framed(&[50, 50]);
        let payload =
            capture_upload_payload(&segment, &audio).unwrap_or_else(|| panic!("opus packages"));
        let body = upload_body(&segment, &payload);

        assert_eq!(body["clientMessageId"], json!(segment.id));
        // The endpoint's own id rule, verified against the log's key format.
        assert!(segment.id.len() >= 8 && segment.id.len() <= 120);
        assert!(
            segment
                .id
                .chars()
                .all(|value| value.is_ascii_alphanumeric() || ".:-_".contains(value))
        );
        assert_eq!(body["format"], json!("ogg"));
        assert_eq!(body["durationSeconds"], json!(1));
        assert_eq!(body["audioStreamId"], json!(segment.audio_stream_id));
        assert_eq!(body["gapBefore"], json!(true));
        assert_eq!(body["startedAt"], json!("2026-07-23T09:15:00.000Z"));
        // The raw BLE address never leaves the phone.
        let device_id = body["deviceId"].as_str().unwrap_or_default();
        assert!(!device_id.contains("AA:BB"));
        assert_eq!(device_id.len(), 64);
        assert!(!body["audio"].as_str().unwrap_or_default().is_empty());
    }

    #[test]
    fn a_retry_under_the_same_key_replays_instead_of_charging_twice() {
        let accepted = classify(200, Some(&json!({"text": "hi"})));
        let replayed = classify(200, Some(&json!({"text": "hi", "idempotentReplay": true})));

        assert_eq!(accepted.outcome, CaptureUploadOutcome::Accepted);
        assert_eq!(replayed.outcome, CaptureUploadOutcome::Duplicate);
        assert!(accepted.done() && replayed.done());
        assert_eq!(
            classify(200, Some(&json!({"duplicate": true}))).outcome,
            CaptureUploadOutcome::Duplicate
        );
    }

    #[test]
    fn an_oversized_segment_is_rejected_rather_than_retried() {
        let result = classify(413, Some(&json!({"error": "Audio too large"})));

        assert_eq!(result.outcome, CaptureUploadOutcome::Rejected);
        assert_eq!(result.message.as_deref(), Some("Audio too large"));
    }

    #[tokio::test]
    async fn a_segment_that_cannot_be_packaged_never_reaches_the_network() {
        // An unreachable origin: a transport that tried the network here would
        // come back `Retry`, so `Rejected` is proof it never dialled.
        let transport = WorkerCaptureUploadTransport::new("https://127.0.0.1:1", "token")
            .unwrap_or_else(|| panic!("transport builds"));
        let result = transport
            .upload(&segment("opus", CaptureWalFraming::Raw, false), &[0_u8; 64])
            .await;

        assert_eq!(result.outcome, CaptureUploadOutcome::Rejected);
        assert_eq!(
            result.message.as_deref(),
            Some("Segment cannot be packaged for upload.")
        );
    }

    #[test]
    fn separates_the_two_meanings_of_409() {
        assert_eq!(
            classify(409, Some(&json!({"error": "Speech request in progress"}))).outcome,
            CaptureUploadOutcome::Retry
        );
        assert_eq!(
            classify(409, Some(&json!({"error": "Client message ID conflict"}))).outcome,
            CaptureUploadOutcome::Rejected
        );
    }

    #[test]
    fn keeps_the_audio_when_the_session_or_entitlement_is_not_there() {
        for status in [401_u16, 403, 408, 425, 429, 500, 503] {
            assert_eq!(
                classify(status, Some(&json!({"error": "no"}))).outcome,
                CaptureUploadOutcome::Retry,
                "status {status}"
            );
        }
    }

    #[test]
    fn a_bodyless_rejection_still_explains_itself() {
        let result = classify(418, None);

        assert_eq!(result.outcome, CaptureUploadOutcome::Rejected);
        assert_eq!(result.message.as_deref(), Some("Upload rejected (418)"));
    }

    #[test]
    fn a_transport_that_cannot_be_built_is_refused_rather_than_guessed() {
        assert!(WorkerCaptureUploadTransport::new("http://api.example.test", "token").is_none());
        assert!(WorkerCaptureUploadTransport::new("not a url", "token").is_none());
    }

    #[tokio::test]
    async fn the_unavailable_transport_keeps_every_segment() {
        let result = UnavailableCaptureUploadTransport
            .upload(&opus_segment(), &framed(&[20]))
            .await;

        assert_eq!(result.outcome, CaptureUploadOutcome::Retry);
        assert!(!result.done());
    }

    #[test]
    fn the_ogg_checksum_covers_the_page_with_its_own_field_zeroed() {
        let audio = framed(&[40]);
        let payload = capture_upload_payload(&opus_segment(), &audio)
            .unwrap_or_else(|| panic!("opus packages"));
        let mut page: Vec<u8> = payload.bytes[..28 + 19].to_vec();
        let stored = u32::from_le_bytes([page[22], page[23], page[24], page[25]]);
        page[22..26].copy_from_slice(&0_u32.to_le_bytes());

        assert_eq!(super::ogg_crc(&page), stored);
        assert_ne!(stored, 0);
    }
}
