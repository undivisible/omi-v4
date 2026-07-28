use base64::{Engine as _, engine::general_purpose::STANDARD};
use std::time::Duration;

use super::models::VisualCaption;

pub const DESCRIPTION_VERSION: u32 = 1;
pub const MAXIMUM_IMAGE_BYTES: usize = 2 * 1024 * 1024;
const MAXIMUM_CAPTION_CHARS: usize = 280;
const CLOUD_TIMEOUT: Duration = Duration::from_secs(10);
const CLOUD_MODEL: &str = "mimo-v2.5";
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LocalVisualAvailability {
    Unavailable,
}

pub const fn local_visual_availability() -> LocalVisualAvailability {
    LocalVisualAvailability::Unavailable
}

pub async fn describe_in_cloud(endpoint: &str, credential: &str, image: &[u8]) -> Option<String> {
    if image.is_empty()
        || image.len() > MAXIMUM_IMAGE_BYTES
        || credential.is_empty()
        || credential.bytes().any(|byte| byte.is_ascii_control())
    {
        return None;
    }
    let response = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(3))
        .timeout(CLOUD_TIMEOUT)
        .build()
        .ok()?
        .post(format!(
            "{}/rewind/describe",
            endpoint.trim_end_matches('/')
        ))
        .bearer_auth(credential)
        .json(&request_body(image))
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    let value: serde_json::Value = response.json().await.ok()?;
    let text = value.get("text")?.as_str()?;
    (value.get("source")?.as_str()? == cloud_source()
        && value.get("model")?.as_str()? == cloud_model()
        && usable_caption(text))
    .then(|| text.trim().to_owned())
}

pub fn request_body(image: &[u8]) -> serde_json::Value {
    serde_json::json!({
        "imageBase64": STANDARD.encode(image),
        "mimeType": "image/jpeg",
    })
}

pub fn caption(text: String, source: &str, model: &str, described_at_ms: i64) -> VisualCaption {
    VisualCaption {
        text,
        source: source.to_owned(),
        model: model.to_owned(),
        description_version: DESCRIPTION_VERSION,
        described_at_ms,
    }
}

pub const fn cloud_source() -> &'static str {
    "cloud_mimo_v2_5"
}

pub const fn cloud_model() -> &'static str {
    CLOUD_MODEL
}

fn usable_caption(value: &str) -> bool {
    let value = value.trim();
    (8..=MAXIMUM_CAPTION_CHARS).contains(&value.chars().count())
        && value.chars().any(char::is_alphabetic)
}

#[cfg(test)]
mod tests {
    use super::{LocalVisualAvailability, local_visual_availability, request_body};

    #[test]
    fn local_visual_is_deterministically_unavailable() {
        assert_eq!(
            local_visual_availability(),
            LocalVisualAvailability::Unavailable
        );
    }

    #[test]
    fn cloud_request_has_only_bounded_image_input() {
        let body = request_body(&[0xff, 0xd8, 0xff]);
        assert_eq!(body.as_object().map(|object| object.len()), Some(2));
        assert_eq!(body["mimeType"], "image/jpeg");
    }
}
