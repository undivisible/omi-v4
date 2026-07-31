import {
  App,
  Badge,
  Divider,
  H,
  Ln,
  PrimaryActions,
  Section,
  T,
  V,
  bigStyle,
  btnLineStyle,
  btnSolidStyle,
  codeStyle,
  giantStyle,
  labelStyle,
  midStyle,
  noteStyle,
  portalUrl,
  smallStyle,
  strongStyle,
} from "../App";

const tiers: Array<[string, string, string]> = [
  ["speed", "Live meeting insights, classification, quick answers", "inception/mercury-2"],
  ["balanced", "The default — roughly 80% of traffic", "xiaomi/mimo-v2.5"],
  ["smart", "Hard reasoning", "xiaomi/mimo-v2.5-pro"],
  ["multimodal", "Vision and visual computer use", "google/gemini-3.6-flash"],
  ["search", "Web-grounded answers", "perplexity/sonar"],
];

function ArchHero() {
  return (
    <Section>
      <Badge style={labelStyle}>Architecture</Badge>
      <T style={giantStyle}>Few moving parts, on purpose.</T>
      <V gap={16}>
        <T style={midStyle}>
          One app, one embedded runtime, one edge worker, one model gateway.
          Every box below exists in the repository today.
        </T>
        <PrimaryActions />
      </V>
    </Section>
  );
}

function ArchRequestPath() {
  return (
    <Section>
      <T style={labelStyle}>The request path</T>
      <ul>
        <li>
          <T style={strongStyle}>The hub is linked into the app.</T>
          <T>
            {" Chat, memory, speech, the workspace scan and computer use share one process and one memory authority — no separate agent daemon."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>The Worker owns the account.</T>
          <T>
            {" It verifies the Firebase ID token at the edge, then owns persistence, the memory log, currents, billing and channel delivery."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>Channels share the conversation.</T>
          <T>
            {" Telegram and iMessage (Sendblue) append into the same UID-scoped ordered transport the desktop agent reads."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>Realtime voice is its own path.</T>
          <T>
            {" OpenRouter is request/response only, so Gemini Live keeps a separate credential and transport."}
          </T>
        </li>
      </ul>
    </Section>
  );
}

function ArchModelTiers() {
  return (
    <Section>
      <T style={labelStyle}>Model tiers</T>
      <T style={{ ...bigStyle, maxWidth: "50rem" }}>
        One table, three implementations.
      </T>
      <V gap={12}>
        <T style={{ ...smallStyle, maxWidth: "50rem" }}>
          Defaults; every tier is overridable by environment variable, and
          mirrored in the hub, the Worker and its Rust parity port.
        </T>
        <ul>
          {tiers.map(([name, when, model]) => (
            <li key={name}>
              <V gap={4}>
                <T
                  style={{
                    fontWeight: 700,
                    fontFamily: '"Geist Mono", monospace',
                  }}
                >
                  {name}
                </T>
                <T style={noteStyle}>{when}</T>
                <T style={codeStyle}>{model}</T>
              </V>
            </li>
          ))}
        </ul>
      </V>
      <ul>
        <li>
          <T style={strongStyle}>
            A tier says what a request is worth paying for.
          </T>
          <T>
            {" Prompt intent picks it: search and vision are detected first, hard reasoning goes to the smart tier, everything else takes the default."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>A capability says what a model can carry.</T>
          <T>
            {" A request states what it needs — audio in, images, audio out — and the first tier whose model declares all of it wins. If none does, the request is refused rather than sent to a model that cannot read it."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>An unverified model satisfies nothing.</T>
          <T>
            {" An override naming a model the table has not checked is refused at the point of use until it declares itself, so a typo degrades to \"unknown\" instead of being trusted."}
          </T>
        </li>
      </ul>
    </Section>
  );
}

function ArchDataPlane() {
  return (
    <Section>
      <T style={labelStyle}>Data plane</T>
      <T style={{ ...bigStyle, maxWidth: "40rem" }}>One tenant key. Yours.</T>
      <ul>
        <li>
          <T style={strongStyle}>D1</T>
          <T>
            {" Users, entitlements, ordered conversations, channel bindings, currents and their approval receipts — every table scoped by account."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>Vectorize</T>
          <T>{" The "}</T>
          <T style={codeStyle}>omi-memory-claims</T>
          <T>
            {" index, embedded by Workers AI, with a per-account metadata filter on every query."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>Durable Objects</T>
          <T>
            {" Four coordinators: channel delivery, assistant and speech cost admission, and rate limiting."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>Memory</T>
          <T>{" One append-only "}</T>
          <T style={codeStyle}>memory_log</T>
          <T>
            {" per account is the write authority. The read tables and Vectorize index are projections of it, so any of them can be dropped and rebuilt, and every device keeps a local zkr mirror at the sequence it last synced."}
          </T>
        </li>
      </ul>
    </Section>
  );
}

function ArchMemory() {
  return (
    <Section>
      <T style={labelStyle}>Memory</T>
      <T style={{ ...bigStyle, maxWidth: "40rem" }}>A log, and a view of it.</T>
      <ul>
        <li>
          <T style={strongStyle}>One writer.</T>
          <T>
            {" A record is not remembered until the Worker has appended it to the account "}
          </T>
          <T style={codeStyle}>memory_log</T>
          <T>
            {" and assigned it a sequence. Devices mint records through zkr and capture evidence; they never decide ordering."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>zkr on device.</T>
          <T>{" The hub opens a per-UID SQLite "}</T>
          <T style={codeStyle}>MemoryDb</T>
          <T>{" keyed by Firebase UID. Pending commits sync with "}</T>
          <T style={codeStyle}>POST /v1/memory/zkr-sync</T>
          <T>{"; the mirror advances with "}</T>
          <T style={codeStyle}>GET /v1/memory/log</T>
          <T>{" and "}</T>
          <T style={codeStyle}>MemoryDb::apply</T>
          <T>{" on desktop."}</T>
        </li>
        <li>
          <T style={strongStyle}>Nothing is edited.</T>
          <T>
            {" A correction and a deletion are new records that reference the one they supersede, so an evidence chain is never rewritten and a citation stays stable for the life of the claim."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>The tables are derived.</T>
          <T>
            {" Search, profile and evidence tables are folded forward from the log and use no wall clock, so replaying the log from zero produces the same rows as following it."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>Recall is cited.</T>
          <T>
            {" A claim is returned only with the evidence that supports it, resolved to a source revision and its locator. A claim whose source has been deleted is dropped from the answer rather than returned uncited."}
          </T>
        </li>
      </ul>
    </Section>
  );
}

function ArchChannels() {
  return (
    <Section>
      <T style={labelStyle}>Channels</T>
      <T style={{ ...bigStyle, maxWidth: "40rem" }}>
        Other inboxes, one conversation.
      </T>
      <ul>
        <li>
          <T style={strongStyle}>Telegram.</T>
          <T>
            {" Webhook-verified inbound updates link through a short-lived code in Settings. Messages append to the shared ordered conversation; outbound replies are plain text with crepus blocks stripped."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>iMessage (Sendblue).</T>
          <T>{" Sendblue is the provider. The stored channel id is "}</T>
          <T style={codeStyle}>imessage</T>
          <T>
            {". DeliveryCoordinator serializes outbound sends per chat with lease-based retries."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>Desktop picks up the thread.</T>
          <T>
            {" A channel message is an ordinary turn — the assistant can plan, propose computer use under the same approval gate, and append a reply that routes back through the channel."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>Linking is required.</T>
          <T>
            {" Neither channel works until the user sends the bot a code from the app. Credentials live server-side only."}
          </T>
        </li>
      </ul>
    </Section>
  );
}

function ArchApproval() {
  return (
    <Section>
      <T style={labelStyle}>The approval gate</T>
      <T style={{ ...bigStyle, maxWidth: "40rem" }}>Asked for is not done.</T>
      <ul>
        <li>
          <T style={strongStyle}>Two actions, named not aimed.</T>
          <T>
            {" The assistant can propose invoking an interface element or setting its value, addressed through the accessibility tree by exact name. No pointer, no keystrokes, no coordinates."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>Bound before you see it.</T>
          <T>
            {" The named element must match exactly one element in a live observation. Zero matches and two matches fail the same way, and the proposal expires with the screen it described."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>Approved once, spent once.</T>
          <T>
            {" Approval is per action. The receipt is consumed server-side before any effect, and the executor re-derives the request and refuses it if a single field has moved."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>Unknown is its own answer.</T>
          <T>
            {" An action that may or may not have taken effect is recorded as unknown and is never retried automatically."}
          </T>
        </li>
      </ul>
    </Section>
  );
}

function ArchFacetime() {
  return (
    <Section>
      <T style={labelStyle}>FaceTime</T>
      <T style={{ ...bigStyle, maxWidth: "40rem" }}>Ring a number, not a link.</T>
      <ul>
        <li>
          <T style={strongStyle}>Sendblue bridge.</T>
          <T>{" "}</T>
          <T style={codeStyle}>POST /api/v1/facetime/calls</T>
          <T>{" and MCP "}</T>
          <T style={codeStyle}>start_facetime_call</T>
          <T>
            {" call Sendblue's FaceTime start endpoint. The provider rings the handle on the recipient's device — there is no "}
          </T>
          <T style={codeStyle}>facetime.apple.com</T>
          <T>{" join URL."}</T>
        </li>
        <li>
          <T style={strongStyle}>E.164 only.</T>
          <T>
            {" Handles must be phone numbers in E.164 form. Email FaceTime identities are refused before anything is sent upstream."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>Provisioned line required.</T>
          <T>
            {" A purchased FaceTime number on the Sendblue account is required. Without one the route returns "}
          </T>
          <T style={codeStyle}>facetime_unavailable</T>
          <T>{" — a product state, not a transient fault."}</T>
        </li>
        <li>
          <T style={strongStyle}>Admission and bridge.</T>
          <T>
            {" Concurrent sessions are cost-gated like managed speech. When configured, a Cloudflare Container bridge carries the realtime audio leg."}
          </T>
        </li>
      </ul>
    </Section>
  );
}

function ArchPendant() {
  return (
    <Section>
      <T style={labelStyle}>The pendant path</T>
      <T style={{ ...smallStyle, maxWidth: "50rem" }}>
        The firmware is the production nRF5340 tree. Live provider credentials
        and physical-device runs are still outstanding.
      </T>
      <H style={{ flexWrap: "wrap", gap: 16 }}>
        <Ln href={portalUrl} style={btnSolidStyle}>
          Open Omi
        </Ln>
        <Ln href="/" style={btnLineStyle}>
          Back to Omi
        </Ln>
      </H>
    </Section>
  );
}

export function ArchitecturePage() {
  return (
    <App>
      <ArchHero />
      <Divider />
      <ArchRequestPath />
      <Divider />
      <ArchModelTiers />
      <Divider />
      <ArchDataPlane />
      <Divider />
      <ArchMemory />
      <Divider />
      <ArchChannels />
      <Divider />
      <ArchApproval />
      <Divider />
      <ArchFacetime />
      <Divider />
      <ArchPendant />
    </App>
  );
}

export default ArchitecturePage;
