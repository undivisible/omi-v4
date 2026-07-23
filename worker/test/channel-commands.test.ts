import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  test,
} from "bun:test";
import { Miniflare } from "miniflare";
import {
  channelCommandPrompt,
  channelCommands,
  handleChannelMessage,
  maskEmail,
} from "../src/channel-commands";
import {
  issueLinkCode,
  normalizeLinkCode,
  resolveLinkCode,
} from "../src/channel-link";
import { systemPrompt as fallbackSystemPrompt } from "../src/inbox-fallback";
import type { Bindings, Channel } from "../src/types";

const miniflare = new Miniflare({
  modules: true,
  script: "export default { fetch() { return new Response('ok') } }",
  d1Databases: ["DB"],
});

let database: D1Database;

// A rate limiter whose window can be toggled shut, to exercise the abuse cap.
let rateAllowed = true;
const rateHits: string[] = [];
const rateLimiter = {
  getByName: (name: string) => ({
    fetch: async (url: string | URL) => {
      const pathname = new URL(String(url)).pathname;
      if (pathname === "/consume") {
        rateHits.push(name);
        return Response.json(
          { allowed: rateAllowed, retryAfter: rateAllowed ? 0 : 60 },
          { status: rateAllowed ? 200 : 429 },
        );
      }
      return new Response(null, { status: 404 });
    },
  }),
} as unknown as DurableObjectNamespace;

const unlinkCalls: Array<{ uid: string; channel: string }> = [];
const deliveryCoordinator = {
  idFromName: (name: string) => ({ name }),
  get: () => ({
    fetch: async (_input: RequestInfo | URL, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body)) as {
        uid: string;
        channel: string;
      };
      unlinkCalls.push({ uid: body.uid, channel: body.channel });
      return new Response(null, { status: 204 });
    },
  }),
} as unknown as DurableObjectNamespace;

const env = (): Bindings =>
  ({
    DB: database,
    FIREBASE_PROJECT_ID: "test",
    RATE_LIMITER: rateLimiter,
    DELIVERY_COORDINATOR: deliveryCoordinator,
    TELEGRAM_WEBHOOK_SECRET: "telegram-secret",
    BLOOIO_WEBHOOK_SIGNING_SECRET: "blooio-secret",
  }) as Bindings;

const migrate = async (path: string) => {
  const sql = (await Bun.file(path).text()).replace(
    "PRAGMA foreign_keys = ON;",
    "",
  );
  for (const statement of sql.split(";").map((value) => value.trim()))
    if (statement) await database.prepare(statement).run();
};

const bind = async (
  channel: Channel,
  channelUserId: string,
  uid: string,
  verifiedAt = Date.now(),
) => {
  await database
    .prepare(
      `INSERT INTO channel_bindings
         (channel, channel_user_id, uid, verified_at, channel_chat_id)
       VALUES (?1, ?2, ?3, ?4, ?2)
       ON CONFLICT(channel, channel_user_id) DO UPDATE SET
         uid = excluded.uid, verified_at = excluded.verified_at, revoked_at = NULL`,
    )
    .bind(channel, channelUserId, uid, verifiedAt)
    .run();
};

beforeAll(async () => {
  database = await miniflare.getD1Database("DB");
  for (const file of [
    "migrations/0001_initial.sql",
    "migrations/0002_memory_and_policy.sql",
    "migrations/0003_align_kr_model.sql",
    "migrations/0004_saas_foundations.sql",
    "migrations/0005_memory_search.sql",
    "migrations/0007_channel_delivery.sql",
    "migrations/0013_conversations.sql",
    "migrations/0014_channel_inbox_dispatch.sql",
    "migrations/0022_channel_link_codes.sql",
  ])
    await migrate(file);
  const now = Date.now();
  await database
    .prepare(
      "INSERT INTO users (uid, email, created_at, updated_at) VALUES ('alpha', 'sam@example.test', ?1, ?1)",
    )
    .bind(now)
    .run();
});

afterAll(async () => {
  await miniflare.dispose();
});

beforeEach(async () => {
  rateAllowed = true;
  rateHits.length = 0;
  unlinkCalls.length = 0;
  await database.prepare("DELETE FROM channel_link_codes").run();
  await database.prepare("DELETE FROM channel_bindings").run();
});

describe("link codes", () => {
  test("issues an unambiguous code and re-issues the same one before expiry", async () => {
    const first = await issueLinkCode(env(), "telegram", "42", "42");
    expect(first).not.toBeNull();
    expect(normalizeLinkCode(first?.code)).toBe(first?.code ?? null);
    expect(first?.code).not.toMatch(/[O0I1l]/);
    const second = await issueLinkCode(env(), "telegram", "42", "42");
    expect(second?.code).toBe(first?.code ?? "");
    const rows = await database
      .prepare(
        "SELECT COUNT(*) AS count FROM channel_link_codes WHERE channel_user_id = '42'",
      )
      .first<{ count: number }>();
    expect(rows?.count).toBe(1);
  });

  test("never stores the plaintext code", async () => {
    const issued = await issueLinkCode(env(), "blooio", "+1555", "+1555");
    const stored = await database
      .prepare("SELECT code_hash FROM channel_link_codes LIMIT 1")
      .first<{ code_hash: string }>();
    expect(stored?.code_hash).not.toBe(issued?.code);
    expect(stored?.code_hash).toMatch(/^[a-f0-9]{64}$/);
  });

  test("resolves a live code and rejects expired ones", async () => {
    const issued = await issueLinkCode(env(), "telegram", "77", "77");
    const resolved = await resolveLinkCode(database, issued?.code ?? "");
    expect(resolved?.channelUserId).toBe("77");
    const later = Date.now() + 20 * 60_000;
    expect(
      await resolveLinkCode(database, issued?.code ?? "", later),
    ).toBeNull();
  });

  test("normalizes case and separators, rejects the ambiguous alphabet", async () => {
    const issued = await issueLinkCode(env(), "telegram", "88", "88");
    const code = issued?.code ?? "";
    const messy = `${code.slice(0, 3)}-${code.slice(3).toLowerCase()}`;
    expect(normalizeLinkCode(messy)).toBe(code);
    expect(normalizeLinkCode("O0I1L__")).toBeNull();
    expect(normalizeLinkCode("short")).toBeNull();
  });
});

describe("unlinked sender", () => {
  test("greets with a code instead of silence", async () => {
    const outcome = await handleChannelMessage(
      env(),
      "telegram",
      "42",
      "42",
      "hello?",
    );
    expect(outcome.enqueue).toBe(false);
    expect(outcome.reply).toContain("link code");
    const stored = await database
      .prepare("SELECT COUNT(*) AS count FROM channel_link_codes")
      .first<{ count: number }>();
    expect(stored?.count).toBe(1);
  });

  test("rate-limits code issuance so the bot cannot relay spam", async () => {
    rateAllowed = false;
    const outcome = await handleChannelMessage(
      env(),
      "telegram",
      "9",
      "9",
      "hi",
    );
    expect(outcome.reply).toBeNull();
    expect(outcome.enqueue).toBe(false);
    expect(rateHits.some((key) => key.includes("channel-link-code"))).toBe(
      true,
    );
  });

  test("/help works before linking; other commands prompt to /start", async () => {
    const help = await handleChannelMessage(
      env(),
      "telegram",
      "5",
      "5",
      "/help",
    );
    expect(help.reply).toContain("/logout");
    const status = await handleChannelMessage(
      env(),
      "telegram",
      "5",
      "5",
      "/status",
    );
    expect(status.reply).toContain("/start");
  });
});

describe("linked commands", () => {
  test("/status masks the email and reports the account", async () => {
    await bind("telegram", "42", "alpha");
    const status = await handleChannelMessage(
      env(),
      "telegram",
      "42",
      "42",
      "/status",
    );
    expect(status.reply).toContain("s***@example.test");
    expect(status.enqueue).toBe(false);
  });

  test("accepts the @botname suffix Telegram adds in groups", async () => {
    await bind("telegram", "42", "alpha");
    const status = await handleChannelMessage(
      env(),
      "telegram",
      "42",
      "42",
      "/status@omi_bot",
    );
    expect(status.reply).toContain("Linked to");
  });

  test("plain text from a linked sender reaches the assistant", async () => {
    await bind("telegram", "42", "alpha");
    const outcome = await handleChannelMessage(
      env(),
      "telegram",
      "42",
      "42",
      "hi there",
    );
    expect(outcome).toEqual({ reply: null, enqueue: true });
  });

  test("unknown command is answered locally, never sent to the model", async () => {
    await bind("telegram", "42", "alpha");
    const outcome = await handleChannelMessage(
      env(),
      "telegram",
      "42",
      "42",
      "/frobnicate",
    );
    expect(outcome.enqueue).toBe(false);
    expect(outcome.reply).toContain("/help");
  });

  test("/logout confirms first, then revokes and blocks later messages", async () => {
    await bind("telegram", "42", "alpha");
    const prompt = await handleChannelMessage(
      env(),
      "telegram",
      "42",
      "42",
      "/logout",
    );
    expect(prompt.reply).toContain("confirm");
    expect(unlinkCalls.length).toBe(0);
    const confirmed = await handleChannelMessage(
      env(),
      "telegram",
      "42",
      "42",
      "/logout confirm",
    );
    expect(confirmed.reply).toContain("Unlinked");
    expect(unlinkCalls).toEqual([{ uid: "alpha", channel: "telegram" }]);
    // The coordinator is faked here, so revoke the binding as it would, then
    // confirm a subsequent message no longer reaches the assistant.
    await database
      .prepare(
        "UPDATE channel_bindings SET revoked_at = ?1 WHERE channel = 'telegram' AND channel_user_id = '42'",
      )
      .bind(Date.now())
      .run();
    const after = await handleChannelMessage(
      env(),
      "telegram",
      "42",
      "42",
      "still there?",
    );
    expect(after.enqueue).toBe(false);
  });

  test("/clear is an alias of /reset and keeps the binding", async () => {
    await bind("telegram", "42", "alpha");
    const outcome = await handleChannelMessage(
      env(),
      "telegram",
      "42",
      "42",
      "/clear",
    );
    expect(outcome.reply).toContain("Fresh start");
    const binding = await database
      .prepare(
        "SELECT revoked_at, conversation_reset_cursor FROM channel_bindings WHERE channel = 'telegram' AND channel_user_id = '42'",
      )
      .first<{
        revoked_at: number | null;
        conversation_reset_cursor: number | null;
      }>();
    expect(binding?.revoked_at).toBeNull();
  });
});

describe("assistant awareness", () => {
  test("every command appears in the injected prompt", () => {
    for (const command of channelCommands)
      expect(channelCommandPrompt).toContain(command.name);
  });

  test("the channel-origin fallback prompt carries the command list", () => {
    expect(fallbackSystemPrompt).toContain(channelCommandPrompt);
    expect(fallbackSystemPrompt).toContain("/logout");
  });

  test("maskEmail hides the local part", () => {
    expect(maskEmail("sam@example.test")).toBe("s***@example.test");
    expect(maskEmail(null)).toBe("your Omi account");
  });
});
