//! @generated from config/model-tiers.json — do not edit; run scripts/sync-model-tiers.ts

use super::ModelCapability;
use super::ModelCapability::{AudioIn, AudioOut, ImageIn, Text};

pub const DEFAULT_SPEED_MODEL: &str = "inception/mercury-2";
pub const DEFAULT_BALANCED_MODEL: &str = "xiaomi/mimo-v2.5";
pub const DEFAULT_SMART_MODEL: &str = "xiaomi/mimo-v2.5-pro";
pub const DEFAULT_MULTIMODAL_MODEL: &str = "google/gemini-2.5-flash-lite";
pub const DEFAULT_SEARCH_MODEL: &str = "perplexity/sonar";
pub const DEFAULT_TRANSCRIBE_MODEL: &str = "x-ai/grok-stt-1.0";
pub const DEFAULT_SPEAK_MODEL: &str = "openai/gpt-audio-mini";

pub const MODEL_CAPABILITIES: &[(&str, &[ModelCapability])] = &[
    ("xiaomi/mimo-v2.5", &[Text, AudioIn]),
    ("xiaomi/mimo-v2.5-pro", &[Text]),
    ("inception/mercury-2", &[Text]),
    ("perplexity/sonar", &[Text]),
    ("google/gemini-2.5-flash-lite", &[Text, AudioIn, ImageIn]),
    ("google/gemini-3.5-flash-lite", &[Text, AudioIn]),
    ("x-ai/grok-stt-1.0", &[AudioIn]),
    ("openai/gpt-audio-mini", &[Text, AudioOut]),
];
