// Model-tier routing config: the single source of truth for which model id
// each workload class resolves to. The hub (app/native/hub/src/model_tier.rs)
// and worker-rs (worker-rs/src/managed_ai.rs) mirror this table and read the
// same OMI_MODEL_* variables with the same defaults.
//
// | Tier       | When                                                      | Default model         | Provider |
// |------------|-----------------------------------------------------------|-----------------------|----------|
// | speed      | latency-sensitive: live insights, classification, answers | inception/mercury-2 | Inception   |
// | balanced   | default (~80%): meeting notes, general chat               | xiaomi/mimo-v2.5          | MiMo     |
// | smart      | hard reasoning                                            | xiaomi/mimo-v2.5-pro           | MiMo     |
// | multimodal | vision / visual computer-use                              | google/gemini-3.6-flash         | Gemini   |
// | search     | web-grounded answers (live search)                        | perplexity/sonar                | Perplexity |
//
// The default ids are best-effort and may need correcting against the real
// provider APIs; that is why they are env-overridable rather than hardcoded.

import type { Bindings } from "./types";

export type ModelTier =
  | "speed"
  | "balanced"
  | "smart"
  | "multimodal"
  | "search";

export const defaultTierModels: Record<ModelTier, string> = {
  speed: "inception/mercury-2",
  balanced: "xiaomi/mimo-v2.5",
  smart: "xiaomi/mimo-v2.5-pro",
  multimodal: "google/gemini-3.6-flash",
  search: "perplexity/sonar",
};

const tierEnvVar: Record<ModelTier, keyof Bindings> = {
  speed: "OMI_MODEL_SPEED",
  balanced: "OMI_MODEL_BALANCED",
  smart: "OMI_MODEL_SMART",
  multimodal: "OMI_MODEL_MULTIMODAL",
  search: "OMI_MODEL_SEARCH",
};

const nonEmpty = (value: string | undefined): string | undefined => {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
};

// Resolves a tier to its model id, falling back to the tier default. The
// balanced tier additionally accepts the legacy MIMO_MODEL name so the existing
// managed-AI configuration keeps working as the balanced default.
export const modelForTier = (env: Bindings, tier: ModelTier): string =>
  nonEmpty(env[tierEnvVar[tier]] as string | undefined) ??
  (tier === "balanced" ? nonEmpty(env.MIMO_MODEL) : undefined) ??
  defaultTierModels[tier];
