//! Pure parity port of `worker/src/speech.ts`.
//!
//! Server-side speech for callers that have no in-process hub: the FaceTime /
//! Gemini Live bridge, a phone-side write-ahead log flushing buffered audio
//! after a dropout, and third-party API/MCP consumers. Both directions run as
//! OpenRouter chat completions (audio in for transcription, audio out for
//! speech), so they share one upstream shape, one AI Gateway route, and one
//! admission reservation.
//!
//! Every call is keyed by a caller-supplied `clientMessageId`: the id decides
//! identity, a completed request replays its stored result, and a retry after a
//! network drop therefore neither re-charges the account nor duplicates
//! segments. The I/O — D1, the admission Durable Object, the upstream fetch —
//! lives in the wasm glue; every decision it makes is here.

use serde_json::{json, Map, Value};

use crate::crypto_util::sha256_hex;
use crate::jsnum::{is_safe_integer, number_from_str, number_from_value};
use crate::managed_ai::{
    model_for_capability, select_model_for, ModelCapability, ModelTier, ASYNC_AUDIO_TIER_PREFERENCE,
};
use crate::public_api::{invalid, OperationResult};

pub const OPENROUTER_COMPLETION_ENDPOINT: &str = "https://openrouter.ai/api/v1/chat/completions";

// Base64 encodes 3 raw bytes as 4 characters, so a ceiling on the decoded
// audio has to be scaled by 4/3 to become a ceiling on the encoded string.
const MAXIMUM_DECODED_AUDIO_BYTES: usize = 10 * 1024 * 1024;
pub const MAXIMUM_AUDIO_BASE64_CHARS: usize = (MAXIMUM_DECODED_AUDIO_BYTES * 4).div_ceil(3);
/// Room for the base64 audio plus the small envelope around it.
pub const MAXIMUM_TRANSCRIBE_BODY_BYTES: usize = MAXIMUM_AUDIO_BASE64_CHARS + 64 * 1024;
pub const MAXIMUM_SPEAK_CHARACTERS: usize = 1_000;
/// The synthesized audio is stored so an idempotent retry can replay it, so it
/// has to stay comfortably inside a single D1 row.
pub const MAXIMUM_SPEAK_BASE64_CHARS: usize = 700_000;
pub const DEFAULT_MAXIMUM_AUDIO_SECONDS: i64 = 900;
pub const DEFAULT_TRANSCRIBE_COST_PER_MINUTE: i64 = 2_000;
pub const DEFAULT_SPEAK_COST_PER_MINUTE: i64 = 12_000;
pub const DEFAULT_UPSTREAM_TIMEOUT_MS: i64 = 120_000;
pub const MAXIMUM_UPSTREAM_TIMEOUT_MS: i64 = 300_000;

/// Bytes per second of audio, per container, used to turn an upload size into
/// the number of seconds to reserve when the caller does not declare a
/// duration. Deliberately conservative (a low bitrate reserves more seconds for
/// the same upload) so the budget is never under-charged.
const AUDIO_BYTES_PER_SECOND: &[(&str, i64)] = &[("wav", 32_000), ("mp3", 4_000), ("ogg", 4_000)];

/// `opus` is the name a caller naturally reaches for when the payload is an Ogg
/// Opus file, so it is accepted and normalised rather than refused. Upstream
/// only ever sees the container name, because that is what decides the mime
/// type the model is handed.
const TRANSCRIBE_FORMAT_ALIASES: &[(&str, &str)] = &[("opus", "ogg")];

/// Only compressed containers are offered for synthesis: the audio is retained
/// for idempotent replay, and PCM would blow the row budget in seconds.
const SPEAK_FORMATS: &[&str] = &["mp3", "opus"];
const SPEAK_VOICES: &[&str] = &[
    "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse",
];

/// Speech is spoken at roughly this rate, which converts a character budget
/// into the seconds of audio to reserve before synthesis runs.
const SPEAK_CHARACTERS_PER_SECOND: i64 = 14;

/// `{ limit, windowMs }` for the two public buckets.
pub const TRANSCRIBE_LIMIT: (i64, i64) = (10, 60_000);
pub const SPEAK_LIMIT: (i64, i64) = (20, 60_000);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SpeechKind {
    Transcribe,
    Speak,
}

impl SpeechKind {
    pub fn slug(self) -> &'static str {
        match self {
            SpeechKind::Transcribe => "transcribe",
            SpeechKind::Speak => "speak",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct TranscriptSegment {
    pub index: usize,
    pub start: Option<f64>,
    pub end: Option<f64>,
    pub text: String,
}

fn unavailable() -> OperationResult {
    OperationResult {
        status: 503,
        body: json!({ "error": "Managed speech unavailable" }),
        retry_after: None,
    }
}

/// `/^[A-Za-z0-9._:-]{8,120}$/`
pub fn is_client_message_id(value: &str) -> bool {
    let length = value.chars().count();
    (8..=120).contains(&length)
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'-'))
}

/// `/^[A-Za-z0-9+/]+={0,2}$/`
fn is_base64(value: &str) -> bool {
    let body = value.trim_end_matches('=');
    let padding = value.len() - body.len();
    padding <= 2
        && !body.is_empty()
        && body
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/')
}

/// `/^(auto|[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*)$/`
fn is_language(value: &str) -> bool {
    if value == "auto" {
        return true;
    }
    let mut parts = value.split('-');
    let Some(primary) = parts.next() else {
        return false;
    };
    if !(2..=3).contains(&primary.len()) || !primary.bytes().all(|b| b.is_ascii_lowercase()) {
        return false;
    }
    parts.all(|part| {
        (2..=8).contains(&part.len()) && part.bytes().all(|b| b.is_ascii_alphanumeric())
    })
}

/// `/^[A-Za-z0-9._:-]{1,200}$/`
fn is_provenance_id(value: &str) -> bool {
    let length = value.chars().count();
    (1..=200).contains(&length)
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'-'))
}

/// `/^\d{4}-\d{2}-\d{2}T[0-9:.]{8,15}Z$/`
fn is_timestamp(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() < 8 + 12 || bytes.len() > 15 + 12 {
        return false;
    }
    let digits = |range: std::ops::Range<usize>| bytes[range].iter().all(u8::is_ascii_digit);
    if !digits(0..4) || bytes[4] != b'-' || !digits(5..7) || bytes[7] != b'-' || !digits(8..10) {
        return false;
    }
    if bytes[10] != b'T' || *bytes.last().unwrap() != b'Z' {
        return false;
    }
    bytes[11..bytes.len() - 1]
        .iter()
        .all(|b| b.is_ascii_digit() || *b == b':' || *b == b'.')
}

fn positive_integer(value: &Value) -> Option<i64> {
    let parsed = number_from_value(value);
    (is_safe_integer(parsed) && parsed > 0.0).then_some(parsed as i64)
}

/// `configuredInteger`: the env value if positive and within `maximum`, the
/// fallback when unset, and `None` when set to something unusable.
pub fn configured_integer(value: Option<&str>, fallback: i64, maximum: i64) -> Option<i64> {
    let parsed = match value {
        None => fallback as f64,
        Some(raw) => number_from_str(raw),
    };
    (is_safe_integer(parsed) && parsed > 0.0 && parsed <= maximum as f64).then_some(parsed as i64)
}

/// The reservation id is derived rather than random so a retry of the same
/// logical request lands on the same admission slot instead of reserving a
/// second one. Byte-for-byte identical to `requestIdFor` in `speech.ts`.
pub fn request_id_for(uid: &str, kind: SpeechKind, client_message_id: &str) -> String {
    sha256_hex(&format!("speech {} {uid} {client_message_id}", kind.slug()))
}

/// How long a `'started'` row is believed to still be running. Anchored to the
/// upstream timeout rather than configured separately, so the window always
/// covers the longest call that could still be in flight, plus slack for the
/// work either side of it.
pub fn stale_started_window_ms(timeout_setting: Option<&str>) -> Option<i64> {
    configured_integer(
        timeout_setting,
        DEFAULT_UPSTREAM_TIMEOUT_MS,
        MAXIMUM_UPSTREAM_TIMEOUT_MS,
    )
    .map(|timeout| timeout + 60_000)
}

/// The stored result of a finished request, ready to replay. A `'complete'` row
/// whose payload no longer parses yields `None`, which is what makes it
/// reclaimable by the next attempt.
pub fn stored_result(status: Option<&str>, result: Option<&str>) -> Option<Map<String, Value>> {
    if status != Some("complete") {
        return None;
    }
    let parsed: Value = serde_json::from_str(result?).ok()?;
    parsed.as_object().cloned()
}

/// Optional provenance from the phone's write-ahead log: which capture stream
/// the audio belonged to, when it started, and whether a recorded discontinuity
/// immediately precedes it. It rides with the stored result rather than in
/// columns of its own, so an idempotent replay hands back exactly the
/// provenance the first attempt was given. Deliberately excluded from the
/// request hash: it describes the audio, it does not change what is billed.
///
/// Returns `None` when a supplied field is malformed, and an empty map when
/// none were supplied at all.
pub fn provenance_of(input: &Value) -> Option<Map<String, Value>> {
    let mut provenance = Map::new();
    for field in ["audioStreamId", "deviceId"] {
        match input.get(field) {
            None | Some(Value::Null) => continue,
            Some(Value::String(value)) if is_provenance_id(value) => {
                provenance.insert(field.to_string(), Value::String(value.clone()));
            }
            Some(_) => return None,
        }
    }
    match input.get("startedAt") {
        None | Some(Value::Null) => {}
        Some(Value::String(value)) if is_timestamp(value) => {
            provenance.insert("startedAt".into(), Value::String(value.clone()));
        }
        Some(_) => return None,
    }
    match input.get("gapBefore") {
        None | Some(Value::Null) => {}
        Some(Value::Bool(value)) => {
            provenance.insert("gapBefore".into(), Value::Bool(*value));
        }
        Some(_) => return None,
    }
    Some(provenance)
}

fn finite_seconds(value: Option<&Value>) -> Option<f64> {
    let raw = value?.as_f64()?;
    (raw.is_finite() && raw >= 0.0).then(|| (raw * 1000.0).round() / 1000.0)
}

/// Model output is JSON by instruction, not by contract, so a reply that is not
/// parseable as segments still yields a usable transcript: the whole text
/// becomes a single untimed segment rather than an error.
pub fn parse_segments(content: &str, fallback_end: Option<f64>) -> Vec<TranscriptSegment> {
    let trimmed = content.trim();
    let unfenced = if trimmed.starts_with("```") {
        let head = trimmed.trim_start_matches("```");
        // `/^```[a-z]*\n?/` — the language tag then an optional newline.
        let after_tag = head.trim_start_matches(|c: char| c.is_ascii_lowercase());
        let after_newline = after_tag.strip_prefix('\n').unwrap_or(after_tag);
        after_newline
            .strip_suffix("```")
            .unwrap_or(after_newline)
            .trim()
    } else {
        trimmed
    };
    if let Ok(parsed) = serde_json::from_str::<Value>(unfenced) {
        if let Some(segments) = parsed
            .as_object()
            .and_then(|object| object.get("segments"))
            .and_then(Value::as_array)
        {
            let mut mapped: Vec<TranscriptSegment> = Vec::new();
            for entry in segments {
                let Some(record) = entry.as_object() else {
                    continue;
                };
                let text = record
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim()
                    .to_string();
                if text.is_empty() {
                    continue;
                }
                mapped.push(TranscriptSegment {
                    index: mapped.len(),
                    start: finite_seconds(record.get("start")),
                    end: finite_seconds(record.get("end")),
                    text,
                });
            }
            if !mapped.is_empty() {
                return mapped;
            }
        }
    }
    if unfenced.is_empty() {
        Vec::new()
    } else {
        vec![TranscriptSegment {
            index: 0,
            start: Some(0.0),
            end: fallback_end,
            text: unfenced.to_string(),
        }]
    }
}

pub const TRANSCRIPTION_INSTRUCTION: &str = concat!(
    "Transcribe the attached audio verbatim. Reply with JSON only, no prose ",
    "and no code fences, shaped {\"segments\":[{\"start\":<seconds>,\"end\":",
    "<seconds>,\"text\":\"...\"}]}. Use one segment per utterance, in order, with ",
    "start and end in seconds from the beginning of the audio. Do not ",
    "translate, summarise, or add speaker labels that were not spoken."
);

pub const SPEAK_INSTRUCTION: &str = concat!(
    "Read the user's text aloud verbatim. Do not answer it, comment ",
    "on it, or add words of your own."
);

/// A validated transcription request: everything the glue needs to reserve,
/// call upstream, and settle.
#[derive(Clone, Debug, PartialEq)]
pub struct TranscribePlan {
    pub client_message_id: String,
    pub model: String,
    pub container: String,
    pub language: String,
    pub audio: String,
    pub declared_duration: Option<i64>,
    pub reserved_seconds: i64,
    pub estimated_cost: i64,
    pub request_hash: String,
    pub request_id: String,
    pub provenance: Map<String, Value>,
}

impl TranscribePlan {
    /// The OpenRouter chat-completions payload for this transcription.
    pub fn upstream_body(&self) -> Value {
        let instruction = if self.language == "auto" {
            TRANSCRIPTION_INSTRUCTION.to_string()
        } else {
            format!(
                "{TRANSCRIPTION_INSTRUCTION} The audio is in {}.",
                self.language
            )
        };
        json!({
            "model": self.model,
            "stream": false,
            "messages": [{
                "role": "user",
                "content": [
                    { "type": "text", "text": instruction },
                    {
                        "type": "input_audio",
                        "input_audio": { "data": self.audio, "format": self.container },
                    },
                ],
            }],
        })
    }

    /// The stored, replayable result for a successful transcription.
    pub fn result(&self, segments: &[TranscriptSegment]) -> Value {
        let mut body = Map::new();
        body.insert("requestId".into(), json!(self.request_id));
        body.insert("clientMessageId".into(), json!(self.client_message_id));
        body.insert("model".into(), json!(self.model));
        body.insert("language".into(), json!(self.language));
        body.insert("format".into(), json!(self.container));
        body.insert("durationSeconds".into(), json!(self.declared_duration));
        for (key, value) in &self.provenance {
            body.insert(key.clone(), value.clone());
        }
        body.insert(
            "text".into(),
            json!(segments
                .iter()
                .map(|segment| segment.text.as_str())
                .collect::<Vec<_>>()
                .join(" ")
                .trim()),
        );
        body.insert(
            "segments".into(),
            Value::Array(
                segments
                    .iter()
                    .map(|segment| {
                        json!({
                            "index": segment.index,
                            "start": segment.start,
                            "end": segment.end,
                            "text": segment.text,
                        })
                    })
                    .collect(),
            ),
        );
        Value::Object(body)
    }
}

/// Everything `transcribeAudioOperation` decides before it touches D1: shape
/// validation, size and duration limits, model selection by capability, and the
/// derived reservation identity.
///
/// `env` reads the same variables the TS side does. Rate limiting and the Pro
/// check happen in the glue, between validation and this plan's use, in the
/// same order as the TS: limits, then Pro, then model selection.
pub fn plan_transcription(
    env: impl Fn(&str) -> Option<String>,
    uid: &str,
    input: &Value,
    preference: &[ModelTier],
) -> Result<TranscribePlan, OperationResult> {
    let audio = input.get("audio");
    let format = input.get("format");
    let language = match input.get("language") {
        None | Some(Value::Null) => Some(Value::String("auto".into())),
        Some(value) => Some(value.clone()),
    };
    let client_message_id = input.get("clientMessageId");
    let declared_input = input.get("durationSeconds");
    let declared_duration = match declared_input {
        None | Some(Value::Null) => None,
        Some(value) => positive_integer(value),
    };
    let bad = || Err(invalid("Invalid transcription request"));

    let Some(client_message_id) = client_message_id.and_then(Value::as_str) else {
        return bad();
    };
    if !is_client_message_id(client_message_id) {
        return bad();
    }
    let Some(format) = format.and_then(Value::as_str) else {
        return bad();
    };
    let known = AUDIO_BYTES_PER_SECOND
        .iter()
        .any(|(name, _)| *name == format)
        || TRANSCRIBE_FORMAT_ALIASES
            .iter()
            .any(|(name, _)| *name == format);
    if !known {
        return bad();
    }
    let Some(language) = language
        .as_ref()
        .and_then(Value::as_str)
        .map(str::to_string)
    else {
        return bad();
    };
    if !is_language(&language) {
        return bad();
    }
    let Some(audio) = audio.and_then(Value::as_str) else {
        return bad();
    };
    if audio.is_empty() || !is_base64(audio) {
        return bad();
    }
    if !matches!(declared_input, None | Some(Value::Null)) && declared_duration.is_none() {
        return bad();
    }
    let Some(provenance) = provenance_of(input) else {
        return bad();
    };

    let container = TRANSCRIBE_FORMAT_ALIASES
        .iter()
        .find(|(name, _)| *name == format)
        .map(|(_, target)| (*target).to_string())
        .unwrap_or_else(|| format.to_string());
    let max_audio_seconds = configured_integer(
        env("SPEECH_MAX_AUDIO_SECONDS").as_deref(),
        DEFAULT_MAXIMUM_AUDIO_SECONDS,
        3600,
    );
    let cost_per_minute = configured_integer(
        env("SPEECH_TRANSCRIBE_COST_MICROUSD_PER_MINUTE").as_deref(),
        DEFAULT_TRANSCRIBE_COST_PER_MINUTE,
        10_000_000,
    );
    let (Some(max_audio_seconds), Some(cost_per_minute)) = (max_audio_seconds, cost_per_minute)
    else {
        return Err(unavailable());
    };
    if audio.len() > MAXIMUM_AUDIO_BASE64_CHARS {
        return Err(OperationResult {
            status: 413,
            body: json!({ "error": "Audio too large" }),
            retry_after: None,
        });
    }
    let decoded_bytes = (audio.len() as i64 * 3) / 4;
    let bytes_per_second = AUDIO_BYTES_PER_SECOND
        .iter()
        .find(|(name, _)| *name == container)
        .map(|(_, rate)| *rate)
        .unwrap_or(1);
    let estimated_seconds = ((decoded_bytes + bytes_per_second - 1) / bytes_per_second).max(1);
    let reserved_seconds = declared_duration.unwrap_or(0).max(estimated_seconds);
    if reserved_seconds > max_audio_seconds {
        return Err(OperationResult {
            status: 413,
            body: json!({ "error": "Audio too long" }),
            retry_after: None,
        });
    }
    // Audio in, so the model is chosen by capability rather than by tier alone:
    // the cheapest preferred tier that actually declares `audioIn` wins, and a
    // configuration where none does fails here instead of posting the audio to
    // a text-only model that would answer with a plausible invention.
    let Ok((_, model)) = select_model_for(&env, &[ModelCapability::AudioIn], preference) else {
        return Err(unavailable());
    };
    let request_hash =
        sha256_hex(&json!([model, container, language, audio.len(), reserved_seconds]).to_string());
    Ok(TranscribePlan {
        request_id: request_id_for(uid, SpeechKind::Transcribe, client_message_id),
        client_message_id: client_message_id.to_string(),
        model,
        container,
        language,
        audio: audio.to_string(),
        declared_duration,
        reserved_seconds,
        estimated_cost: ((reserved_seconds * cost_per_minute) + 59) / 60,
        request_hash,
        provenance,
    })
}

/// The default preference list for asynchronous audio.
pub fn default_transcribe_preference() -> &'static [ModelTier] {
    ASYNC_AUDIO_TIER_PREFERENCE
}

#[derive(Clone, Debug, PartialEq)]
pub struct SpeakPlan {
    pub client_message_id: String,
    pub model: String,
    pub voice: String,
    pub format: String,
    pub spoken: String,
    pub reserved_seconds: i64,
    pub estimated_cost: i64,
    pub request_hash: String,
    pub request_id: String,
}

impl SpeakPlan {
    pub fn upstream_body(&self) -> Value {
        json!({
            "model": self.model,
            "stream": false,
            "modalities": ["text", "audio"],
            "audio": { "voice": self.voice, "format": self.format },
            "messages": [
                { "role": "system", "content": SPEAK_INSTRUCTION },
                { "role": "user", "content": self.spoken },
            ],
        })
    }

    pub fn result(&self, audio: &str) -> Value {
        json!({
            "requestId": self.request_id,
            "clientMessageId": self.client_message_id,
            "model": self.model,
            "voice": self.voice,
            "format": self.format,
            "characters": self.spoken.encode_utf16().count(),
            "estimatedSeconds": self.reserved_seconds,
            "audio": audio,
        })
    }
}

pub fn plan_speech(
    env: impl Fn(&str) -> Option<String>,
    uid: &str,
    input: &Value,
) -> Result<SpeakPlan, OperationResult> {
    let bad = || Err(invalid("Invalid speech request"));
    let text = input.get("text");
    let format = match input.get("format") {
        None | Some(Value::Null) => Value::String("mp3".into()),
        Some(value) => value.clone(),
    };
    let voice = match input.get("voice") {
        None | Some(Value::Null) => Value::String("alloy".into()),
        Some(value) => value.clone(),
    };
    let Some(client_message_id) = input.get("clientMessageId").and_then(Value::as_str) else {
        return bad();
    };
    if !is_client_message_id(client_message_id) {
        return bad();
    }
    let Some(text) = text.and_then(Value::as_str) else {
        return bad();
    };
    if text.trim().is_empty() {
        return bad();
    }
    let Some(format) = format.as_str() else {
        return bad();
    };
    if !SPEAK_FORMATS.contains(&format) {
        return bad();
    }
    let Some(voice) = voice.as_str() else {
        return bad();
    };
    if !SPEAK_VOICES.contains(&voice) {
        return bad();
    }
    if text.encode_utf16().count() > MAXIMUM_SPEAK_CHARACTERS {
        return Err(OperationResult {
            status: 413,
            body: json!({ "error": "Text too long" }),
            retry_after: None,
        });
    }
    let Some(cost_per_minute) = configured_integer(
        env("SPEECH_SPEAK_COST_MICROUSD_PER_MINUTE").as_deref(),
        DEFAULT_SPEAK_COST_PER_MINUTE,
        10_000_000,
    ) else {
        return Err(unavailable());
    };
    let spoken = text.trim().to_string();
    let reserved_seconds = (((spoken.encode_utf16().count() as i64) + SPEAK_CHARACTERS_PER_SECOND
        - 1)
        / SPEAK_CHARACTERS_PER_SECOND)
        .max(1);
    let Ok(model) = model_for_capability(&env, ModelTier::Speak, &[ModelCapability::AudioOut])
    else {
        return Err(unavailable());
    };
    let request_hash = sha256_hex(&json!([model, format, voice, spoken]).to_string());
    Ok(SpeakPlan {
        request_id: request_id_for(uid, SpeechKind::Speak, client_message_id),
        client_message_id: client_message_id.to_string(),
        model,
        voice: voice.to_string(),
        format: format.to_string(),
        spoken,
        reserved_seconds,
        estimated_cost: ((reserved_seconds * cost_per_minute) + 59) / 60,
        request_hash,
    })
}

/// `messageOf`: the first choice's message object.
pub fn message_of(body: &Value) -> Option<&Map<String, Value>> {
    body.get("choices")?
        .as_array()?
        .first()?
        .as_object()?
        .get("message")?
        .as_object()
}

/// The three outcomes `reserve` resolves before any upstream call runs, given
/// the existing row for this `(uid, kind, clientMessageId)`.
#[derive(Clone, Debug, PartialEq)]
pub enum ReservationDecision {
    /// Nothing recorded, or a `'failed'` row: this attempt owns the slot.
    Fresh { reclaims: bool },
    /// A finished request replays its stored result verbatim.
    Replay(Map<String, Value>),
    /// The same id carrying a different payload, or an attempt still running.
    Refuse(OperationResult),
}

/// `reserve`'s pre-admission branch, made testable. `existing` is the row's
/// `(status, request_hash, result, updated_at)` or `None`.
pub fn decide_reservation(
    existing: Option<(&str, &str, Option<&str>, i64)>,
    request_hash: &str,
    stale_after_ms: Option<i64>,
    now: i64,
) -> ReservationDecision {
    let Some((status, stored_hash, result, updated_at)) = existing else {
        return ReservationDecision::Fresh { reclaims: false };
    };
    if stored_hash != request_hash {
        return ReservationDecision::Refuse(OperationResult {
            status: 409,
            body: json!({ "error": "Client message ID conflict" }),
            retry_after: None,
        });
    }
    if let Some(replay) = stored_result(Some(status), result) {
        let mut body = replay;
        body.insert("idempotentReplay".into(), Value::Bool(true));
        return ReservationDecision::Replay(body);
    }
    // An isolate evicted between the insert and `settle` leaves the row
    // 'started' with nothing left to finish it, so a row that has sat there
    // longer than any request could legitimately take is reclaimable — without
    // that, the caller's id would be wedged for good. A 'complete' row whose
    // stored result no longer parses is reclaimable immediately: it can neither
    // be replayed nor settled, so the next attempt has to be allowed to own it.
    if status == "started" && stale_after_ms.map(|window| now - updated_at < window) != Some(false)
    {
        return ReservationDecision::Refuse(OperationResult {
            status: 409,
            body: json!({ "error": "Speech request in progress" }),
            retry_after: None,
        });
    }
    ReservationDecision::Fresh {
        reclaims: status != "failed",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        let owned: Vec<(String, String)> = pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect();
        move |name: &str| {
            owned
                .iter()
                .find(|(key, _)| key == name)
                .map(|(_, value)| value.clone())
        }
    }

    #[test]
    fn reservation_id_matches_the_typescript_derivation() {
        // SHA-256("speech transcribe uid-1 cm-000001").
        assert_eq!(
            request_id_for("uid-1", SpeechKind::Transcribe, "cm-000001"),
            sha256_hex("speech transcribe uid-1 cm-000001")
        );
        assert_ne!(
            request_id_for("uid-1", SpeechKind::Transcribe, "cm-000001"),
            request_id_for("uid-1", SpeechKind::Speak, "cm-000001")
        );
        assert_ne!(
            request_id_for("uid-1", SpeechKind::Speak, "cm-000001"),
            request_id_for("uid-2", SpeechKind::Speak, "cm-000001")
        );
        assert_eq!(
            request_id_for("uid-1", SpeechKind::Speak, "cm-000001").len(),
            64
        );
    }

    fn transcribe_input() -> Value {
        json!({
            "clientMessageId": "cm-000001",
            "format": "opus",
            "audio": "AAAA",
        })
    }

    #[test]
    fn normalises_the_opus_alias_to_the_ogg_container() {
        let plan = plan_transcription(
            env(&[]),
            "uid-1",
            &transcribe_input(),
            ASYNC_AUDIO_TIER_PREFERENCE,
        )
        .unwrap();
        assert_eq!(plan.container, "ogg");
        assert_eq!(plan.language, "auto");
        assert_eq!(plan.model, "xiaomi/mimo-v2.5");
        assert_eq!(plan.reserved_seconds, 1);
    }

    #[test]
    fn refuses_every_malformed_transcription_shape() {
        for input in [
            json!({ "format": "wav", "audio": "AAAA" }),
            json!({ "clientMessageId": "short", "format": "wav", "audio": "AAAA" }),
            json!({ "clientMessageId": "cm-000001", "format": "flac", "audio": "AAAA" }),
            json!({ "clientMessageId": "cm-000001", "format": "wav", "audio": "" }),
            json!({ "clientMessageId": "cm-000001", "format": "wav", "audio": "not base64!" }),
            json!({ "clientMessageId": "cm-000001", "format": "wav", "audio": "AAAA", "language": "english" }),
            json!({ "clientMessageId": "cm-000001", "format": "wav", "audio": "AAAA", "durationSeconds": 0 }),
            json!({ "clientMessageId": "cm-000001", "format": "wav", "audio": "AAAA", "durationSeconds": "twelve" }),
            json!({ "clientMessageId": "cm-000001", "format": "wav", "audio": "AAAA", "deviceId": 7 }),
            json!({ "clientMessageId": "cm-000001", "format": "wav", "audio": "AAAA", "gapBefore": "yes" }),
            json!({ "clientMessageId": "cm-000001", "format": "wav", "audio": "AAAA", "startedAt": "2026-07-23" }),
        ] {
            let outcome =
                plan_transcription(env(&[]), "uid-1", &input, ASYNC_AUDIO_TIER_PREFERENCE);
            assert_eq!(
                outcome.err().map(|result| result.status),
                Some(400),
                "should refuse {input}"
            );
        }
    }

    #[test]
    fn a_string_duration_coerces_the_way_number_does() {
        let mut input = transcribe_input();
        input["durationSeconds"] = json!("12");
        let plan =
            plan_transcription(env(&[]), "uid-1", &input, ASYNC_AUDIO_TIER_PREFERENCE).unwrap();
        assert_eq!(plan.declared_duration, Some(12));
        assert_eq!(plan.reserved_seconds, 12);
    }

    #[test]
    fn provenance_rides_with_the_stored_result_but_not_the_hash() {
        let plain = plan_transcription(
            env(&[]),
            "uid-1",
            &transcribe_input(),
            ASYNC_AUDIO_TIER_PREFERENCE,
        )
        .unwrap();
        let mut input = transcribe_input();
        input["deviceId"] = json!("pendant-1");
        input["startedAt"] = json!("2026-07-23T10:00:00.000Z");
        input["gapBefore"] = json!(true);
        let annotated =
            plan_transcription(env(&[]), "uid-1", &input, ASYNC_AUDIO_TIER_PREFERENCE).unwrap();
        assert_eq!(annotated.request_hash, plain.request_hash);
        let result = annotated.result(&[]);
        assert_eq!(result["deviceId"], json!("pendant-1"));
        assert_eq!(result["gapBefore"], json!(true));
    }

    #[test]
    fn oversized_and_overlong_audio_are_413() {
        let mut input = transcribe_input();
        input["audio"] = json!("A".repeat(MAXIMUM_AUDIO_BASE64_CHARS + 1));
        assert_eq!(
            plan_transcription(env(&[]), "uid-1", &input, ASYNC_AUDIO_TIER_PREFERENCE)
                .err()
                .map(|result| result.status),
            Some(413)
        );
        let mut input = transcribe_input();
        // 4 000 bytes per second of ogg, capped at 10 seconds by the override.
        input["audio"] = json!("A".repeat(4 * 4_000 * 20));
        assert_eq!(
            plan_transcription(
                env(&[("SPEECH_MAX_AUDIO_SECONDS", "10")]),
                "uid-1",
                &input,
                ASYNC_AUDIO_TIER_PREFERENCE
            )
            .err()
            .map(|result| result.status),
            Some(413)
        );
    }

    #[test]
    fn an_override_that_leaves_no_audio_capable_tier_is_503() {
        let outcome = plan_transcription(
            env(&[
                ("OMI_MODEL_BALANCED", "vendor/text-only"),
                ("OMI_MODEL_TRANSCRIBE", "vendor/text-only"),
                ("OMI_MODEL_MULTIMODAL", "vendor/text-only"),
            ]),
            "uid-1",
            &transcribe_input(),
            ASYNC_AUDIO_TIER_PREFERENCE,
        );
        assert_eq!(outcome.err().map(|result| result.status), Some(503));
    }

    #[test]
    fn a_declared_override_can_restore_the_audio_capable_tier() {
        let plan = plan_transcription(
            env(&[
                ("OMI_MODEL_BALANCED", "vendor/ears"),
                (
                    "OMI_MODEL_CAPABILITIES",
                    r#"{"vendor/ears":["text","audioIn"]}"#,
                ),
            ]),
            "uid-1",
            &transcribe_input(),
            ASYNC_AUDIO_TIER_PREFERENCE,
        )
        .unwrap();
        assert_eq!(plan.model, "vendor/ears");
    }

    #[test]
    fn speech_synthesis_validates_and_prices_by_characters() {
        let plan = plan_speech(
            env(&[]),
            "uid-1",
            &json!({ "clientMessageId": "cm-000001", "text": "  hello there  " }),
        )
        .unwrap();
        assert_eq!(plan.spoken, "hello there");
        assert_eq!(plan.format, "mp3");
        assert_eq!(plan.voice, "alloy");
        assert_eq!(plan.model, "openai/gpt-audio-mini");
        assert_eq!(plan.reserved_seconds, 1);
        assert_eq!(plan.estimated_cost, 200);
        for input in [
            json!({ "text": "hi" }),
            json!({ "clientMessageId": "cm-000001", "text": "   " }),
            json!({ "clientMessageId": "cm-000001", "text": "hi", "format": "wav" }),
            json!({ "clientMessageId": "cm-000001", "text": "hi", "voice": "brian" }),
        ] {
            assert_eq!(
                plan_speech(env(&[]), "uid-1", &input)
                    .err()
                    .map(|result| result.status),
                Some(400),
                "should refuse {input}"
            );
        }
        assert_eq!(
            plan_speech(
                env(&[]),
                "uid-1",
                &json!({
                    "clientMessageId": "cm-000001",
                    "text": "a".repeat(MAXIMUM_SPEAK_CHARACTERS + 1),
                })
            )
            .err()
            .map(|result| result.status),
            Some(413)
        );
    }

    #[test]
    fn a_speak_tier_without_audio_out_is_503() {
        assert_eq!(
            plan_speech(
                env(&[("OMI_MODEL_SPEAK", "xiaomi/mimo-v2.5")]),
                "uid-1",
                &json!({ "clientMessageId": "cm-000001", "text": "hi" })
            )
            .err()
            .map(|result| result.status),
            Some(503)
        );
    }

    #[test]
    fn segments_parse_from_json_fenced_json_and_prose() {
        let parsed = parse_segments(
            r#"```json
{"segments":[{"start":0,"end":1.2345,"text":" one "},{"text":""},{"start":2,"text":"two"}]}
```"#,
            None,
        );
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].text, "one");
        assert_eq!(parsed[0].end, Some(1.235));
        assert_eq!(parsed[1].index, 1);
        assert_eq!(parsed[1].end, None);

        let prose = parse_segments("just words", Some(12.0));
        assert_eq!(prose.len(), 1);
        assert_eq!(prose[0].text, "just words");
        assert_eq!(prose[0].start, Some(0.0));
        assert_eq!(prose[0].end, Some(12.0));

        assert!(parse_segments("   ", None).is_empty());
        // A well-formed envelope with no usable segments falls back to prose.
        let empty = parse_segments(r#"{"segments":[]}"#, None);
        assert_eq!(empty.len(), 1);
    }

    #[test]
    fn a_finished_request_replays_and_a_running_one_is_refused() {
        let stored = r#"{"requestId":"r","text":"hi"}"#;
        assert_eq!(
            decide_reservation(Some(("complete", "h", Some(stored), 0)), "h", Some(1), 10),
            ReservationDecision::Replay(
                serde_json::from_str::<Map<String, Value>>(
                    r#"{"requestId":"r","text":"hi","idempotentReplay":true}"#
                )
                .unwrap()
            )
        );
        assert!(matches!(
            decide_reservation(Some(("started", "h", None, 100)), "h", Some(1_000), 200),
            ReservationDecision::Refuse(result) if result.status == 409
        ));
        // The same id carrying a different payload never replays.
        assert!(matches!(
            decide_reservation(Some(("complete", "other", Some(stored), 0)), "h", Some(1), 10),
            ReservationDecision::Refuse(result) if result.status == 409
        ));
        // Abandoned past the staleness window: reclaimable.
        assert_eq!(
            decide_reservation(Some(("started", "h", None, 0)), "h", Some(1_000), 2_000),
            ReservationDecision::Fresh { reclaims: true }
        );
        // A 'complete' row whose payload no longer parses is reclaimable now.
        assert_eq!(
            decide_reservation(Some(("complete", "h", Some("{"), 0)), "h", Some(1_000), 1),
            ReservationDecision::Fresh { reclaims: true }
        );
        assert_eq!(
            decide_reservation(Some(("failed", "h", None, 0)), "h", Some(1_000), 1),
            ReservationDecision::Fresh { reclaims: false }
        );
        assert_eq!(
            decide_reservation(None, "h", Some(1_000), 1),
            ReservationDecision::Fresh { reclaims: false }
        );
        // An unusable timeout setting leaves no window, so a 'started' row is
        // believed to still be running forever rather than reclaimed early.
        assert!(matches!(
            decide_reservation(Some(("started", "h", None, 0)), "h", None, 1_000_000),
            ReservationDecision::Refuse(result) if result.status == 409
        ));
    }

    #[test]
    fn the_stale_window_follows_the_configured_upstream_timeout() {
        assert_eq!(stale_started_window_ms(None), Some(180_000));
        assert_eq!(stale_started_window_ms(Some("1000")), Some(61_000));
        assert_eq!(stale_started_window_ms(Some("0")), None);
        assert_eq!(stale_started_window_ms(Some("400000")), None);
        assert_eq!(stale_started_window_ms(Some("nonsense")), None);
    }
}
