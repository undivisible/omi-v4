export type Bindings = {
  DB: D1Database;
  DELIVERY_COORDINATOR: DurableObjectNamespace;
  ASSISTANT_ADMISSION: DurableObjectNamespace;
  STT_ADMISSION: DurableObjectNamespace;
  FIREBASE_PROJECT_ID: string;
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
  MIMO_OUTPUT_MICROUSD_PER_MILLION_TOKENS?: string;
  MIMO_INPUT_MICROUSD_PER_MILLION_TOKENS?: string;
  MIMO_BUDGET_WINDOW_SECONDS?: string;
  MIMO_UID_IN_FLIGHT_LIMIT?: string;
  MIMO_GLOBAL_IN_FLIGHT_LIMIT?: string;
  MIMO_UID_TOKEN_BUDGET?: string;
  MIMO_GLOBAL_TOKEN_BUDGET?: string;
  MIMO_UID_COST_BUDGET_MICROUSD?: string;
  MIMO_GLOBAL_COST_BUDGET_MICROUSD?: string;
  GEMINI_API_KEY?: string;
  GEMINI_LIVE_MODEL?: string;
  OAUTH_TOKEN_KEY?: string;
  OPENAI_OAUTH_CLIENT_ID?: string;
  XAI_OAUTH_CLIENT_ID?: string;
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

export type AppEnv = { Bindings: Bindings; Variables: { auth: Auth } };

export type Plan = "byok" | "pro";
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
