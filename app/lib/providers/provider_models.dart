import '../native/generated/signals/signals.dart' show AssistantProvider;

/// The balanced-tier model each BYOK provider defaults to.
///
/// Onboarding collects one model, and the hub resolves the remaining tiers
/// (`app/native/hub/src/byok_tier.rs`) from the provider's own catalogue. This
/// map exists only so the single field arrives pre-filled: a user who types
/// nothing still connects to a real model rather than an empty string. A
/// `compatible` endpoint has no catalogue, so it has no default here.
const defaultBalancedModel = <AssistantProvider, String>{
  AssistantProvider.openAi: 'gpt-5.6-terra',
  AssistantProvider.anthropic: 'claude-sonnet-5',
  AssistantProvider.gemini: 'gemini-3.6-flash',
  AssistantProvider.xai: 'grok-4.5',
};
