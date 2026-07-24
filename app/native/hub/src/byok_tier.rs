//! Per-provider tier defaults for bring-your-own-key inference.
//!
//! `model_tier.rs` is the managed-path table: one set of OpenRouter slugs the
//! worker and the hub both read. A BYOK user is not on OpenRouter — they hold a
//! key for one provider — so the same five chat-facing tiers have to resolve to
//! that provider's own model ids. This table is that mapping, and it is hub-only
//! by design: the worker never dispatches against a user's key, so mirroring it
//! into `worker/src/model-tiers.ts` would add a table nothing there reads.
//!
//! | Tier         | OpenAI            | Anthropic          | Gemini                 | xAI       |
//! |--------------|-------------------|--------------------|------------------------|-----------|
//! | `speed`      | gpt-5.6-luna      | claude-haiku-4-5   | gemini-3.5-flash-lite  | grok-4.3  |
//! | `balanced`   | gpt-5.6-terra     | claude-sonnet-5    | gemini-3.6-flash       | grok-4.5  |
//! | `smart`      | gpt-5.6-sol       | claude-opus-4-8    | gemini-3.5-flash       | grok-4.5  |
//! | `multimodal` | gpt-5.6-terra     | claude-sonnet-5    | gemini-3.6-flash       | grok-4.5  |
//! | `search`     | gpt-5.6-terra     | claude-sonnet-5    | gemini-3.6-flash       | grok-4.5  |
//!
//! Every id above was read off the provider's own live model documentation
//! rather than guessed. The OpenAI ids are exactly the picker-visible models the
//! ChatGPT-subscription Codex Responses endpoint serves (per Zed's
//! `openai_subscribed.rs` model list), and the xAI ids are the Grok models the
//! SuperGrok OAuth surface serves, so the same table backs both the API-key and
//! the OAuth sign-in paths for those two providers. The SEARCH tier for OpenAI
//! and xAI is dispatched through their Responses API's hosted
//! `{"type": "web_search"}` tool
//! (`hosted_search.rs`) rather than through `rs_ai`, which speaks only
//! `/chat/completions` with function tools and cannot emit that tool shape.
//! Any general model drives the hosted tool, so OpenAI's search tier is a
//! normal model (gpt-5.6-terra) and no longer the Chat-Completions-only
//! `gpt-5-search-api`. Anthropic and Gemini expose no such passthrough here,
//! so their search tier stays on the balanced model rather than pretending to
//! be grounded.

use crate::model_tier::{Capability, ModelTier};

/// The BYOK providers with a known model catalogue. `compatible` is absent on
/// purpose: an arbitrary OpenAI-shaped endpoint has no catalogue to map, so it
/// keeps the single configured model for every tier.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ByokProvider {
    OpenAi,
    Anthropic,
    Gemini,
    Xai,
}

const OPENAI_TIERS: &[(ModelTier, &str)] = &[
    (ModelTier::Speed, "gpt-5.6-luna"),
    (ModelTier::Balanced, "gpt-5.6-terra"),
    (ModelTier::Smart, "gpt-5.6-sol"),
    (ModelTier::Multimodal, "gpt-5.6-terra"),
    // The SEARCH tier is dispatched through the Responses API's hosted
    // `web_search` tool (`hosted_search.rs`), which any general model drives —
    // the fine-tuned `gpt-5-search-api` is a Chat-Completions-only construct
    // and is no longer the search path.
    (ModelTier::Search, "gpt-5.6-terra"),
];

const ANTHROPIC_TIERS: &[(ModelTier, &str)] = &[
    (ModelTier::Speed, "claude-haiku-4-5"),
    (ModelTier::Balanced, "claude-sonnet-5"),
    (ModelTier::Smart, "claude-opus-4-8"),
    (ModelTier::Multimodal, "claude-sonnet-5"),
    (ModelTier::Search, "claude-sonnet-5"),
];

const GEMINI_TIERS: &[(ModelTier, &str)] = &[
    (ModelTier::Speed, "gemini-3.5-flash-lite"),
    (ModelTier::Balanced, "gemini-3.6-flash"),
    (ModelTier::Smart, "gemini-3.5-flash"),
    (ModelTier::Multimodal, "gemini-3.6-flash"),
    (ModelTier::Search, "gemini-3.6-flash"),
];

const XAI_TIERS: &[(ModelTier, &str)] = &[
    (ModelTier::Speed, "grok-4.3"),
    (ModelTier::Balanced, "grok-4.5"),
    (ModelTier::Smart, "grok-4.5"),
    (ModelTier::Multimodal, "grok-4.5"),
    (ModelTier::Search, "grok-4.5"),
];

/// Capabilities of the ids above, read off the same provider documentation.
/// A BYOK id absent from this table is unverified and satisfies nothing, the
/// same rule `model_tier.rs` applies to the managed slugs.
const BYOK_CAPABILITIES: &[(&str, &[Capability])] = &[
    // OpenAI: "All latest OpenAI models support text and image input".
    ("gpt-5.6-luna", &[Capability::Text, Capability::ImageIn]),
    ("gpt-5.6-terra", &[Capability::Text, Capability::ImageIn]),
    ("gpt-5.6-sol", &[Capability::Text, Capability::ImageIn]),
    ("claude-haiku-4-5", &[Capability::Text, Capability::ImageIn]),
    ("claude-sonnet-5", &[Capability::Text, Capability::ImageIn]),
    ("claude-opus-4-8", &[Capability::Text, Capability::ImageIn]),
    (
        "gemini-3.5-flash-lite",
        &[Capability::Text, Capability::AudioIn, Capability::ImageIn],
    ),
    (
        "gemini-3.6-flash",
        &[Capability::Text, Capability::AudioIn, Capability::ImageIn],
    ),
    (
        "gemini-3.5-flash",
        &[Capability::Text, Capability::AudioIn, Capability::ImageIn],
    ),
    ("grok-4.3", &[Capability::Text, Capability::ImageIn]),
    ("grok-4.5", &[Capability::Text, Capability::ImageIn]),
];

impl ByokProvider {
    fn table(self) -> &'static [(ModelTier, &'static str)] {
        match self {
            ByokProvider::OpenAi => OPENAI_TIERS,
            ByokProvider::Anthropic => ANTHROPIC_TIERS,
            ByokProvider::Gemini => GEMINI_TIERS,
            ByokProvider::Xai => XAI_TIERS,
        }
    }

    /// The provider's default model for a tier, or `None` for a tier this
    /// table does not route (transcribe and speak are server-side workloads a
    /// BYOK chat client never dispatches).
    pub(crate) fn default_model(self, tier: ModelTier) -> Option<&'static str> {
        self.table()
            .iter()
            .find(|(candidate, _)| *candidate == tier)
            .map(|(_, model)| *model)
    }

    /// The balanced-tier default, used to seed the single onboarding "Model"
    /// field so a user who types nothing still lands on a real model.
    pub(crate) fn default_balanced_model(self) -> &'static str {
        self.default_model(ModelTier::Balanced).unwrap_or_default()
    }
}

/// The capabilities of a BYOK model id, empty when nothing has verified it.
pub(crate) fn capabilities_of(model: &str) -> &'static [Capability] {
    BYOK_CAPABILITIES
        .iter()
        .find(|(name, _)| *name == model)
        .map(|(_, capabilities)| *capabilities)
        .unwrap_or(&[])
}

#[cfg(test)]
mod tests {
    use super::*;

    const CHAT_TIERS: &[ModelTier] = &[
        ModelTier::Speed,
        ModelTier::Balanced,
        ModelTier::Smart,
        ModelTier::Multimodal,
        ModelTier::Search,
    ];

    const PROVIDERS: &[ByokProvider] = &[
        ByokProvider::OpenAi,
        ByokProvider::Anthropic,
        ByokProvider::Gemini,
        ByokProvider::Xai,
    ];

    #[test]
    fn every_provider_covers_every_chat_tier_with_a_verified_model() {
        for provider in PROVIDERS {
            for tier in CHAT_TIERS {
                let model = provider
                    .default_model(*tier)
                    .unwrap_or_else(|| panic!("{provider:?} has no {tier:?} model"));
                assert!(
                    capabilities_of(model).contains(&Capability::Text),
                    "{model} is undeclared"
                );
            }
        }
    }

    #[test]
    fn multimodal_defaults_can_actually_read_images() {
        for provider in PROVIDERS {
            let model = provider
                .default_model(ModelTier::Multimodal)
                .unwrap_or_default();
            assert!(capabilities_of(model).contains(&Capability::ImageIn));
        }
    }

    #[test]
    fn server_side_tiers_are_not_routed_for_byok() {
        assert_eq!(ByokProvider::OpenAi.default_model(ModelTier::Speak), None);
        assert_eq!(
            ByokProvider::Gemini.default_model(ModelTier::Transcribe),
            None
        );
    }

    #[test]
    fn an_unknown_id_declares_nothing() {
        assert!(capabilities_of("some/unknown-model").is_empty());
    }
}
