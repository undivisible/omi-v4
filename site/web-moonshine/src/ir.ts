import type { CrepusIr, CrepusNode, StyleMap } from "@tschk/crepus-moonshine";

const portalUrl = "https://api.omi.tsc.hk/portal";
const apiKeysUrl = "https://api.omi.tsc.hk/portal#api-keys";
const apiDocsUrl = "https://api.omi.tsc.hk/docs/api";
const downloadUrl = "https://omi.me/download";

const inkColor = "#171716";
const creamColor = "#fffcec";
const mutedColor = "#a6a49c";
const skyColor = "#9aa0ff";

function t(content: string, style?: StyleMap): CrepusNode {
  return { kind: "text", content, style };
}

function v(children: CrepusNode[], style?: StyleMap, gap?: number): CrepusNode {
  return { kind: "stack", axis: "vertical", children, style, gap: gap ?? 8 };
}

function h(children: CrepusNode[], style?: StyleMap, gap?: number): CrepusNode {
  return { kind: "stack", axis: "horizontal", children, style, gap: gap ?? 8 };
}

function ln(href: string, content: string, style?: StyleMap): CrepusNode {
  return { kind: "link", href, content, style };
}

function ul(children: CrepusNode[], style?: StyleMap): CrepusNode {
  return { kind: "list", children, ordered: false, style };
}

function ol(children: CrepusNode[], style?: StyleMap): CrepusNode {
  return { kind: "list", children, ordered: true, style };
}

function li(children: CrepusNode[], style?: StyleMap): CrepusNode {
  return { kind: "listItem", children, style };
}

function badge(label: string, style?: StyleMap): CrepusNode {
  return { kind: "badge", label, style };
}

function img(src: string, alt: string, width?: number, height?: number): CrepusNode {
  return { kind: "image", src, alt, width, height };
}

function divider(): CrepusNode {
  return { kind: "divider", orientation: "horizontal" };
}

function spacer(size?: number): CrepusNode {
  return { kind: "spacer", size };
}

const sectionStyle: StyleMap = {
  padding: "clamp(1.25rem, 5vw, 4.5rem)",
  maxWidth: "76rem",
  margin: "0 auto",
};

const labelStyle: StyleMap = {
  fontFamily: '"Geist Pixel", "Geist Mono", monospace',
  fontSize: "11px",
  letterSpacing: "0.12em",
  textTransform: "uppercase",
  color: mutedColor,
};

const giantStyle: StyleMap = {
  fontFamily: '"Literata", Georgia, serif',
  fontSize: "clamp(2.5rem, 7vw, 5rem)",
  lineHeight: "1.05",
  fontWeight: 600,
  color: inkColor,
};

const bigStyle: StyleMap = {
  fontFamily: '"Literata", Georgia, serif',
  fontSize: "clamp(1.5rem, 4vw, 2.5rem)",
  lineHeight: "1.15",
  fontWeight: 400,
  color: inkColor,
};

const midStyle: StyleMap = {
  fontFamily: '"Arimo", sans-serif',
  fontSize: "clamp(1rem, 2.5vw, 1.25rem)",
  lineHeight: "1.5",
  color: inkColor,
};

const smallStyle: StyleMap = {
  fontFamily: '"Arimo", sans-serif',
  fontSize: "0.875rem",
  lineHeight: "1.5",
  color: mutedColor,
};

const btnSolidStyle: StyleMap = {
  display: "inline-flex",
  alignItems: "center",
  padding: "0.625rem 1.25rem",
  borderRadius: "999px",
  background: inkColor,
  color: creamColor,
  fontFamily: '"Arimo", sans-serif',
  fontSize: "0.9375rem",
  textDecoration: "none",
};

const btnLineStyle: StyleMap = {
  display: "inline-flex",
  alignItems: "center",
  padding: "0.625rem 1.25rem",
  borderRadius: "999px",
  border: `1px solid ${inkColor}`,
  color: inkColor,
  fontFamily: '"Arimo", sans-serif',
  fontSize: "0.9375rem",
  textDecoration: "none",
};

const arrowStyle: StyleMap = {
  color: skyColor,
  fontFamily: '"Arimo", sans-serif',
  fontSize: "0.9375rem",
  textDecoration: "none",
};

const noteStyle: StyleMap = {
  fontFamily: '"Arimo", sans-serif',
  fontSize: "1rem",
  lineHeight: "1.6",
  color: inkColor,
};

const codeStyle: StyleMap = {
  fontFamily: '"Geist Mono", monospace',
  fontSize: "0.875em",
  background: "rgba(25, 23, 20, 0.06)",
  padding: "0.125em 0.375em",
  borderRadius: "4px",
};

function primaryActions(): CrepusNode {
  return h(
    [
      ln(portalUrl, "Open Omi", btnSolidStyle),
      ln(apiDocsUrl, "Documentation", btnLineStyle),
      ln(apiKeysUrl, "API login", btnLineStyle),
    ],
    { flexWrap: "wrap", gap: 12 },
  );
}

const capabilities: Array<[string, string, string]> = [
  ["01", "Memory you can check", "Every fact keeps a trail back to where it came from. Correct it or delete it, and anything built on it updates with it."],
  ["02", "Live meetings", "Transcription and insight while the meeting is still going — live voice when you need a conversation, longer capture when you need the full record."],
  ["03", "Currents & Now Brief", "What matters next, ranked and cited — reshaped by what you dismiss or accept. Rich updates can show up as a clear Now Brief graphic."],
  ["04", "Voice on double-Shift", "Press both Shift keys — in the app, or from anywhere once you've allowed it. Voice opens in a small overlay so it doesn't take over your screen."],
  ["05", "Clicks and typing, with your OK", "It asks before it clicks or types. You approve once; every action is recorded."],
  ["06", "The pendant", "Captures the day over Bluetooth. Your phone relays; your desktop remembers."],
  ["07", "Telegram & iMessage", "Link Telegram or iMessage in Settings. Messages join the same conversation as desktop — replies go back when you're online."],
  ["08", "FaceTime calls", "Ask Omi to place a FaceTime Audio call to a phone number when calling is set up for your account."],
];

const specs: Array<[string, string]> = [
  ["Size", "2.5cm diameter, 1.5cm deep"],
  ["Battery", "150 mAh, 10–14 hours"],
  ["Radio", "Bluetooth 5.1; Wi-Fi 2.4/5 GHz"],
  ["Latency", "500–2000 ms live; 10–20 s offline"],
  ["Offline recording", "Yes — it catches up when the phone is back"],
  ["Charging", "Dock with pogo-pin contacts"],
  ["Languages", "25+, single, multi, or translated"],
  ["Encrypted in transit", "TLS"],
  ["Encrypted on disk", "AES-256-GCM"],
  ["Training on your data", "No"],
  ["Compatibility", "iOS 15+, Android 7+, macOS, any browser"],
  ["Water resistance", "None — keep it out of the shower"],
];

const hardwareCapabilities: Array<[string, string[]]> = [
  ["Capture everything", [
    "Transcribes everything you say and hear",
    "Automatic summaries, tasks and memories",
    "Speech profiles, so it knows who said what",
    "Live streaming or offline recording",
  ]],
  ["Recall instantly", [
    "Search summaries, tasks and memories",
    "Ask Omi: it knows you, and it can search the web",
    "A daily recap in the evening",
    "Tap and talk — Omi answers on the spot",
  ]],
  ["Automate your work", [
    "Sync tasks to the task manager you already use",
    "Custom summary templates per meeting type",
    "Folders and stars, so a week of capture stays navigable",
    "Share a transcript or a summary in one action",
  ]],
];

const reachChannels: Array<[string, string[]]> = [
  ["Telegram", [
    "Link once in Settings with a short code",
    "Messages join the same conversation as desktop",
    "Replies stay plain text on Telegram",
    "Can ask Omi to help on your computer — with your OK",
  ]],
  ["iMessage", [
    "Same linking flow with a short code from the app",
    "Messages join the same conversation as desktop",
    "You can ask Omi to help on your computer the same way — with your OK",
    "FaceTime Audio is available when calling is set up on your account",
  ]],
  ["FaceTime", [
    "Omi can place a FaceTime Audio call to a phone number",
    "It rings their phone — not a join link",
    "Needs calling to be enabled for your account",
    "Same assistant memory as chat, Telegram, and iMessage",
  ]],
];

function homeHero(): CrepusNode {
  return v([
    badge("OMI · PRIVATE MEMORY", labelStyle),
    t("Be here. Omi keeps the thread.", giantStyle),
    v([
      t("A private memory for the things that matter while you are busy living them.", midStyle),
      primaryActions(),
    ], { gap: 16 }),
  ], { ...sectionStyle, gap: 16 });
}

function homeWhatItDoes(): CrepusNode {
  return v([
    t("What it does", labelStyle),
    ol(
      capabilities.map(([index, title, body]) =>
        li([
          v([
            t(index, labelStyle),
            t(title, { ...midStyle, fontWeight: 600 }),
            t(body, noteStyle),
          ], { gap: 4 }),
        ]),
      ),
    ),
  ], { ...sectionStyle, gap: 16 });
}

function homeMemory(): CrepusNode {
  return v([
    t("Memory", labelStyle),
    t("Remembered once, available everywhere you use Omi.", { ...bigStyle, maxWidth: "40rem" }),
    ul([
      li([t("On your computer.", { fontWeight: 700 }), t(" Omi keeps a private copy of what it has learned from chats, transcripts, and what it sees on screen — so recall still works when you're offline.")]),
      li([t("Synced to your account.", { fontWeight: 700 }), t(" Nothing counts as remembered until it's safely stored in your account. Your devices catch up from there — so they stay consistent, not invent their own version of the truth.")]),
      li([t("Offline, without guessing.", { fontWeight: 700 }), t(" Desktop can answer from the last sync. It may be a little behind; it won't make things up. On the web, you always see what's in your account.")]),
      li([t("Cited answers.", { fontWeight: 700 }), t(" Search and chat only return things they can point back to. If the source is gone, the answer is gone — not kept without a citation.")]),
    ]),
    ln("/architecture#memory", "How remembering stays honest →", arrowStyle),
  ], { ...sectionStyle, gap: 16 });
}

function homeReach(): CrepusNode {
  return v([
    t("Reach", labelStyle),
    t("Same brain, other inboxes.", { ...bigStyle, maxWidth: "40rem" }),
    h(
      reachChannels.map(([title, lines]) =>
        v([
          t(title, labelStyle),
          ul(lines.map((line) => li([t(line)]))),
        ], { gap: 8 }),
      ),
      { flexWrap: "wrap", gap: 16 },
    ),
    t("Link Telegram or iMessage in Settings with a short code from the app. Managed Omi AI billing rolls out when checkout is live; until then, bring your own keys or negotiate.", { ...smallStyle, maxWidth: "40rem" }),
  ], { ...sectionStyle, gap: 16 });
}

function homeHardware(): CrepusNode {
  return v([
    t("The hardware", labelStyle),
    t("Two and a half centimetres of listening.", { ...bigStyle, maxWidth: "50rem" }),
    img("/omi-pendant-1200.webp", "The Omi pendant, 2.5cm across, on a display plinth.", 1200, 670),
    v([
      t("Omi is a 2.5cm disc, 1.5cm deep, on a lanyard or a wrist band. It records what you say and hear, streams it to your phone over Bluetooth LE 5.1, and keeps recording when the phone is out of range — the audio catches up when it comes back.", { ...midStyle, maxWidth: "40rem" }),
      ul(
        specs.map(([term, value]) =>
          li([t(term, { fontWeight: 700 }), t(` ${value}`)]),
        ),
      ),
    ], { gap: 16 }),
    h(
      [
        img("/omi-worn-1200.webp", "Omi worn on a lanyard in an open-plan office.", 1200, 670),
        img("/omi-desk-1200.webp", "Omi on a meeting-room table beside two laptops.", 1200, 670),
      ],
      { flexWrap: "wrap", gap: 16 },
    ),
    h(
      hardwareCapabilities.map(([title, lines]) =>
        v([
          t(title, labelStyle),
          ul(lines.map((line) => li([t(line)]))),
        ], { gap: 8 }),
      ),
      { flexWrap: "wrap", gap: 16 },
    ),
    t("Omi is open hardware as well as open software: the enclosure, the board and the firmware are published, and this build talks to the same device.", { ...smallStyle, maxWidth: "40rem" }),
  ], { ...sectionStyle, gap: 16 });
}

function homeOpenSurface(): CrepusNode {
  return v([
    t("Open surface", labelStyle),
    v([
      t("POST", { ...codeStyle, verticalAlign: "super" }),
      t("/mcp", { ...bigStyle, fontFamily: '"Geist Mono", monospace' }),
    ], { gap: 4 }),
    v([
      t("Other apps can ask your second brain too — through a public HTTP API and an MCP server.", { ...midStyle, maxWidth: "40rem" }),
      ul([
        li([t("The same boundary as the app.", { fontWeight: 700 }), t(" Every request carries your credential; every row is scoped to your account before it is read.")]),
        li([t("OpenAI-compatible chat.", { fontWeight: 700 }), t(" "), t("/v1/chat/completions", codeStyle), t(" streams in the shape your clients already speak.")]),
        li([t("Memory, Currents, channels, FaceTime.", { fontWeight: 700 }), t(" Search memory, list or create Currents with optional Now Brief widgets, and place FaceTime calls — all scoped to your account.")]),
        li([ln("/docs/api", "Read the API reference →", arrowStyle)]),
        li([ln("/architecture", "See how it is built →", arrowStyle)]),
      ]),
    ], { gap: 16 }),
  ], { ...sectionStyle, gap: 16 });
}

function homePrivacy(): CrepusNode {
  return v([
    t("Privacy", labelStyle),
    t("Your memory stays yours.", { ...bigStyle, maxWidth: "36rem" }),
    ul([
      li([t("Your account is the source of truth.", { fontWeight: 700 }), t(" Your account is the source of truth.")]),
      li([t("On-device summaries.", { fontWeight: 700 }), t(" Summaries can stay on your Mac.")]),
      li([t("Open source.", { fontWeight: 700 }), t(" The boundary is open source.")]),
    ]),
  ], { ...sectionStyle, gap: 16 });
}

function homePricing(): CrepusNode {
  return v([
    t("Pricing", labelStyle),
    h(
      [
        v([
          t("Omi with your own keys", labelStyle),
          t("More than 60% off", { ...bigStyle, fontWeight: 600 }),
          t("vs managed Omi AI at ~$35/month", smallStyle),
          t("Sign in with an xAI or ChatGPT subscription you already pay for and there is no separate inference bill, or bring an API key for OpenAI, Anthropic, Gemini or a compatible endpoint and pay that provider directly. Either way, what you settle with Omi is Omi's own price, and that is the figure you negotiate.", { ...smallStyle, maxWidth: "30rem" }),
          ln("#negotiate", "Negotiate", btnLineStyle),
        ], { gap: 12 }),
        v([
          t("Omi AI", labelStyle),
          v([
            t("~$35", { ...bigStyle, fontWeight: 600 }),
            t(" / month, managed", smallStyle),
          ], { gap: 0 }),
          t("No keys, no provider accounts. We run them.", smallStyle),
          t("Checkout opens when billing is live; until then, bring your own keys or negotiate.", smallStyle),
          ln(portalUrl, "Open Omi", btnSolidStyle),
        ], { gap: 12 }),
      ],
      { flexWrap: "wrap", gap: 24 },
    ),
  ], { ...sectionStyle, gap: 16 });
}

function homeNegotiate(): CrepusNode {
  return v([
    t("Negotiate", labelStyle),
    t("Haggle with Omi. It is not a metaphor.", { ...bigStyle, maxWidth: "36rem" }),
    v([
      t("Bring your own key and the price is not a plan you pick, it is a conversation you have. Omi opens a session, you argue your case, and what you agree is what you are charged — because the agreement is enforced on the server, not in the app.", { ...midStyle, maxWidth: "40rem" }),
      ul([
        li([t("The model never sets the price.", { fontWeight: 700 }), t(" It may suggest at most one concession per reply, from a closed list the server sent it. The server turns codes into money.")]),
        li([t("There is a floor.", { fontWeight: 700 }), t(" Grants are de-duplicated, subtracted from the standard price, and clamped. No combination — forged or replayed — lands below it.")]),
        li([t("The prose cannot lie.", { fontWeight: 700 }), t(" Any figure in a reply is rewritten to the figure the server computed before you ever see it.")]),
        li([t("Accepting recomputes.", { fontWeight: 700 }), t(" Checkout reads the agreed price server-side; no caller passes one in. The transcript is kept with the outcome.")]),
        li([t("Skipping is a real path.", { fontWeight: 700 }), t(" Take the standard price and it is recorded like any other outcome.")]),
      ]),
    ], { gap: 16 }),
    h(
      [
        ln(downloadUrl, "Download Omi and negotiate", btnSolidStyle),
        ln("/architecture", "How the band works →", arrowStyle),
      ],
      { flexWrap: "wrap", gap: 16 },
    ),
  ], { ...sectionStyle, gap: 16 });
}

export const homeIr: CrepusIr = {
  version: 1,
  root: [
    homeHero(),
    divider(),
    homeWhatItDoes(),
    divider(),
    homeMemory(),
    divider(),
    homeReach(),
    divider(),
    homeHardware(),
    divider(),
    homeOpenSurface(),
    divider(),
    homePrivacy(),
    divider(),
    homePricing(),
    divider(),
    homeNegotiate(),
  ],
};

const tiers: Array<[string, string, string]> = [
  ["speed", "Live meeting insights, classification, quick answers", "inception/mercury-2"],
  ["balanced", "The default — roughly 80% of traffic", "xiaomi/mimo-v2.5"],
  ["smart", "Hard reasoning", "xiaomi/mimo-v2.5-pro"],
  ["multimodal", "Vision and visual computer use", "google/gemini-3.6-flash"],
  ["search", "Web-grounded answers", "perplexity/sonar"],
];

function archHero(): CrepusNode {
  return v([
    badge("Architecture", labelStyle),
    t("Few moving parts, on purpose.", giantStyle),
    v([
      t("One app, one embedded runtime, one edge worker, one model gateway. Every box below exists in the repository today.", midStyle),
      primaryActions(),
    ], { gap: 16 }),
  ], { ...sectionStyle, gap: 16 });
}

function archRequestPath(): CrepusNode {
  return v([
    t("The request path", labelStyle),
    ul([
      li([t("The hub is linked into the app.", { fontWeight: 700 }), t(" Chat, memory, speech, the workspace scan and computer use share one process and one memory authority — no separate agent daemon.")]),
      li([t("The Worker owns the account.", { fontWeight: 700 }), t(" It verifies the Firebase ID token at the edge, then owns persistence, the memory log, currents, billing and channel delivery.")]),
      li([t("Channels share the conversation.", { fontWeight: 700 }), t(" Telegram and iMessage (Sendblue) append into the same UID-scoped ordered transport the desktop agent reads.")]),
      li([t("Realtime voice is its own path.", { fontWeight: 700 }), t(" OpenRouter is request/response only, so Gemini Live keeps a separate credential and transport.")]),
    ]),
  ], { ...sectionStyle, gap: 16 });
}

function archModelTiers(): CrepusNode {
  return v([
    t("Model tiers", labelStyle),
    t("One table, three implementations.", { ...bigStyle, maxWidth: "50rem" }),
    v([
      t("Defaults; every tier is overridable by environment variable, and mirrored in the hub, the Worker and its Rust parity port.", { ...smallStyle, maxWidth: "50rem" }),
      ul(
        tiers.map(([name, when, model]) =>
          li([
            v([
              t(name, { fontWeight: 700, fontFamily: '"Geist Mono", monospace' }),
              t(when, noteStyle),
              t(model, codeStyle),
            ], { gap: 4 }),
          ]),
        ),
      ),
    ], { gap: 12 }),
    ul([
      li([t("A tier says what a request is worth paying for.", { fontWeight: 700 }), t(" Prompt intent picks it: search and vision are detected first, hard reasoning goes to the smart tier, everything else takes the default.")]),
      li([t("A capability says what a model can carry.", { fontWeight: 700 }), t(" A request states what it needs — audio in, images, audio out — and the first tier whose model declares all of it wins. If none does, the request is refused rather than sent to a model that cannot read it.")]),
      li([t("An unverified model satisfies nothing.", { fontWeight: 700 }), t(" An override naming a model the table has not checked is refused at the point of use until it declares itself, so a typo degrades to \"unknown\" instead of being trusted.")]),
    ]),
  ], { ...sectionStyle, gap: 16 });
}

function archDataPlane(): CrepusNode {
  return v([
    t("Data plane", labelStyle),
    t("One tenant key. Yours.", { ...bigStyle, maxWidth: "40rem" }),
    ul([
      li([t("D1", { fontWeight: 700 }), t(" Users, entitlements, ordered conversations, channel bindings, currents and their approval receipts — every table scoped by account.")]),
      li([t("Vectorize", { fontWeight: 700 }), t(" The "), t("omi-memory-claims", codeStyle), t(" index, embedded by Workers AI, with a per-account metadata filter on every query.")]),
      li([t("Durable Objects", { fontWeight: 700 }), t(" Four coordinators: channel delivery, assistant and speech cost admission, and rate limiting.")]),
      li([t("Memory", { fontWeight: 700 }), t(" One append-only "), t("memory_log", codeStyle), t(" per account is the write authority. The read tables and Vectorize index are projections of it, so any of them can be dropped and rebuilt, and every device keeps a local zkr mirror at the sequence it last synced.")]),
    ]),
  ], { ...sectionStyle, gap: 16 });
}

function archMemory(): CrepusNode {
  return v([
    t("Memory", labelStyle),
    t("A log, and a view of it.", { ...bigStyle, maxWidth: "40rem" }),
    ul([
      li([t("One writer.", { fontWeight: 700 }), t(" A record is not remembered until the Worker has appended it to the account "), t("memory_log", codeStyle), t(" and assigned it a sequence. Devices mint records through zkr and capture evidence; they never decide ordering.")]),
      li([t("zkr on device.", { fontWeight: 700 }), t(" The hub opens a per-UID SQLite "), t("MemoryDb", codeStyle), t(" keyed by Firebase UID. Pending commits sync with "), t("POST /v1/memory/zkr-sync", codeStyle), t("; the mirror advances with "), t("GET /v1/memory/log", codeStyle), t(" and "), t("MemoryDb::apply", codeStyle), t(" on desktop.")]),
      li([t("Nothing is edited.", { fontWeight: 700 }), t(" A correction and a deletion are new records that reference the one they supersede, so an evidence chain is never rewritten and a citation stays stable for the life of the claim.")]),
      li([t("The tables are derived.", { fontWeight: 700 }), t(" Search, profile and evidence tables are folded forward from the log and use no wall clock, so replaying the log from zero produces the same rows as following it.")]),
      li([t("Recall is cited.", { fontWeight: 700 }), t(" A claim is returned only with the evidence that supports it, resolved to a source revision and its locator. A claim whose source has been deleted is dropped from the answer rather than returned uncited.")]),
    ]),
  ], { ...sectionStyle, gap: 16 });
}

function archChannels(): CrepusNode {
  return v([
    t("Channels", labelStyle),
    t("Other inboxes, one conversation.", { ...bigStyle, maxWidth: "40rem" }),
    ul([
      li([t("Telegram.", { fontWeight: 700 }), t(" Webhook-verified inbound updates link through a short-lived code in Settings. Messages append to the shared ordered conversation; outbound replies are plain text with crepus blocks stripped.")]),
      li([t("iMessage (Sendblue).", { fontWeight: 700 }), t(" Sendblue is the provider. The stored channel id is "), t("imessage", codeStyle), t(". DeliveryCoordinator serializes outbound sends per chat with lease-based retries.")]),
      li([t("Desktop picks up the thread.", { fontWeight: 700 }), t(" A channel message is an ordinary turn — the assistant can plan, propose computer use under the same approval gate, and append a reply that routes back through the channel.")]),
      li([t("Linking is required.", { fontWeight: 700 }), t(" Neither channel works until the user sends the bot a code from the app. Credentials live server-side only.")]),
    ]),
  ], { ...sectionStyle, gap: 16 });
}

function archApproval(): CrepusNode {
  return v([
    t("The approval gate", labelStyle),
    t("Asked for is not done.", { ...bigStyle, maxWidth: "40rem" }),
    ul([
      li([t("Two actions, named not aimed.", { fontWeight: 700 }), t(" The assistant can propose invoking an interface element or setting its value, addressed through the accessibility tree by exact name. No pointer, no keystrokes, no coordinates.")]),
      li([t("Bound before you see it.", { fontWeight: 700 }), t(" The named element must match exactly one element in a live observation. Zero matches and two matches fail the same way, and the proposal expires with the screen it described.")]),
      li([t("Approved once, spent once.", { fontWeight: 700 }), t(" Approval is per action. The receipt is consumed server-side before any effect, and the executor re-derives the request and refuses it if a single field has moved.")]),
      li([t("Unknown is its own answer.", { fontWeight: 700 }), t(" An action that may or may not have taken effect is recorded as unknown and is never retried automatically.")]),
    ]),
  ], { ...sectionStyle, gap: 16 });
}

function archFacetime(): CrepusNode {
  return v([
    t("FaceTime", labelStyle),
    t("Ring a number, not a link.", { ...bigStyle, maxWidth: "40rem" }),
    ul([
      li([t("Sendblue bridge.", { fontWeight: 700 }), t(" "), t("POST /api/v1/facetime/calls", codeStyle), t(" and MCP "), t("start_facetime_call", codeStyle), t(" call Sendblue's FaceTime start endpoint. The provider rings the handle on the recipient's device — there is no "), t("facetime.apple.com", codeStyle), t(" join URL.")]),
      li([t("E.164 only.", { fontWeight: 700 }), t(" Handles must be phone numbers in E.164 form. Email FaceTime identities are refused before anything is sent upstream.")]),
      li([t("Provisioned line required.", { fontWeight: 700 }), t(" A purchased FaceTime number on the Sendblue account is required. Without one the route returns "), t("facetime_unavailable", codeStyle), t(" — a product state, not a transient fault.")]),
      li([t("Admission and bridge.", { fontWeight: 700 }), t(" Concurrent sessions are cost-gated like managed speech. When configured, a Cloudflare Container bridge carries the realtime audio leg.")]),
    ]),
  ], { ...sectionStyle, gap: 16 });
}

function archPendant(): CrepusNode {
  return v([
    t("The pendant path", labelStyle),
    t("The firmware is the production nRF5340 tree. Live provider credentials and physical-device runs are still outstanding.", { ...smallStyle, maxWidth: "50rem" }),
    h(
      [
        ln(portalUrl, "Open Omi", btnSolidStyle),
        ln("/", "Back to Omi", btnLineStyle),
      ],
      { flexWrap: "wrap", gap: 16 },
    ),
  ], { ...sectionStyle, gap: 16 });
}

export const architectureIr: CrepusIr = {
  version: 1,
  root: [
    archHero(),
    divider(),
    archRequestPath(),
    divider(),
    archModelTiers(),
    divider(),
    archDataPlane(),
    divider(),
    archMemory(),
    divider(),
    archChannels(),
    divider(),
    archApproval(),
    divider(),
    archFacetime(),
    divider(),
    archPendant(),
  ],
};

const apiSections: Array<[string, string]> = [
  ["1-authentication", "1. Authentication"],
  ["2-rate-limits", "2. Rate limits"],
  ["3-conventions", "3. Conventions"],
  ["4-rest-endpoints", "4. REST endpoints"],
  ["5-mcp-server", "5. MCP server"],
  ["6-data-lifetime-and-deletion", "6. Data lifetime and deletion"],
  ["7-how-the-rest-of-it-works", "7. How the rest of it works"],
];

function apiHero(): CrepusNode {
  return v([
    badge("Reference", labelStyle),
    t("The public API", giantStyle),
    v([
      v([
        t("Two surfaces on one credential: a REST API under ", midStyle),
        t("/api/v1", codeStyle),
        t(" and an MCP server at ", midStyle),
        t("/mcp", codeStyle),
        t(". Everything here is scoped to a single account.", midStyle),
      ], { gap: 0 }),
      primaryActions(),
    ], { gap: 16 }),
  ], { ...sectionStyle, gap: 16 });
}

function apiContents(): CrepusNode {
  return v([
    t("Contents", labelStyle),
    ol(
      apiSections.map(([anchor, label]) =>
        li([ln(`#${anchor}`, label)]),
      ),
    ),
  ], { ...sectionStyle, gap: 16 });
}

function apiReference(): CrepusNode {
  return v([
    v([
      t("1. Authentication", { ...midStyle, fontWeight: 700 }),
      t("Every request to /api/v1/* and /mcp must carry a credential. Two are accepted: API keys (recommended for programmatic access) sent as a bearer token, and Firebase ID tokens. Keys are matched with ^omi_sk_[0-9a-f]{8}_[A-Za-z0-9_-]{43}$. Only the SHA-256 digest is persisted. Scopes include memory:read, currents:read, currents:write, conversations:read, assistant:write, facetime:write, and speech:write.", noteStyle),
    ], { gap: 8 }),
    divider(),
    v([
      t("2. Rate limits", { ...midStyle, fontWeight: 700 }),
      t("Rate limits are per-user, not per-key. Managed-AI admission gates concurrent model sessions by cost. The budget is shared across both surfaces.", noteStyle),
    ], { gap: 8 }),
    divider(),
    v([
      t("3. Conventions", { ...midStyle, fontWeight: 700 }),
      t("All responses are JSON. Timestamps are Unix milliseconds. Errors use {\"error\":\"...\",\"scope\":\"...\"} for missing scopes and JSON-RPC error code -32000 on MCP.", noteStyle),
    ], { gap: 8 }),
    divider(),
    v([
      t("4. REST endpoints", { ...midStyle, fontWeight: 700 }),
      ul([
        li([t("GET /api/v1/me", codeStyle), t(" — account identity")]),
        li([t("GET /api/v1/memory/search", codeStyle), t(" — search memories")]),
        li([t("GET /api/v1/memories", codeStyle), t(" — list memories")]),
        li([t("GET /api/v1/currents", codeStyle), t(" — list currents")]),
        li([t("POST /api/v1/currents", codeStyle), t(" — create a current")]),
        li([t("GET /api/v1/conversations/messages", codeStyle), t(" — list conversation messages")]),
        li([t("GET /api/v1/notes", codeStyle), t(" — list meeting notes")]),
        li([t("POST /api/v1/assistant/messages", codeStyle), t(" — send a message to the assistant")]),
        li([t("POST /api/v1/facetime/calls", codeStyle), t(" — place a FaceTime call")]),
        li([t("POST /api/v1/speech/transcriptions", codeStyle), t(" — transcribe audio")]),
        li([t("POST /api/v1/speech/synthesis", codeStyle), t(" — synthesise speech")]),
      ]),
    ], { gap: 8 }),
    divider(),
    v([
      t("5. MCP server", { ...midStyle, fontWeight: 700 }),
      t("The MCP server at /mcp uses MCP streamable HTTP (JSON-RPC 2.0). It accepts the same credentials and enforces the same scopes. Supported methods include initialize, tools/list, and tools/call. Tools include search_memory, list_memories, list_currents, create_current, list_conversation_messages, list_meeting_notes, ask_omi, start_facetime_call, transcribe_audio, and speak_text.", noteStyle),
    ], { gap: 8 }),
    divider(),
    v([
      t("6. Data lifetime and deletion", { ...midStyle, fontWeight: 700 }),
      t("Account deletion removes all data: memories, currents, conversations, notes, and channel bindings. The memory log is truncated and the Vectorize index is purged.", noteStyle),
    ], { gap: 8 }),
    divider(),
    v([
      t("7. How the rest of it works", { ...midStyle, fontWeight: 700 }),
      t("The Worker verifies the credential, resolves the uid, and scopes every query. The hub is linked into the Flutter app. Channels share one ordered conversation. See /architecture for the full system design.", noteStyle),
    ], { gap: 8 }),
  ], { ...sectionStyle, gap: 16 });
}

export const apiDocsIr: CrepusIr = {
  version: 1,
  root: [
    apiHero(),
    divider(),
    apiContents(),
    divider(),
    apiReference(),
  ],
};
