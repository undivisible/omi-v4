//! Model-tier routing config. Defaults and capability tables are generated from
//! `config/model-tiers.json` via `scripts/sync-model-tiers.ts`; the worker
//! imports the same JSON at runtime. All three read the same `OMI_MODEL_*`
//! environment variables with the same defaults.
//!
//! | Tier         | When                                                      | Default model           | Provider |
//! |--------------|-----------------------------------------------------------|-------------------------|----------|
//! | `speed`      | latency-sensitive: live insights, classification, answers | openai/gpt-5.6-luna | OpenAI   |
//! | `balanced`   | default (~80%): meeting notes, general chat               | openai/gpt-5.6-luna | OpenAI   |
//! | `smart`      | hard reasoning                                            | openai/gpt-5.6-luna          | OpenAI   |
//! | `multimodal` | vision / visual computer-use                              | openai/gpt-5.6-luna          | OpenAI   |
//! | `search`     | web-grounded answers (live search)                        | perplexity/sonar             | Perplexity |
//! | `transcribe` | server-side speech-to-text (no hub on the caller)         | x-ai/grok-stt-1.0            | xAI      |
//! | `speak`      | server-side text-to-speech                                | openai/gpt-audio-mini        | OpenAI   |
//!
//! The default ids are best-effort and may need correcting against the real
//! provider APIs; that is exactly why they are env-overridable rather than
//! hardcoded at call sites.
//!
//! A tier says how much a workload is worth paying for. A [`Capability`] says
//! what a model can actually carry, which a slug alone never encoded: a call
//! site that needs audio or images resolves through [`model_for_capability`] or
//! [`select_model_for`] so an incapable model — table default or env override —
//! is refused rather than silently handed input it cannot read.

// Every text tier resolves to the same model; the BALANCED model reaches
// meeting notes through the configured provider rather than a tier lookup here,
// so some variants are unconstructed in this binary. The full table is kept as
// the single source of truth mirrored by the worker.
#[allow(dead_code)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ModelTier {
    Speed,
    Balanced,
    Smart,
    Multimodal,
    Search,
    Transcribe,
    Speak,
}

#[path = "model_tier_defaults.rs"]
mod model_tier_defaults;
use model_tier_defaults::MODEL_CAPABILITIES;
pub(crate) use model_tier_defaults::{
    DEFAULT_BALANCED_MODEL, DEFAULT_MULTIMODAL_MODEL, DEFAULT_SEARCH_MODEL, DEFAULT_SMART_MODEL,
    DEFAULT_SPEAK_MODEL, DEFAULT_SPEED_MODEL, DEFAULT_TRANSCRIBE_MODEL,
};

impl ModelTier {
    /// The env var that overrides this tier's model id.
    pub(crate) fn env_var(self) -> &'static str {
        match self {
            ModelTier::Speed => "OMI_MODEL_SPEED",
            ModelTier::Balanced => "OMI_MODEL_BALANCED",
            ModelTier::Smart => "OMI_MODEL_SMART",
            ModelTier::Multimodal => "OMI_MODEL_MULTIMODAL",
            ModelTier::Search => "OMI_MODEL_SEARCH",
            ModelTier::Transcribe => "OMI_MODEL_TRANSCRIBE",
            ModelTier::Speak => "OMI_MODEL_SPEAK",
        }
    }

    /// The fallback model id when nothing is configured.
    pub(crate) fn default_model(self) -> &'static str {
        match self {
            ModelTier::Speed => DEFAULT_SPEED_MODEL,
            ModelTier::Balanced => DEFAULT_BALANCED_MODEL,
            ModelTier::Smart => DEFAULT_SMART_MODEL,
            ModelTier::Multimodal => DEFAULT_MULTIMODAL_MODEL,
            ModelTier::Search => DEFAULT_SEARCH_MODEL,
            ModelTier::Transcribe => DEFAULT_TRANSCRIBE_MODEL,
            ModelTier::Speak => DEFAULT_SPEAK_MODEL,
        }
    }
}

/// Resolves a tier to its model id from a value lookup, falling back to the
/// tier default. BALANCED additionally accepts the legacy `MIMO_MODEL` name so
/// the existing managed-AI configuration keeps working as the balanced default.
pub(crate) fn model_for_tier(tier: ModelTier, value: impl Fn(&str) -> Option<String>) -> String {
    let nonempty = |name: &str| value(name).filter(|candidate| !candidate.trim().is_empty());
    nonempty(tier.env_var())
        .or_else(|| match tier {
            ModelTier::Balanced => nonempty("MIMO_MODEL"),
            _ => None,
        })
        .unwrap_or_else(|| tier.default_model().to_owned())
}

/// Environment-backed variant of [`model_for_tier`].
pub(crate) fn model_for_tier_env(tier: ModelTier) -> String {
    model_for_tier(tier, |name| std::env::var(name).ok())
}

/// What a model can carry, independent of what it costs.
///
/// `Realtime` is deliberately claimed by nothing in this table: a bidirectional
/// live conversation runs over Gemini Live (`live_voice.rs`), not over an
/// OpenRouter chat completion, so asking the tier table for a realtime model is
/// asking the wrong layer and is refused.
#[allow(dead_code)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Capability {
    Text,
    AudioIn,
    AudioOut,
    ImageIn,
    Realtime,
}

/// A model id an env override introduced declares itself through
/// `OMI_MODEL_CAPABILITIES`, a `model=cap+cap,model=cap` list. Anything the
/// value does not parse is simply not declared, so a typo degrades to "this
/// model is unverified" and the check below refuses it loudly at the point of
/// use rather than accepting an unverified model.
fn declared_capabilities(
    model: &str,
    value: &impl Fn(&str) -> Option<String>,
) -> Option<Vec<Capability>> {
    let raw = value("OMI_MODEL_CAPABILITIES")?;
    for entry in raw.split(',') {
        let (name, capabilities) = entry.split_once('=')?;
        if name.trim() != model {
            continue;
        }
        return Some(
            capabilities
                .split('+')
                .filter_map(|capability| match capability.trim() {
                    "text" => Some(Capability::Text),
                    "audioIn" => Some(Capability::AudioIn),
                    "audioOut" => Some(Capability::AudioOut),
                    "imageIn" => Some(Capability::ImageIn),
                    "realtime" => Some(Capability::Realtime),
                    _ => None,
                })
                .collect(),
        );
    }
    None
}

/// The capabilities of a model id, empty when nothing has verified it.
pub(crate) fn capabilities_of(
    model: &str,
    value: impl Fn(&str) -> Option<String>,
) -> Vec<Capability> {
    if let Some(declared) = declared_capabilities(model, &value) {
        return declared;
    }
    MODEL_CAPABILITIES
        .iter()
        .find(|(name, _)| *name == model)
        .map(|(_, capabilities)| capabilities.to_vec())
        .unwrap_or_default()
}

/// Raised when the model a tier resolves to cannot carry the request. Refusing
/// here is the point: silently sending audio to a text-only model is how a
/// transcription becomes a confident invention.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CapabilityMismatch {
    pub(crate) tier: ModelTier,
    pub(crate) model: String,
    pub(crate) missing: Vec<Capability>,
}

impl std::fmt::Display for CapabilityMismatch {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "model {} (tier {:?}) lacks required capability: {:?}",
            self.model, self.tier, self.missing
        )
    }
}

fn missing_capabilities(
    model: &str,
    required: &[Capability],
    value: impl Fn(&str) -> Option<String>,
) -> Vec<Capability> {
    let capabilities = capabilities_of(model, value);
    required
        .iter()
        .copied()
        .filter(|capability| !capabilities.contains(capability))
        .collect()
}

/// Resolves a tier the way [`model_for_tier`] does, then validates the result —
/// override included — against the capabilities the call site needs.
#[allow(dead_code)]
pub(crate) fn model_for_capability(
    tier: ModelTier,
    required: &[Capability],
    value: impl Fn(&str) -> Option<String> + Copy,
) -> Result<String, CapabilityMismatch> {
    let model = model_for_tier(tier, value);
    let missing = missing_capabilities(&model, required, value);
    if missing.is_empty() {
        Ok(model)
    } else {
        Err(CapabilityMismatch {
            tier,
            model,
            missing,
        })
    }
}

/// Picks the first tier in `preference` whose model can carry `required`, so a
/// workload states what it needs and what it would rather pay. Fails rather
/// than falling back to a model that cannot take the input.
#[allow(dead_code)]
pub(crate) fn select_model_for(
    required: &[Capability],
    preference: &[ModelTier],
    value: impl Fn(&str) -> Option<String> + Copy,
) -> Result<(ModelTier, String), CapabilityMismatch> {
    let mut last: Option<CapabilityMismatch> = None;
    for tier in preference {
        match model_for_capability(*tier, required, value) {
            Ok(model) => return Ok((*tier, model)),
            Err(mismatch) => last = Some(mismatch),
        }
    }
    Err(last.unwrap_or_else(|| CapabilityMismatch {
        tier: ModelTier::Balanced,
        model: model_for_tier(ModelTier::Balanced, value),
        missing: required.to_vec(),
    }))
}

/// Asynchronous audio (voice notes, WAL uploads, channel voice messages) goes
/// to the transcribe tier, and falls through to the text tiers only when an
/// override leaves one of them able to take audio. Mirrors the worker's
/// `asyncAudioTierPreference`.
#[allow(dead_code)]
pub(crate) const ASYNC_AUDIO_TIER_PREFERENCE: &[ModelTier] = &[
    ModelTier::Transcribe,
    ModelTier::Balanced,
    ModelTier::Multimodal,
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tiers_fall_back_to_their_defaults() {
        let empty = |_: &str| None;
        assert_eq!(model_for_tier(ModelTier::Speed, empty), DEFAULT_SPEED_MODEL);
        assert_eq!(
            model_for_tier(ModelTier::Balanced, empty),
            DEFAULT_BALANCED_MODEL
        );
        assert_eq!(model_for_tier(ModelTier::Smart, empty), DEFAULT_SMART_MODEL);
        assert_eq!(
            model_for_tier(ModelTier::Multimodal, empty),
            DEFAULT_MULTIMODAL_MODEL
        );
    }

    #[test]
    fn explicit_overrides_win() {
        let overridden = |name: &str| match name {
            "OMI_MODEL_BALANCED" => Some("custom-balanced".to_owned()),
            _ => None,
        };
        assert_eq!(
            model_for_tier(ModelTier::Balanced, overridden),
            "custom-balanced"
        );
    }

    #[test]
    fn balanced_accepts_the_legacy_mimo_model_as_its_default() {
        let legacy = |name: &str| match name {
            "MIMO_MODEL" => Some("mimo-configured".to_owned()),
            _ => None,
        };
        assert_eq!(
            model_for_tier(ModelTier::Balanced, legacy),
            "mimo-configured"
        );
        // The legacy name only feeds the balanced tier, never the others.
        assert_eq!(
            model_for_tier(ModelTier::Smart, legacy),
            DEFAULT_SMART_MODEL
        );
    }

    #[test]
    fn audio_tiers_declare_audio_and_text_tiers_do_not() {
        let empty = |_: &str| None;
        assert!(capabilities_of(DEFAULT_TRANSCRIBE_MODEL, empty).contains(&Capability::AudioIn));
        assert!(capabilities_of(DEFAULT_MULTIMODAL_MODEL, empty).contains(&Capability::ImageIn));
        assert!(capabilities_of(DEFAULT_SPEAK_MODEL, empty).contains(&Capability::AudioOut));
        assert!(!capabilities_of(DEFAULT_BALANCED_MODEL, empty).contains(&Capability::AudioIn));
        assert!(!capabilities_of(DEFAULT_SPEED_MODEL, empty).contains(&Capability::AudioIn));
        assert!(!capabilities_of(DEFAULT_SMART_MODEL, empty).contains(&Capability::AudioIn));
    }

    #[test]
    fn a_capability_mismatch_is_refused_rather_than_routed() {
        let empty = |_: &str| None;
        let refused = model_for_capability(ModelTier::Smart, &[Capability::AudioIn], empty);
        assert_eq!(
            refused,
            Err(CapabilityMismatch {
                tier: ModelTier::Smart,
                model: DEFAULT_SMART_MODEL.to_owned(),
                missing: vec![Capability::AudioIn],
            })
        );
        // Nothing in the table carries a realtime session; that is Gemini Live.
        assert!(
            select_model_for(
                &[Capability::Realtime],
                &[ModelTier::Balanced, ModelTier::Multimodal],
                empty
            )
            .is_err()
        );
    }

    #[test]
    fn an_override_is_validated_against_the_required_capability() {
        let text_only = |name: &str| match name {
            "OMI_MODEL_TRANSCRIBE" => Some(DEFAULT_SPEED_MODEL.to_owned()),
            _ => None,
        };
        assert!(
            model_for_capability(ModelTier::Transcribe, &[Capability::AudioIn], text_only).is_err()
        );
        // An unverified id satisfies nothing until it declares itself.
        let unverified = |name: &str| match name {
            "OMI_MODEL_TRANSCRIBE" => Some("some/unknown-model".to_owned()),
            _ => None,
        };
        assert!(
            model_for_capability(ModelTier::Transcribe, &[Capability::AudioIn], unverified)
                .is_err()
        );
        let declared = |name: &str| match name {
            "OMI_MODEL_TRANSCRIBE" => Some("some/unknown-model".to_owned()),
            "OMI_MODEL_CAPABILITIES" => Some("some/unknown-model=text+audioIn".to_owned()),
            _ => None,
        };
        assert_eq!(
            model_for_capability(ModelTier::Transcribe, &[Capability::AudioIn], declared),
            Ok("some/unknown-model".to_owned())
        );
    }

    #[test]
    fn asynchronous_audio_reaches_a_model_that_can_hear_it() {
        let empty = |_: &str| None;
        assert_eq!(
            select_model_for(&[Capability::AudioIn], ASYNC_AUDIO_TIER_PREFERENCE, empty),
            Ok((ModelTier::Transcribe, DEFAULT_TRANSCRIBE_MODEL.to_owned()))
        );
        // A transcribe override that cannot take audio is refused rather than
        // falling through to a text model that would answer about audio it
        // never received.
        let text_only = |name: &str| match name {
            "OMI_MODEL_TRANSCRIBE" => Some(DEFAULT_SMART_MODEL.to_owned()),
            _ => None,
        };
        assert!(
            select_model_for(
                &[Capability::AudioIn],
                ASYNC_AUDIO_TIER_PREFERENCE,
                text_only
            )
            .is_err()
        );
    }

    #[test]
    fn every_text_tier_resolves_to_the_one_text_model() {
        let empty = |_: &str| None;
        for tier in [
            ModelTier::Speed,
            ModelTier::Balanced,
            ModelTier::Smart,
            ModelTier::Multimodal,
        ] {
            assert_eq!(model_for_tier(tier, empty), "openai/gpt-5.6-luna");
        }
    }

    #[test]
    fn blank_values_are_ignored() {
        let blank = |_: &str| Some("   ".to_owned());
        assert_eq!(model_for_tier(ModelTier::Speed, blank), DEFAULT_SPEED_MODEL);
    }
}
