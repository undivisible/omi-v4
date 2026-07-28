use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde_json::{json, Value};

pub const MODEL: &str = "mimo-v2.5";
pub const MAXIMUM_IMAGE_BYTES: usize = 2 * 1024 * 1024;
pub const MAXIMUM_CAPTION_CHARS: usize = 280;
pub const MAXIMUM_OUTPUT_TOKENS: i64 = 128;
pub const REQUEST_TIMEOUT_MS: i64 = 15_000;
const PROMPT: &str = "Describe this image factually in one short sentence. State only clearly visible people, objects, actions, and setting. Do not infer identities, emotions, intent, or sensitive traits.";

#[derive(Debug, PartialEq)]
pub enum Outcome {
    Ok(Image),
    TooLarge,
    Invalid,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Image {
    pub base64: String,
    pub mime_type: String,
    pub bytes: usize,
}

pub fn maximum_base64_chars() -> usize {
    (MAXIMUM_IMAGE_BYTES * 4).div_ceil(3)
}

pub fn maximum_body_bytes() -> usize {
    maximum_base64_chars() + 1024
}

pub fn classify(body: &Value) -> Outcome {
    let Some(object) = body.as_object() else {
        return Outcome::Invalid;
    };
    if object.len() != 2 {
        return Outcome::Invalid;
    }
    let Some(base64) = object.get("imageBase64").and_then(Value::as_str) else {
        return Outcome::Invalid;
    };
    if base64.len() > maximum_base64_chars() {
        return Outcome::TooLarge;
    }
    let Some(mime_type) = object.get("mimeType").and_then(Value::as_str) else {
        return Outcome::Invalid;
    };
    if !matches!(mime_type, "image/jpeg" | "image/png") || base64.is_empty() {
        return Outcome::Invalid;
    }
    let Ok(decoded) = STANDARD.decode(base64) else {
        return Outcome::Invalid;
    };
    if decoded.is_empty() {
        return Outcome::Invalid;
    }
    if decoded.len() > MAXIMUM_IMAGE_BYTES {
        return Outcome::TooLarge;
    }
    let matches_type = match mime_type {
        "image/jpeg" => decoded.starts_with(&[0xff, 0xd8, 0xff]),
        "image/png" => decoded.starts_with(b"\x89PNG\r\n\x1a\n"),
        _ => false,
    };
    if !matches_type {
        return Outcome::Invalid;
    }
    Outcome::Ok(Image {
        base64: base64.to_owned(),
        mime_type: mime_type.to_owned(),
        bytes: decoded.len(),
    })
}

pub fn upstream_body(image: &Image) -> Value {
    json!({
        "model": MODEL,
        "messages": [{
            "role": "user",
            "content": [
                { "type": "text", "text": PROMPT },
                { "type": "image_url", "image_url": { "url": format!("data:{};base64,{}", image.mime_type, image.base64) } }
            ]
        }],
        "stream": false,
        "max_tokens": MAXIMUM_OUTPUT_TOKENS,
        "temperature": 0
    })
}

pub fn parse_caption(value: &Value) -> Option<String> {
    let caption = value
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|choices| choices.first())
        .and_then(|choice| choice.get("message"))
        .and_then(|message| message.get("content"))
        .and_then(Value::as_str)?
        .trim();
    if caption.is_empty() || caption.chars().count() > MAXIMUM_CAPTION_CHARS {
        return None;
    }
    Some(caption.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn jpeg() -> String {
        STANDARD.encode([0xff, 0xd8, 0xff, 0xdb])
    }

    #[test]
    fn rejects_malformed_oversize_and_non_images_before_upstream() {
        assert_eq!(classify(&json!({})), Outcome::Invalid);
        assert_eq!(
            classify(&json!({ "imageBase64": "not base64", "mimeType": "image/jpeg" })),
            Outcome::Invalid
        );
        assert_eq!(
            classify(
                &json!({ "imageBase64": STANDARD.encode(b"not an image"), "mimeType": "image/jpeg" })
            ),
            Outcome::Invalid
        );
        assert_eq!(
            classify(
                &json!({ "imageBase64": "A".repeat(maximum_base64_chars() + 1), "mimeType": "image/jpeg" })
            ),
            Outcome::TooLarge
        );
    }

    #[test]
    fn fixed_mimo_request_cannot_take_a_caller_prompt_or_model() {
        let Outcome::Ok(image) =
            classify(&json!({ "imageBase64": jpeg(), "mimeType": "image/jpeg" }))
        else {
            panic!("expected image");
        };
        let body = upstream_body(&image);
        assert_eq!(body["model"], MODEL);
        assert_eq!(body["max_tokens"], MAXIMUM_OUTPUT_TOKENS);
        assert_eq!(body["temperature"], 0);
        assert_eq!(
            body["messages"][0]["content"][1]["image_url"]["url"],
            format!("data:image/jpeg;base64,{}", jpeg())
        );
        assert!(body["messages"][0]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("factually"));
    }

    #[test]
    fn accepts_only_nonempty_bounded_captions() {
        assert_eq!(
            parse_caption(
                &json!({ "choices": [{ "message": { "content": " A desk and a laptop. " }}] })
            )
            .as_deref(),
            Some("A desk and a laptop.")
        );
        assert_eq!(
            parse_caption(&json!({ "choices": [{ "message": { "content": "  " }}] })),
            None
        );
        assert_eq!(
            parse_caption(
                &json!({ "choices": [{ "message": { "content": "x".repeat(MAXIMUM_CAPTION_CHARS + 1) }}] })
            ),
            None
        );
    }
}
