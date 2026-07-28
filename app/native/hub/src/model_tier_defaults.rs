//! @generated from config/model-tiers.json — do not edit; run scripts/sync-model-tiers.ts

use super::Capability;

pub(crate) const DEFAULT_SPEED_MODEL: &str = "inception/mercury-2";
pub(crate) const DEFAULT_BALANCED_MODEL: &str = "xiaomi/mimo-v2.5";
pub(crate) const DEFAULT_SMART_MODEL: &str = "xiaomi/mimo-v2.5-pro";
pub(crate) const DEFAULT_MULTIMODAL_MODEL: &str = "google/gemini-3.6-flash";
pub(crate) const DEFAULT_SEARCH_MODEL: &str = "perplexity/sonar";
pub(crate) const DEFAULT_TRANSCRIBE_MODEL: &str = "google/gemini-3.5-flash-lite";
pub(crate) const DEFAULT_SPEAK_MODEL: &str = "openai/gpt-audio-mini";

pub(crate) const MODEL_CAPABILITIES: &[(&str, &[Capability])] = &[
    (
        "xiaomi/mimo-v2.5",
        &[Capability::Text, Capability::AudioIn, Capability::ImageIn],
    ),
    ("xiaomi/mimo-v2.5-pro", &[Capability::Text]),
    ("inception/mercury-2", &[Capability::Text]),
    ("perplexity/sonar", &[Capability::Text]),
    (
        "google/gemini-3.6-flash",
        &[Capability::Text, Capability::AudioIn, Capability::ImageIn],
    ),
    (
        "google/gemini-3.5-flash-lite",
        &[Capability::Text, Capability::AudioIn],
    ),
    (
        "openai/gpt-audio-mini",
        &[Capability::Text, Capability::AudioOut],
    ),
];
