import {
  App,
  Badge,
  ColumnGroup,
  Divider,
  H,
  Ln,
  PrimaryActions,
  Section,
  T,
  V,
  arrowStyle,
  bigStyle,
  btnLineStyle,
  btnSolidStyle,
  codeStyle,
  giantStyle,
  labelStyle,
  midStyle,
  noteStyle,
  portalUrl,
  downloadUrl,
  smallStyle,
  strongStyle,
} from "../App";

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

function HomeHero() {
  return (
    <Section>
      <Badge style={labelStyle}>OMI · PRIVATE MEMORY</Badge>
      <T style={giantStyle}>Be here. Omi keeps the thread.</T>
      <V gap={16}>
        <T style={midStyle}>
          A private memory for the things that matter while you are busy living
          them.
        </T>
        <PrimaryActions />
      </V>
    </Section>
  );
}

function HomeWhatItDoes() {
  return (
    <Section>
      <T style={labelStyle}>What it does</T>
      <ol>
        {capabilities.map(([index, title, body]) => (
          <li key={index}>
            <V gap={4}>
              <T style={labelStyle}>{index}</T>
              <T style={{ ...midStyle, fontWeight: 600 }}>{title}</T>
              <T style={noteStyle}>{body}</T>
            </V>
          </li>
        ))}
      </ol>
    </Section>
  );
}

function HomeMemory() {
  return (
    <Section>
      <T style={labelStyle}>Memory</T>
      <T style={{ ...bigStyle, maxWidth: "40rem" }}>
        Remembered once, available everywhere you use Omi.
      </T>
      <ul>
        <li>
          <T style={strongStyle}>On your computer.</T>
          <T>
            {" Omi keeps a private copy of what it has learned from chats, transcripts, and what it sees on screen — so recall still works when you're offline."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>Synced to your account.</T>
          <T>
            {" Nothing counts as remembered until it's safely stored in your account. Your devices catch up from there — so they stay consistent, not invent their own version of the truth."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>Offline, without guessing.</T>
          <T>
            {" Desktop can answer from the last sync. It may be a little behind; it won't make things up. On the web, you always see what's in your account."}
          </T>
        </li>
        <li>
          <T style={strongStyle}>Cited answers.</T>
          <T>
            {" Search and chat only return things they can point back to. If the source is gone, the answer is gone — not kept without a citation."}
          </T>
        </li>
      </ul>
      <Ln href="/architecture#memory" style={arrowStyle}>
        How remembering stays honest →
      </Ln>
    </Section>
  );
}

function HomeReach() {
  return (
    <Section>
      <T style={labelStyle}>Reach</T>
      <T style={{ ...bigStyle, maxWidth: "40rem" }}>
        Same brain, other inboxes.
      </T>
      <ColumnGroup groups={reachChannels} />
      <T style={{ ...smallStyle, maxWidth: "40rem" }}>
        Link Telegram or iMessage in Settings with a short code from the app.
        Managed Omi AI billing rolls out when checkout is live; until then, bring
        your own keys or negotiate.
      </T>
    </Section>
  );
}

function HomeHardware() {
  return (
    <Section>
      <T style={labelStyle}>The hardware</T>
      <T style={{ ...bigStyle, maxWidth: "50rem" }}>
        Two and a half centimetres of listening.
      </T>
      <img
        src="/omi-pendant-1200.webp"
        alt="The Omi pendant, 2.5cm across, on a display plinth."
        width={1200}
        height={670}
      />
      <V gap={16}>
        <T style={{ ...midStyle, maxWidth: "40rem" }}>
          Omi is a 2.5cm disc, 1.5cm deep, on a lanyard or a wrist band. It
          records what you say and hear, streams it to your phone over Bluetooth
          LE 5.1, and keeps recording when the phone is out of range — the audio
          catches up when it comes back.
        </T>
        <ul>
          {specs.map(([term, value]) => (
            <li key={term}>
              <T style={strongStyle}>{term}</T>
              <T>{` ${value}`}</T>
            </li>
          ))}
        </ul>
      </V>
      <H style={{ flexWrap: "wrap", gap: 16 }}>
        <img
          src="/omi-worn-1200.webp"
          alt="Omi worn on a lanyard in an open-plan office."
          width={1200}
          height={670}
        />
        <img
          src="/omi-desk-1200.webp"
          alt="Omi on a meeting-room table beside two laptops."
          width={1200}
          height={670}
        />
      </H>
      <ColumnGroup groups={hardwareCapabilities} />
      <T style={{ ...smallStyle, maxWidth: "40rem" }}>
        Omi is open hardware as well as open software: the enclosure, the board
        and the firmware are published, and this build talks to the same device.
      </T>
    </Section>
  );
}

function HomeOpenSurface() {
  return (
    <Section>
      <T style={labelStyle}>Open surface</T>
      <V gap={4}>
        <T style={{ ...codeStyle, verticalAlign: "super" }}>POST</T>
        <T style={{ ...bigStyle, fontFamily: '"Geist Mono", monospace' }}>
          /mcp
        </T>
      </V>
      <V gap={16}>
        <T style={{ ...midStyle, maxWidth: "40rem" }}>
          Other apps can ask your second brain too — through a public HTTP API
          and an MCP server.
        </T>
        <ul>
          <li>
            <T style={strongStyle}>The same boundary as the app.</T>
            <T>
              {" Every request carries your credential; every row is scoped to your account before it is read."}
            </T>
          </li>
          <li>
            <T style={strongStyle}>OpenAI-compatible chat.</T>
            <T>{" "}</T>
            <T style={codeStyle}>/v1/chat/completions</T>
            <T>{" streams in the shape your clients already speak."}</T>
          </li>
          <li>
            <T style={strongStyle}>Memory, Currents, channels, FaceTime.</T>
            <T>
              {" Search memory, list or create Currents with optional Now Brief widgets, and place FaceTime calls — all scoped to your account."}
            </T>
          </li>
          <li>
            <Ln href="/docs/api" style={arrowStyle}>
              Read the API reference →
            </Ln>
          </li>
          <li>
            <Ln href="/architecture" style={arrowStyle}>
              See how it is built →
            </Ln>
          </li>
        </ul>
      </V>
    </Section>
  );
}

function HomePrivacy() {
  return (
    <Section>
      <T style={labelStyle}>Privacy</T>
      <T style={{ ...bigStyle, maxWidth: "36rem" }}>Your memory stays yours.</T>
      <ul>
        <li>
          <T style={strongStyle}>Your account is the source of truth.</T>
          <T>{" Your account is the source of truth."}</T>
        </li>
        <li>
          <T style={strongStyle}>On-device summaries.</T>
          <T>{" Summaries can stay on your Mac."}</T>
        </li>
        <li>
          <T style={strongStyle}>Open source.</T>
          <T>{" The boundary is open source."}</T>
        </li>
      </ul>
    </Section>
  );
}

function HomePricing() {
  return (
    <Section>
      <T style={labelStyle}>Pricing</T>
      <H style={{ flexWrap: "wrap", gap: 24 }}>
        <V gap={12}>
          <T style={labelStyle}>Omi with your own keys</T>
          <T style={{ ...bigStyle, fontWeight: 600 }}>More than 60% off</T>
          <T style={smallStyle}>vs managed Omi AI at ~$35/month</T>
          <T style={{ ...smallStyle, maxWidth: "30rem" }}>
            Sign in with an xAI or ChatGPT subscription you already pay for and
            there is no separate inference bill, or bring an API key for OpenAI,
            Anthropic, Gemini or a compatible endpoint and pay that provider
            directly. Either way, what you settle with Omi is Omi's own price,
            and that is the figure you negotiate.
          </T>
          <Ln href="#negotiate" style={btnLineStyle}>
            Negotiate
          </Ln>
        </V>
        <V gap={12}>
          <T style={labelStyle}>Omi AI</T>
          <V gap={0}>
            <T style={{ ...bigStyle, fontWeight: 600 }}>~$35</T>
            <T style={smallStyle}> / month, managed</T>
          </V>
          <T style={smallStyle}>
            No keys, no provider accounts. We run them.
          </T>
          <T style={smallStyle}>
            Checkout opens when billing is live; until then, bring your own keys
            or negotiate.
          </T>
          <Ln href={portalUrl} style={btnSolidStyle}>
            Open Omi
          </Ln>
        </V>
      </H>
    </Section>
  );
}

function HomeNegotiate() {
  return (
    <Section>
      <T style={labelStyle}>Negotiate</T>
      <T style={{ ...bigStyle, maxWidth: "36rem" }}>
        Haggle with Omi. It is not a metaphor.
      </T>
      <V gap={16}>
        <T style={{ ...midStyle, maxWidth: "40rem" }}>
          Bring your own key and the price is not a plan you pick, it is a
          conversation you have. Omi opens a session, you argue your case, and
          what you agree is what you are charged — because the agreement is
          enforced on the server, not in the app.
        </T>
        <ul>
          <li>
            <T style={strongStyle}>The model never sets the price.</T>
            <T>
              {" It may suggest at most one concession per reply, from a closed list the server sent it. The server turns codes into money."}
            </T>
          </li>
          <li>
            <T style={strongStyle}>There is a floor.</T>
            <T>
              {" Grants are de-duplicated, subtracted from the standard price, and clamped. No combination — forged or replayed — lands below it."}
            </T>
          </li>
          <li>
            <T style={strongStyle}>The prose cannot lie.</T>
            <T>
              {" Any figure in a reply is rewritten to the figure the server computed before you ever see it."}
            </T>
          </li>
          <li>
            <T style={strongStyle}>Accepting recomputes.</T>
            <T>
              {" Checkout reads the agreed price server-side; no caller passes one in. The transcript is kept with the outcome."}
            </T>
          </li>
          <li>
            <T style={strongStyle}>Skipping is a real path.</T>
            <T>
              {" Take the standard price and it is recorded like any other outcome."}
            </T>
          </li>
        </ul>
      </V>
      <H style={{ flexWrap: "wrap", gap: 16 }}>
        <Ln href={downloadUrl} style={btnSolidStyle}>
          Download Omi and negotiate
        </Ln>
        <Ln href="/architecture" style={arrowStyle}>
          How the band works →
        </Ln>
      </H>
    </Section>
  );
}

export function HomePage() {
  return (
    <App>
      <HomeHero />
      <Divider />
      <HomeWhatItDoes />
      <Divider />
      <HomeMemory />
      <Divider />
      <HomeReach />
      <Divider />
      <HomeHardware />
      <Divider />
      <HomeOpenSurface />
      <Divider />
      <HomePrivacy />
      <Divider />
      <HomePricing />
      <Divider />
      <HomeNegotiate />
    </App>
  );
}

export default HomePage;
