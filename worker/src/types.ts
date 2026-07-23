export type Bindings = {
  DB: D1Database;
  MEMORY_VECTORS?: VectorizeIndex;
  AI?: {
    run(model: string, inputs: Record<string, unknown>): Promise<unknown>;
  };
  DELIVERY_COORDINATOR: DurableObjectNamespace;
  ASSISTANT_ADMISSION: DurableObjectNamespace;
  STT_ADMISSION: DurableObjectNamespace;
  RATE_LIMITER: DurableObjectNamespace;
  FIREBASE_PROJECT_ID: string;
  ENVIRONMENT?: string;
  TELEGRAM_WEBHOOK_SECRET?: string;
  TELEGRAM_BOT_TOKEN?: string;
  BLOOIO_WEBHOOK_SIGNING_SECRET?: string;
  BLOOIO_API_KEY?: string;
  STRIPE_SECRET_KEY?: string;
  STRIPE_PRO_PRICE_ID?: string;
  STRIPE_WEBHOOK_SECRET?: string;
  APP_URL?: string;
  FIREBASE_SERVICE_ACCOUNT_EMAIL?: string;
  FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY?: string;
  MIMO_API_KEY?: string;
  MIMO_CHAT_COMPLETIONS_URL?: string;
  MIMO_MODEL?: string;
  OMI_MODEL_SPEED?: string;
  OMI_MODEL_BALANCED?: string;
  OMI_MODEL_SMART?: string;
  OMI_MODEL_MULTIMODAL?: string;
  OMI_MODEL_SEARCH?: string;
  OMI_MODEL_TRANSCRIBE?: string;
  OMI_MODEL_SPEAK?: string;
  OPENROUTER_API_KEY?: string;
  OPENROUTER_CHAT_COMPLETIONS_URL?: string;
  SPEECH_MAX_AUDIO_SECONDS?: string;
  SPEECH_TRANSCRIBE_COST_MICROUSD_PER_MINUTE?: string;
  SPEECH_SPEAK_COST_MICROUSD_PER_MINUTE?: string;
  SPEECH_UPSTREAM_TIMEOUT_MS?: string;
  CF_AI_GATEWAY_ACCOUNT_ID?: string;
  CF_AI_GATEWAY_ID?: string;
  CF_AI_GATEWAY_TOKEN?: string;
  HEARTBEAT_URL?: string;
  MIMO_OUTPUT_MICROUSD_PER_MILLION_TOKENS?: string;
  MIMO_INPUT_MICROUSD_PER_MILLION_TOKENS?: string;
  MIMO_BUDGET_WINDOW_SECONDS?: string;
  MIMO_UID_IN_FLIGHT_LIMIT?: string;
  MIMO_GLOBAL_IN_FLIGHT_LIMIT?: string;
  MIMO_UID_TOKEN_BUDGET?: string;
  MIMO_GLOBAL_TOKEN_BUDGET?: string;
  MIMO_UID_COST_BUDGET_MICROUSD?: string;
  MIMO_GLOBAL_COST_BUDGET_MICROUSD?: string;
  BYOK_STANDARD_PRICE_CENTS?: string;
  BYOK_FLOOR_PRICE_CENTS?: string;
  BYOK_NEGOTIATION_MAX_TURNS?: string;
  BYOK_NEGOTIATION_COOLDOWN_HOURS?: string;
  BYOK_NEGOTIATION_CONCESSIONS?: string;
  DEV_FAKE_PRO?: string;
  CHANNEL_FALLBACK_RESPONDER?: string;
  GEMINI_API_KEY?: string;
  GEMINI_LIVE_MODEL?: string;
  DEEPGRAM_API_KEY?: string;
  STT_MAX_SESSION_SECONDS?: string;
  STT_COST_MICROUSD_PER_MINUTE?: string;
  STT_UPSTREAM_CONNECT_TIMEOUT_MS?: string;
  STT_CLAIM_DEADLINE_SECONDS?: string;
  STT_BUDGET_WINDOW_SECONDS?: string;
  STT_UID_IN_FLIGHT_LIMIT?: string;
  STT_GLOBAL_IN_FLIGHT_LIMIT?: string;
  STT_UID_SECONDS_BUDGET?: string;
  STT_GLOBAL_SECONDS_BUDGET?: string;
  STT_UID_COST_BUDGET_MICROUSD?: string;
  STT_GLOBAL_COST_BUDGET_MICROUSD?: string;
};

export type Auth = { uid: string; email: string | null };

export type ApiKeyScope =
  | "memory:read"
  | "currents:read"
  | "currents:write"
  | "conversations:read"
  | "assistant:write"
  | "facetime:write"
  | "speech:write";

export type ApiKeyContext = { id: string; scopes: ApiKeyScope[] };

export type AppEnv = {
  Bindings: Bindings;
  Variables: { auth: Auth; apiKey?: ApiKeyContext };
};

export type Channel = "telegram" | "blooio";

export type PersonalMemory = {
  id: string;
  content: string;
  source: string;
  evidence: MemoryEvidence[];
  profileKind: "stable" | "current";
  status: "active" | "pinned" | "archived";
  validFrom: number | null;
  validTo: number | null;
  createdAt: number;
  updatedAt: number;
};

export type MemoryEvidence = {
  id: string;
  sourceId: string;
  sourceRevisionId: string;
  quote: string;
  locator: unknown;
};

export type Current = {
  id: string;
  title: string;
  summary: string;
  status: "active" | "dismissed" | "done";
  createdAt: number;
  updatedAt: number;
};

export type UserSettings = {
  approvalMode: "ask" | "once" | "auto";
  proactiveRecommendations: boolean;
};

export type SettingsDuration = "task" | "session" | "persistent";
