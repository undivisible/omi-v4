export type Bindings = {
  DB: D1Database;
  FIREBASE_PROJECT_ID: string;
  TELEGRAM_WEBHOOK_SECRET?: string;
  BLOOIO_WEBHOOK_SIGNING_SECRET?: string;
  STRIPE_SECRET_KEY?: string;
  STRIPE_PRO_PRICE_ID?: string;
  STRIPE_WEBHOOK_SECRET?: string;
  APP_URL?: string;
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
