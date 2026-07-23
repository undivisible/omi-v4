//! Model-tier routing config: the single source of truth for which model id
//! each workload class resolves to. Both the hub and the worker read the same
//! `OMI_MODEL_*` environment variables with the same defaults so a model id is
//! corrected in one place.
//!
//! | Tier         | When                                                      | Default model           | Provider |
//! |--------------|-----------------------------------------------------------|-------------------------|----------|
//! | `speed`      | latency-sensitive: live insights, classification, answers | `gemini-3.1-flash-lite` | Gemini   |
//! | `balanced`   | default (~80%): meeting notes, general chat               | `mimo-v2.5-balanced`    | MiMo     |
//! | `smart`      | hard reasoning                                            | `mimo-v2.5-pro`         | MiMo     |
//! | `multimodal` | vision / visual computer-use                              | `gemini-3.6-flash`      | Gemini   |
//!
//! The default ids are best-effort and may need correcting against the real
//! provider APIs; that is exactly why they are env-overridable rather than
//! hardcoded at call sites.

/// SPEED tier default: latency-sensitive live insights and answer suggestions.
pub(crate) const DEFAULT_SPEED_MODEL: &str = "gemini-3.1-flash-lite";
/// BALANCED tier default: the everyday model for meeting notes and chat.
pub(crate) const DEFAULT_BALANCED_MODEL: &str = "mimo-v2.5-balanced";
/// SMART tier default: reserved for hard reasoning.
pub(crate) const DEFAULT_SMART_MODEL: &str = "mimo-v2.5-pro";
/// MULTIMODAL tier default: vision and visual computer-use.
pub(crate) const DEFAULT_MULTIMODAL_MODEL: &str = "gemini-3.6-flash";

// The hub resolves the SPEED tier directly (its dev Gemini fallback); the
// BALANCED model reaches meeting notes through the configured provider rather
// than a tier lookup here, so those variants are unconstructed in this binary.
// The full table is kept as the single source of truth mirrored by the worker.
#[allow(dead_code)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ModelTier {
    Speed,
    Balanced,
    Smart,
    Multimodal,
}

impl ModelTier {
    /// The env var that overrides this tier's model id.
    pub(crate) fn env_var(self) -> &'static str {
        match self {
            ModelTier::Speed => "OMI_MODEL_SPEED",
            ModelTier::Balanced => "OMI_MODEL_BALANCED",
            ModelTier::Smart => "OMI_MODEL_SMART",
            ModelTier::Multimodal => "OMI_MODEL_MULTIMODAL",
        }
    }

    /// The fallback model id when nothing is configured.
    pub(crate) fn default_model(self) -> &'static str {
        match self {
            ModelTier::Speed => DEFAULT_SPEED_MODEL,
            ModelTier::Balanced => DEFAULT_BALANCED_MODEL,
            ModelTier::Smart => DEFAULT_SMART_MODEL,
            ModelTier::Multimodal => DEFAULT_MULTIMODAL_MODEL,
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
    fn blank_values_are_ignored() {
        let blank = |_: &str| Some("   ".to_owned());
        assert_eq!(model_for_tier(ModelTier::Speed, blank), DEFAULT_SPEED_MODEL);
    }
}
