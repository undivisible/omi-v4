//! Pure port of the ASR proxy validation and upstream-body shaping in
//! `worker/src/asr.ts`. The fetch/ledger plumbing is glue; the size caps,
//! format/language allow-lists and request construction are here.

use serde_json::{json, Value};

pub const ASR_MODEL: &str = "mimo-v2.5-asr";
pub const MAXIMUM_DECODED_AUDIO_BYTES: usize = 10 * 1024 * 1024;

/// `Math.ceil((maximumDecodedAudioBytes * 4) / 3)`.
pub fn maximum_audio_base64_chars() -> usize {
    (MAXIMUM_DECODED_AUDIO_BYTES * 4).div_ceil(3)
}

/// `maximumAudioBase64Chars + 64 * 1024`.
pub fn maximum_body_bytes() -> usize {
    maximum_audio_base64_chars() + 64 * 1024
}

const FORMATS: &[&str] = &["wav", "mp3"];
const LANGUAGES: &[&str] = &["auto", "zh", "en"];

#[derive(Clone, Debug, PartialEq)]
pub struct AsrRequest {
    pub audio: String,
    pub format: String,
    pub language: Option<String>,
}

/// The classification outcome of a transcribe request body.
#[derive(Debug, PartialEq)]
pub enum AsrOutcome {
    Ok(AsrRequest),
    /// 413 Audio too large.
    TooLarge,
    /// 400 Invalid request.
    Invalid,
}

/// `Number.isFinite(declared) && declared > maximumBodyBytes` → too large.
pub fn declared_length_exceeds(content_length: Option<&str>) -> bool {
    match content_length {
        Some(raw) => {
            let n = crate::jsnum::number_from_str(raw);
            n.is_finite() && n > maximum_body_bytes() as f64
        }
        None => false,
    }
}

/// Port of the body validation after `boundedJson`. Ordering matches the TS:
/// the base64 char-cap (413) is checked before the shape validation (400).
pub fn classify(body: &Value) -> AsrOutcome {
    let obj = match body.as_object() {
        Some(o) => o,
        None => return AsrOutcome::Invalid,
    };
    let audio = obj.get("audio");
    let format = obj.get("format");
    let language = obj.get("language");

    if let Some(Value::String(s)) = audio {
        if s.chars().count() > maximum_audio_base64_chars() {
            return AsrOutcome::TooLarge;
        }
    }

    let audio_ok = matches!(audio, Some(Value::String(s)) if !s.is_empty());
    let format_ok = matches!(format, Some(Value::String(s)) if FORMATS.contains(&s.as_str()));
    let language_ok = match language {
        None => true,
        Some(Value::String(s)) => LANGUAGES.contains(&s.as_str()),
        Some(_) => false,
    };
    if !audio_ok || !format_ok || !language_ok {
        return AsrOutcome::Invalid;
    }

    AsrOutcome::Ok(AsrRequest {
        audio: audio.unwrap().as_str().unwrap().to_string(),
        format: format.unwrap().as_str().unwrap().to_string(),
        language: language.and_then(Value::as_str).map(str::to_string),
    })
}

/// Port of the upstream request body for the pinned MiMo ASR endpoint.
pub fn upstream_body(request: &AsrRequest) -> Value {
    let mut body = json!({
        "model": ASR_MODEL,
        "messages": [{
            "role": "user",
            "content": [{
                "type": "input_audio",
                "input_audio": { "data": request.audio, "format": request.format }
            }]
        }],
        "stream": false,
    });
    if let Some(language) = &request.language {
        body.as_object_mut()
            .unwrap()
            .insert("asr_options".into(), json!({ "language": language }));
    }
    body
}

/// Port of the completion parse: `choices[0].message.content` when a string.
pub fn parse_transcript(value: &Value) -> Option<String> {
    value
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|c| c.first())
        .and_then(|c| c.get("message"))
        .and_then(|m| m.get("content"))
        .and_then(Value::as_str)
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_cap_matches_ts() {
        assert_eq!(maximum_audio_base64_chars(), (10 * 1024 * 1024 * 4usize).div_ceil(3));
    }

    #[test]
    fn rejects_oversized_declared_length() {
        assert!(declared_length_exceeds(Some(&(maximum_body_bytes() + 1).to_string())));
        assert!(!declared_length_exceeds(Some("100")));
        assert!(!declared_length_exceeds(None));
    }

    #[test]
    fn classifies_size_before_shape() {
        let big = "A".repeat(maximum_audio_base64_chars() + 1);
        assert_eq!(classify(&json!({ "audio": big, "format": "wav" })), AsrOutcome::TooLarge);
    }

    #[test]
    fn rejects_disallowed_format_and_language() {
        assert_eq!(classify(&json!({ "audio": "QUJD", "format": "flac" })), AsrOutcome::Invalid);
        assert_eq!(
            classify(&json!({ "audio": "QUJD", "format": "wav", "language": "de" })),
            AsrOutcome::Invalid
        );
        assert_eq!(classify(&json!({ "audio": "", "format": "wav" })), AsrOutcome::Invalid);
    }

    #[test]
    fn builds_pinned_upstream_body() {
        let outcome = classify(&json!({ "audio": "QUJD", "format": "mp3", "language": "zh" }));
        let AsrOutcome::Ok(request) = outcome else {
            panic!("expected ok");
        };
        let body = upstream_body(&request);
        assert_eq!(body["model"], json!("mimo-v2.5-asr"));
        assert_eq!(body["stream"], json!(false));
        assert_eq!(body["asr_options"], json!({ "language": "zh" }));
        assert_eq!(
            body["messages"][0]["content"][0],
            json!({ "type": "input_audio", "input_audio": { "data": "QUJD", "format": "mp3" } })
        );
    }

    #[test]
    fn omits_asr_options_without_language() {
        let AsrOutcome::Ok(request) = classify(&json!({ "audio": "QUJD", "format": "wav" })) else {
            panic!("expected ok");
        };
        let body = upstream_body(&request);
        assert!(body.get("asr_options").is_none());
    }

    #[test]
    fn parses_transcript() {
        let value = json!({ "choices": [{ "message": { "content": "hello 世界" } }] });
        assert_eq!(parse_transcript(&value).as_deref(), Some("hello 世界"));
        assert_eq!(parse_transcript(&json!({ "choices": [] })), None);
    }
}
