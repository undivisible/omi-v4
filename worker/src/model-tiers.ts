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
// | transcribe | server-side speech-to-text (no hub on the caller)         | google/gemini-3.5-flash-lite    | Gemini   |
// | speak      | server-side text-to-speech                                | openai/gpt-audio-mini           | OpenAI   |
//
// The default ids are best-effort and may need correcting against the real
// provider APIs; that is why they are env-overridable rather than hardcoded.
//
// Tiers say how much a workload is worth paying for. Capabilities (below) say
// what a model can carry, and a call site that needs audio or images resolves
// through `modelForCapability` / `selectModelFor` so an incapable model — table
// default or env override — is refused rather than silently handed the input.

import type { Bindings } from "./types";

export type ModelTier =
  | "speed"
  | "balanced"
  | "smart"
  | "multimodal"
  | "search"
  | "transcribe"
  | "speak";

export const defaultTierModels: Record<ModelTier, string> = {
  speed: "inception/mercury-2",
  balanced: "xiaomi/mimo-v2.5",
  smart: "xiaomi/mimo-v2.5-pro",
  multimodal: "google/gemini-3.6-flash",
  search: "perplexity/sonar",
  transcribe: "google/gemini-3.5-flash-lite",
  speak: "openai/gpt-audio-mini",
};

const tierEnvVar: Record<ModelTier, keyof Bindings> = {
  speed: "OMI_MODEL_SPEED",
  balanced: "OMI_MODEL_BALANCED",
  smart: "OMI_MODEL_SMART",
  multimodal: "OMI_MODEL_MULTIMODAL",
  search: "OMI_MODEL_SEARCH",
  transcribe: "OMI_MODEL_TRANSCRIBE",
  speak: "OMI_MODEL_SPEAK",
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

// What a model can actually carry. A tier says how much a workload is worth
// paying for; a capability says whether the model can accept the request at
// all, which is the part a tier slug alone never encoded.
//
// `realtime` is deliberately declared by nothing in this table: a bidirectional
// live conversation runs over Gemini Live (worker/src/voice.ts mints the
// ephemeral token), not over OpenRouter chat completions, so any caller asking
// the tier table for a realtime model is asking the wrong layer and is refused.
export type ModelCapability =
  | "text"
  | "audioIn"
  | "audioOut"
  | "imageIn"
  | "realtime";

// Capabilities per model id, checked against the live OpenRouter model list.
// A model that is not listed here has unknown capabilities and therefore
// satisfies nothing: an unverified id must never be assumed able to take audio.
export const modelCapabilities: Record<string, readonly ModelCapability[]> = {
  // Cheapest audio-capable model on the list ($0.14/M prompt), which is why
  // asynchronous voice notes route here rather than to the transcribe tier.
  "xiaomi/mimo-v2.5": ["text", "audioIn"],
  "xiaomi/mimo-v2.5-pro": ["text"],
  "inception/mercury-2": ["text"],
  "perplexity/sonar": ["text"],
  "google/gemini-3.6-flash": ["text", "audioIn", "imageIn"],
  "google/gemini-3.5-flash-lite": ["text", "audioIn"],
  "openai/gpt-audio-mini": ["text", "audioOut"],
};

// An env override names a model this table has never seen, so the override has
// to be able to declare what it can do: OMI_MODEL_CAPABILITIES is a JSON object
// of model id to capability list, merged over the built-in table. A malformed
// value declares nothing rather than throwing, so a typo degrades to "this
// model is unverified" and the capability check refuses it loudly at use.
const declaredCapabilities = (
  env: Bindings,
): Record<string, readonly ModelCapability[]> => {
  const raw = nonEmpty(env.OMI_MODEL_CAPABILITIES);
  if (raw === undefined) return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return {};
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed))
    return {};
  const declared: Record<string, readonly ModelCapability[]> = {};
  for (const [model, value] of Object.entries(parsed)) {
    if (!Array.isArray(value)) continue;
    const capabilities = value.filter(
      (entry): entry is ModelCapability =>
        entry === "text" ||
        entry === "audioIn" ||
        entry === "audioOut" ||
        entry === "imageIn" ||
        entry === "realtime",
    );
    declared[model] = capabilities;
  }
  return declared;
};

// The capabilities of a model id, empty when nothing has verified it.
export const capabilitiesOf = (
  env: Bindings,
  model: string,
): readonly ModelCapability[] =>
  declaredCapabilities(env)[model] ?? modelCapabilities[model] ?? [];

export const modelSupports = (
  env: Bindings,
  model: string,
  required: readonly ModelCapability[],
): boolean => {
  const capabilities = capabilitiesOf(env, model);
  return required.every((capability) => capabilities.includes(capability));
};

// Raised when the model a tier resolves to cannot carry the request. Refusing
// here is the whole point: silently sending audio to a text-only model is how a
// transcription turns into a confident hallucination about nothing.
export class ModelCapabilityError extends Error {
  constructor(
    readonly tier: ModelTier,
    readonly model: string,
    readonly missing: readonly ModelCapability[],
  ) {
    super(
      `Model ${model} (tier ${tier}) lacks required capability: ${missing.join(", ")}`,
    );
    this.name = "ModelCapabilityError";
  }
}

const missingCapabilities = (
  env: Bindings,
  model: string,
  required: readonly ModelCapability[],
): ModelCapability[] => {
  const capabilities = capabilitiesOf(env, model);
  return required.filter((capability) => !capabilities.includes(capability));
};

// Resolves a tier the same way `modelForTier` does, then validates the result —
// override included — against the capabilities the call site actually needs.
export const modelForCapability = (
  env: Bindings,
  tier: ModelTier,
  required: readonly ModelCapability[],
): string => {
  const model = modelForTier(env, tier);
  const missing = missingCapabilities(env, model, required);
  if (missing.length > 0) throw new ModelCapabilityError(tier, model, missing);
  return model;
};

// Picks the first tier in `preference` whose model can carry `required`, so a
// workload states what it needs and what it would rather pay, and the table
// decides. Throws when no preferred tier qualifies rather than falling back to
// a model that cannot take the input.
export const selectModelFor = (
  env: Bindings,
  required: readonly ModelCapability[],
  preference: readonly ModelTier[],
): { tier: ModelTier; model: string } => {
  let last: ModelCapabilityError | null = null;
  for (const tier of preference) {
    const model = modelForTier(env, tier);
    const missing = missingCapabilities(env, model, required);
    if (missing.length === 0) return { tier, model };
    last = new ModelCapabilityError(tier, model, missing);
  }
  throw (
    last ??
    new ModelCapabilityError("balanced", modelForTier(env, "balanced"), [
      ...required,
    ])
  );
};

// Asynchronous audio (voice notes on a channel, WAL uploads, API uploads)
// prefers the balanced model: it accepts audio input at $0.14/M, half the
// transcribe tier's price, and the transcribe tier remains the fallback when an
// override leaves balanced text-only.
export const asyncAudioTierPreference: readonly ModelTier[] = [
  "balanced",
  "transcribe",
  "multimodal",
];
