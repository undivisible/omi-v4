use crate::model_tier::{ModelTier, model_for_tier};
use rx4::model_router::{ModelRouter, RouterConfig, TaskTier};

// Search and multimodal are hub-level tiers with no rx4 `TaskTier`, so the
// online router detects them from prompt keywords before delegating the
// remaining Lite/Standard/Heavy decision to rx4's `route_prompt`.
const SEARCH_MARKERS: &[&str] = &[
    "search the web",
    "search online",
    "web search",
    "look up",
    "latest news",
    "current price",
    "up to date",
    "on the internet",
];

const VISION_MARKERS: &[&str] = &[
    "this image",
    "this photo",
    "this picture",
    "this screenshot",
    "look at this",
    "see this",
    "in the picture",
    "on screen",
];

// Extra prompt heuristics layered onto rx4's defaults so hard reasoning routes
// to the Heavy tier (our SMART model) rather than falling through to Standard.
const HEAVY_KEYWORDS: &[&str] = &[
    "reasoning",
    "prove",
    "proof",
    "algorithm",
    "analyze",
    "refactor",
    "implement",
    "step by step",
    "think hard",
    "optimize",
];

/// Bridges rx4's [`ModelRouter`] to the hub's [`ModelTier`] slug table.
///
/// The router's per-tier model ids are populated from `model_tier.rs` (the
/// single source of truth) rather than re-hardcoded here, so a slug is only
/// ever corrected in one place.
pub(crate) struct ChatRouter {
    router: ModelRouter,
}

impl ChatRouter {
    /// Builds a router whose tier models resolve to the hub's slugs, reading
    /// each slug through `value` (an env-style lookup).
    pub(crate) fn with_value(value: impl Fn(&str) -> Option<String> + Copy) -> Self {
        let mut config = RouterConfig::default();
        for keyword in HEAVY_KEYWORDS {
            config
                .prompt_heuristics
                .insert((*keyword).to_owned(), TaskTier::Heavy);
        }
        let mut router = ModelRouter::with_config(config);
        // rx4 TaskTier -> hub ModelTier: Lite=Speed, Standard=Balanced,
        // Heavy=Smart, Subagent=Balanced. Each tier falls back to Balanced so a
        // failed tier degrades to the everyday model.
        let speed = model_for_tier(ModelTier::Speed, value);
        let balanced = model_for_tier(ModelTier::Balanced, value);
        let smart = model_for_tier(ModelTier::Smart, value);
        router.set_model(TaskTier::Lite, speed);
        router.set_model(TaskTier::Standard, balanced.clone());
        router.set_model(TaskTier::Heavy, smart.clone());
        router.set_model(TaskTier::Subagent, balanced.clone());
        router.set_fallback(TaskTier::Lite, balanced.clone());
        router.set_fallback(TaskTier::Standard, smart);
        router.set_fallback(TaskTier::Heavy, balanced.clone());
        router.set_fallback(TaskTier::Subagent, balanced);
        Self { router }
    }

    /// Environment-backed constructor mirroring [`model_for_tier_env`].
    pub(crate) fn from_env() -> Self {
        Self::with_value(|name| std::env::var(name).ok())
    }

    /// Selects the hub [`ModelTier`] for an online prompt. Search and vision
    /// intents are detected first; everything else defers to rx4's heuristics.
    pub(crate) fn route_prompt(&self, prompt: &str) -> ModelTier {
        let lowered = prompt.to_lowercase();
        if SEARCH_MARKERS.iter().any(|marker| lowered.contains(marker)) {
            return ModelTier::Search;
        }
        if VISION_MARKERS.iter().any(|marker| lowered.contains(marker)) {
            return ModelTier::Multimodal;
        }
        match self.router.route_prompt(prompt).model.as_str() {
            model if model == self.tier_model(TaskTier::Heavy) => ModelTier::Smart,
            model if model == self.tier_model(TaskTier::Lite) => ModelTier::Speed,
            _ => ModelTier::Balanced,
        }
    }

    /// The model slug the online router picks for `prompt`.
    pub(crate) fn model_for_prompt(
        &self,
        prompt: &str,
        value: impl Fn(&str) -> Option<String>,
    ) -> String {
        model_for_tier(self.route_prompt(prompt), value)
    }

    fn tier_model(&self, tier: TaskTier) -> &str {
        self.router
            .config()
            .tiers
            .get(&tier)
            .map(|configured| configured.model.as_str())
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::model_tier::{
        DEFAULT_BALANCED_MODEL, DEFAULT_MULTIMODAL_MODEL, DEFAULT_SEARCH_MODEL,
        DEFAULT_SMART_MODEL, DEFAULT_SPEED_MODEL,
    };

    fn default_router() -> ChatRouter {
        ChatRouter::with_value(|_| None)
    }

    #[test]
    fn route_prompt_selects_expected_tiers() {
        let router = default_router();
        assert_eq!(router.route_prompt("hi there"), ModelTier::Balanced);
        assert_eq!(
            router.route_prompt("prove this theorem step by step"),
            ModelTier::Smart
        );
        assert_eq!(
            router.route_prompt("what is in this image?"),
            ModelTier::Multimodal
        );
        assert_eq!(
            router.route_prompt("search the web for today's headlines"),
            ModelTier::Search
        );
    }

    #[test]
    fn router_resolves_tiers_to_model_tier_slugs() {
        let router = default_router();
        let slug = |prompt: &str| router.model_for_prompt(prompt, |_| None);
        assert_eq!(slug("prove this theorem"), DEFAULT_SMART_MODEL);
        assert_eq!(slug("hi there"), DEFAULT_BALANCED_MODEL);
        assert_eq!(slug("describe this photo"), DEFAULT_MULTIMODAL_MODEL);
        assert_eq!(slug("search the web for prices"), DEFAULT_SEARCH_MODEL);
        // The Lite tier is populated from the SPEED slug even though the online
        // prompt heuristics rarely reach it directly.
        assert_eq!(router.tier_model(TaskTier::Lite), DEFAULT_SPEED_MODEL);
    }

    #[test]
    fn tier_slugs_follow_env_overrides() {
        let router = ChatRouter::with_value(|name| match name {
            "OMI_MODEL_SMART" => Some("custom-smart".to_owned()),
            _ => None,
        });
        assert_eq!(
            router.model_for_prompt("analyze the tradeoffs", |name| match name {
                "OMI_MODEL_SMART" => Some("custom-smart".to_owned()),
                _ => None,
            }),
            "custom-smart"
        );
    }
}
