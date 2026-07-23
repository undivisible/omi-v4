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
import {
  claimChannelAccount,
  liveChannelAccount,
  parseSignupAnswer,
  signUpChannelSender,
} from "../src/channel-signup";
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
const rateBlocked: string[] = [];
const rateHits: string[] = [];
const rateLimiter = {
  getByName: (name: string) => ({
    fetch: async (url: string | URL) => {
      const pathname = new URL(String(url)).pathname;
      if (pathname === "/consume") {
        rateHits.push(name);
        const allowed =
          rateAllowed && !rateBlocked.some((key) => name.includes(key));
        return Response.json(
          { allowed, retryAfter: allowed ? 0 : 60 },
          { status: allowed ? 200 : 429 },
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
    "migrations/0026_channel_accounts.sql",
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
  rateBlocked.length = 0;
  rateHits.length = 0;
  unlinkCalls.length = 0;
  await database.prepare("DELETE FROM channel_link_codes").run();
  await database.prepare("DELETE FROM channel_bindings").run();
  await database.prepare("DELETE FROM channel_accounts").run();
  await database.prepare("DELETE FROM channel_first_contact").run();
  await database.prepare("DELETE FROM users WHERE uid LIKE 'chan_%'").run();
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
  test("asks whether they have an account instead of staying silent", async () => {
    const outcome = await handleChannelMessage(
      env(),
      "telegram",
      "42",
      "42",
      "hello?",
    );
    expect(outcome.enqueue).toBe(false);
    expect(outcome.reply).toContain("Do you already have an Omi account");
    const stored = await database
      .prepare("SELECT COUNT(*) AS count FROM channel_link_codes")
      .first<{ count: number }>();
    expect(stored?.count).toBe(0);
    const asked = await database
      .prepare("SELECT COUNT(*) AS count FROM channel_first_contact")
      .first<{ count: number }>();
    expect(asked?.count).toBe(1);
  });

  test("answering yes falls through to the unchanged code-linking path", async () => {
    await handleChannelMessage(env(), "telegram", "42", "42", "hi");
    const outcome = await handleChannelMessage(
      env(),
      "telegram",
      "42",
      "42",
      "Yes, I do!",
    );
    expect(outcome.reply).toContain("link code");
    const stored = await database
      .prepare("SELECT COUNT(*) AS count FROM channel_link_codes")
      .first<{ count: number }>();
    expect(stored?.count).toBe(1);
    const account = await liveChannelAccount(database, "telegram", "42");
    expect(account).toBeNull();
  });

  test("answering no signs the sender up and binds the chat", async () => {
    await handleChannelMessage(env(), "telegram", "77", "77", "hey");
    const outcome = await handleChannelMessage(
      env(),
      "telegram",
      "77",
      "77",
      "nope",
    );
    expect(outcome.reply).toContain("this chat is your Omi account");
    const account = await liveChannelAccount(database, "telegram", "77");
    expect(account?.uid).toMatch(/^chan_[a-f0-9]{32}$/);
    const binding = await database
      .prepare(
        "SELECT uid FROM channel_bindings WHERE channel = 'telegram' AND channel_user_id = '77'",
      )
      .first<{ uid: string }>();
    expect(binding?.uid).toBe(account?.uid ?? "");
    const after = await handleChannelMessage(
      env(),
      "telegram",
      "77",
      "77",
      "what can you do?",
    );
    expect(after).toEqual({ reply: null, enqueue: true });
  });

  test("an answer it cannot read asks again rather than guessing", async () => {
    await handleChannelMessage(env(), "telegram", "31", "31", "hello");
    const outcome = await handleChannelMessage(
      env(),
      "telegram",
      "31",
      "31",
      "what is this thing anyway",
    );
    expect(outcome.reply).toContain("Reply yes");
    expect(await liveChannelAccount(database, "telegram", "31")).toBeNull();
  });

  test("/signup creates the account without the yes/no question", async () => {
    const outcome = await handleChannelMessage(
      env(),
      "telegram",
      "55",
      "55",
      "/signup",
    );
    expect(outcome.reply).toContain("this chat is your Omi account");
    expect(await liveChannelAccount(database, "telegram", "55")).not.toBeNull();
  });

  test("signup is rate-limited per sender", async () => {
    rateBlocked.push("channel-signup:");
    const outcome = await handleChannelMessage(
      env(),
      "telegram",
      "56",
      "56",
      "/signup",
    );
    expect(outcome.reply).toBeNull();
    expect(await liveChannelAccount(database, "telegram", "56")).toBeNull();
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

describe("channel-created accounts", () => {
  test("reads however a person types yes or no", () => {
    for (const value of ["yes", "Y", "i do", "already have one", "Sure."])
      expect(parseSignupAnswer(value)).toBe("has-account");
    for (const value of ["no", "Nope!", "nah", "new", "sign me up", "i dont"])
      expect(parseSignupAnswer(value)).toBe("needs-account");
    for (const value of ["maybe", "who are you", ""])
      expect(parseSignupAnswer(value)).toBeNull();
  });

  test("a replayed signup returns the same account and one user row", async () => {
    const first = await signUpChannelSender(env(), "blooio", "+1555", "+1555");
    const second = await signUpChannelSender(env(), "blooio", "+1555", "+1555");
    expect(first.status).toBe("created");
    expect(second).toEqual({
      status: "existing",
      uid: first.status === "created" ? first.uid : "",
    });
    const users = await database
      .prepare("SELECT COUNT(*) AS count FROM users WHERE uid LIKE 'chan_%'")
      .first<{ count: number }>();
    expect(users?.count).toBe(1);
  });

  test("never overwrites a chat already linked to a real account", async () => {
    await bind("telegram", "42", "alpha");
    const result = await signUpChannelSender(env(), "telegram", "42", "42");
    expect(result.status).toBe("conflict");
    const binding = await database
      .prepare(
        "SELECT uid FROM channel_bindings WHERE channel = 'telegram' AND channel_user_id = '42'",
      )
      .first<{ uid: string }>();
    expect(binding?.uid).toBe("alpha");
  });

  test("claiming retires the placeholder so the handle cannot be reused", async () => {
    const created = await signUpChannelSender(env(), "telegram", "61", "61");
    const uid = created.status === "created" ? created.uid : "";
    expect(await claimChannelAccount(database, "telegram", "61", "alpha")).toBe(
      uid,
    );
    expect(await liveChannelAccount(database, "telegram", "61")).toBeNull();
    expect(
      await claimChannelAccount(database, "telegram", "61", "mallory"),
    ).toBeNull();
  });

  test("/status and /whoami say the chat is the account", async () => {
    await signUpChannelSender(env(), "telegram", "62", "62");
    const status = await handleChannelMessage(
      env(),
      "telegram",
      "62",
      "62",
      "/status",
    );
    expect(status.reply).toContain("This chat is your Omi account");
    const whoami = await handleChannelMessage(
      env(),
      "telegram",
      "62",
      "62",
      "/whoami",
    );
    expect(whoami.reply).toContain("lives in this chat");
  });

  test("/logout explains, then closes the account and retires the row", async () => {
    const created = await signUpChannelSender(env(), "telegram", "63", "63");
    const uid = created.status === "created" ? created.uid : "";
    const prompt = await handleChannelMessage(
      env(),
      "telegram",
      "63",
      "63",
      "/logout",
    );
    expect(prompt.reply).toContain("no separate login");
    expect(unlinkCalls.length).toBe(0);
    const confirmed = await handleChannelMessage(
      env(),
      "telegram",
      "63",
      "63",
      "/logout confirm",
    );
    expect(confirmed.reply).toContain("Closed");
    expect(unlinkCalls).toEqual([{ uid, channel: "telegram" }]);
    expect(await liveChannelAccount(database, "telegram", "63")).toBeNull();
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
