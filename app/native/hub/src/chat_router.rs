use crate::model_tier::{
    ASYNC_AUDIO_TIER_PREFERENCE, Capability, CapabilityMismatch, ModelTier, model_for_tier,
    select_model_for,
};
use crate::signals::MessageOrigin;
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

// Prompts that likely need computer-use tools, memory writes, or channel actions.
const TOOL_MARKERS: &[&str] = &[
    "click",
    "open ",
    "type ",
    "press ",
    "tap ",
    "scroll",
    "screenshot",
    "on my screen",
    "computer",
    "browser",
    "remember this",
    "save to memory",
    "add to memory",
    "send a message",
    "text ",
    "email ",
];

const SHORT_SIMPLE_MAX_LEN: usize = 160;

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
    /// intents are detected first; short simple chat turns route to Speed
    /// (Mercury); everything else defers to rx4's heuristics.
    pub(crate) fn route_prompt(&self, prompt: &str, origin: Option<MessageOrigin>) -> ModelTier {
        let lowered = prompt.to_lowercase();
        if SEARCH_MARKERS.iter().any(|marker| lowered.contains(marker)) {
            return ModelTier::Search;
        }
        if likely_needs_tools(prompt, origin) {
            return ModelTier::Smart;
        }
        if VISION_MARKERS.iter().any(|marker| lowered.contains(marker)) {
            return ModelTier::Multimodal;
        }
        // Recall prompts ("do you remember…") used to divert here too, but the
        // memories they ask about reach the model as text the runtime already
        // recalled, so nothing about them needs a vision model. Sending them to
        // MULTIMODAL only bought them a lite model chosen for reading pictures
        // and audio, which is not a chat model — recall answers came back
        // shallow. They now take the ordinary chat path like any other turn.
        if !likely_needs_tools(prompt, origin)
            && is_short_simple(prompt)
            && !HEAVY_KEYWORDS
                .iter()
                .any(|keyword| lowered.contains(keyword))
        {
            return ModelTier::Speed;
        }
        match self.router.route_prompt(prompt).model.as_str() {
            model if model == self.tier_model(TaskTier::Heavy) => ModelTier::Smart,
            model if model == self.tier_model(TaskTier::Lite) => ModelTier::Speed,
            _ => ModelTier::Balanced,
        }
    }

    /// The model slug the online router picks for `prompt`.
    #[allow(dead_code)]
    pub(crate) fn model_for_prompt(
        &self,
        prompt: &str,
        value: impl Fn(&str) -> Option<String>,
    ) -> String {
        model_for_tier(self.route_prompt(prompt, None), value)
    }

    /// Selects a model for a request that carries more than text. The prompt
    /// still decides what the request is worth paying for, but the attachment
    /// decides what the model has to be able to read, and a configuration where
    /// no preferred tier can read it is an error rather than a silent downgrade
    /// to a model that would answer about audio it never received.
    #[allow(dead_code)]
    pub(crate) fn model_for_input(
        &self,
        prompt: &str,
        required: &[Capability],
        value: impl Fn(&str) -> Option<String> + Copy,
    ) -> Result<String, CapabilityMismatch> {
        // Audio in is the asynchronous voice-note case: cheapest capable tier
        // first, which is the balanced model. Anything else keeps the prompt's
        // own tier at the head of the preference list.
        if required.contains(&Capability::AudioIn) {
            return select_model_for(required, ASYNC_AUDIO_TIER_PREFERENCE, value)
                .map(|(_, model)| model);
        }
        let routed = self.route_prompt(prompt, None);
        let preference = [routed, ModelTier::Multimodal, ModelTier::Balanced];
        select_model_for(required, &preference, value).map(|(_, model)| model)
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

fn likely_needs_tools(prompt: &str, origin: Option<MessageOrigin>) -> bool {
    if matches!(origin, Some(MessageOrigin::Overlay)) {
        return true;
    }
    let lowered = prompt.to_lowercase();
    TOOL_MARKERS.iter().any(|marker| lowered.contains(marker))
}

fn is_short_simple(prompt: &str) -> bool {
    let trimmed = prompt.trim();
    trimmed.len() <= SHORT_SIMPLE_MAX_LEN
        && trimmed.matches('\n').count() <= 1
        && !trimmed.contains("```")
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::model_tier::{
        DEFAULT_BALANCED_MODEL, DEFAULT_MULTIMODAL_MODEL, DEFAULT_SEARCH_MODEL,
        DEFAULT_SMART_MODEL, DEFAULT_SPEAK_MODEL, DEFAULT_SPEED_MODEL, DEFAULT_TRANSCRIBE_MODEL,
        capabilities_of,
    };
    use crate::signals::MessageOrigin;

    fn default_router() -> ChatRouter {
        ChatRouter::with_value(|_| None)
    }

    #[test]
    fn route_prompt_selects_expected_tiers() {
        let router = default_router();
        assert_eq!(router.route_prompt("hi there", None), ModelTier::Speed);
        assert_eq!(
            router.route_prompt("prove this theorem step by step", None),
            ModelTier::Smart
        );
        assert_eq!(
            router.route_prompt("what is in this image?", None),
            ModelTier::Multimodal
        );
        assert_eq!(
            router.route_prompt("search the web for today's headlines", None),
            ModelTier::Search
        );
    }

    #[test]
    fn overlay_origin_routes_to_smart_for_the_tool_pipeline() {
        let router = default_router();
        assert_eq!(
            router.route_prompt("hi there", Some(MessageOrigin::Overlay)),
            ModelTier::Smart
        );
    }

    #[test]
    fn tool_markers_route_to_smart() {
        let router = default_router();
        assert_eq!(
            router.route_prompt("click the save button", None),
            ModelTier::Smart
        );
    }

    #[test]
    fn memory_recall_stays_on_a_chat_tier() {
        let router = default_router();
        assert_eq!(
            router.route_prompt("what do you remember about my work?", None),
            ModelTier::Speed
        );
    }

    // The regression this pins: desktop chat once answered on a lite model
    // picked for audio and pictures, because a text prompt was routed to a
    // non-chat tier. A tier whose model cannot hold a text conversation must
    // never be reachable from a typed turn, whatever the wording.
    #[test]
    fn no_typed_prompt_routes_to_a_non_chat_tier() {
        let router = default_router();
        let prompts = [
            "hi there",
            "what do you remember about my work?",
            "recall my notes from the standup",
            "from my memory, what did I promise Ana?",
            "summarize my past week and tell me what I keep putting off",
            "prove this theorem step by step",
            "click the save button",
            "search the web for today's headlines",
            "what is in this image?",
        ];
        for prompt in prompts {
            let tier = router.route_prompt(prompt, None);
            assert!(
                !matches!(tier, ModelTier::Transcribe | ModelTier::Speak),
                "{prompt:?} routed to {tier:?}"
            );
            assert!(
                capabilities_of(&model_for_tier(tier, |_| None), |_| None)
                    .contains(&Capability::Text),
                "{prompt:?} routed to {tier:?}, whose model cannot carry text"
            );
        }
    }

    // Recall is a text workload, so it has to resolve to a text-first chat
    // model rather than to whatever the audio tiers happen to name.
    #[test]
    fn recall_never_resolves_to_the_transcribe_model() {
        let router = default_router();
        for prompt in [
            "do you remember the plan?",
            "recall my notes from the standup",
            "what do you remember about my work?",
        ] {
            let model = router.model_for_prompt(prompt, |_| None);
            assert_ne!(model, DEFAULT_TRANSCRIBE_MODEL, "{prompt:?}");
            assert_ne!(model, DEFAULT_SPEAK_MODEL, "{prompt:?}");
            assert_eq!(model, DEFAULT_SPEED_MODEL, "{prompt:?}");
        }
    }

    #[test]
    fn router_resolves_tiers_to_model_tier_slugs() {
        let router = default_router();
        let slug = |prompt: &str| router.model_for_prompt(prompt, |_| None);
        assert_eq!(slug("prove this theorem"), DEFAULT_SMART_MODEL);
        assert_eq!(slug("hi there"), DEFAULT_SPEED_MODEL);
        assert_eq!(slug("describe this photo"), DEFAULT_MULTIMODAL_MODEL);
        assert_eq!(slug("search the web for prices"), DEFAULT_SEARCH_MODEL);
        // The Lite tier is populated from the SPEED slug even though the online
        // prompt heuristics rarely reach it directly.
        assert_eq!(router.tier_model(TaskTier::Lite), DEFAULT_SPEED_MODEL);
    }

    #[test]
    fn audio_input_routes_to_the_balanced_model_whatever_the_prompt_says() {
        let router = default_router();
        assert_eq!(
            router.model_for_input("prove this theorem", &[Capability::AudioIn], |_| None),
            Ok(DEFAULT_BALANCED_MODEL.to_owned())
        );
    }

    #[test]
    fn an_input_no_configured_model_can_read_is_refused() {
        let router = default_router();
        let text_only = |name: &str| match name {
            "OMI_MODEL_MULTIMODAL" => Some(DEFAULT_SPEED_MODEL.to_owned()),
            "OMI_MODEL_BALANCED" => Some(DEFAULT_SPEED_MODEL.to_owned()),
            _ => None,
        };
        assert!(
            router
                .model_for_input("what is in this image?", &[Capability::ImageIn], text_only)
                .is_err()
        );
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
