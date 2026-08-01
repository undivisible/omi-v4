import type { ReactNode } from "react";
import {
  App,
  ColumnGroup,
  Ln,
  PrimaryActions,
  arrowStyle,
  codeStyle,
  downloadUrl,
  portalUrl,
  OmiMarkHero,
} from "../App";
import { ScrollCue, ScrollStage } from "../../scroll-stage";

const heroWords = [
  "keeps the thread",
  "remembers the room",
  "watches with your OK",
  "answers from sources",
];

const queryCards: Array<[string, string, string]> = [
  ["01", "What did we decide about the launch window?", "Memory"],
  ["02", "Summarize the last meeting while I’m still in it", "Live"],
  ["03", "Draft a follow-up from what we actually said", "Reach"],
  ["04", "Show me what changed since yesterday’s brief", "Currents"],
];

const howSteps: Array<[string, string, string, string]> = [
  [
    "01",
    "Capture without breaking flow",
    "Meetings, voice, and the pendant feed one private memory — cited, not guessed.",
    "/omi-desk-1200.webp",
  ],
  [
    "02",
    "Recall with a trail",
    "Every fact keeps a path back to where it came from. Correct it, and anything built on it updates.",
    "/omi-worn-1200.webp",
  ],
  [
    "03",
    "Act only with your OK",
    "Clicks, typing, and outbound messages ask first. Approve once; every action is recorded.",
    "/omi-pendant-1200.webp",
  ],
];

const features: Array<[string, string, string]> = [
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

const homeRail: Array<[string, string]> = [
  ["top", "Omi"],
  ["manifesto", "Manifesto"],
  ["omi-unifies", "Unifies"],
  ["how-it-works", "How"],
  ["features", "Features"],
  ["memory", "Memory"],
  ["reach", "Reach"],
  ["hardware", "Hardware"],
  ["open", "Open surface"],
  ["privacy", "Privacy"],
  ["pricing", "Pricing"],
  ["negotiate", "Negotiate"],
  ["get-started", "Start"],
  ["demo-cue", "Demo"],
];

function HomeHero() {
  return (
    <section className="cs-hero" id="top">
      <OmiMarkHero />
      <p className="cs-hero-status">
        <span className="cs-hero-status-dots" aria-hidden="true">
          <i /><i /><i />
        </span>
        OMI · PRIVATE MEMORY
      </p>
      <h1 className="cs-hero-headline">
        Be here. Omi{" "}
        <span className="cs-hero-rotator" aria-live="polite">
          {heroWords.map((word, i) => (
            <span
              key={word}
              data-hero-word
              className={i === 0 ? "is-active" : undefined}
            >
              {word}
            </span>
          ))}
        </span>
      </h1>
      <p className="mid measure">
        A private memory for the things that matter while you are busy living
        them. Be here. Omi keeps the thread.
      </p>
      <div className="cs-hero-cycle" aria-hidden="true">
        <span data-hero-progress style={{ width: "25%" }} />
      </div>
      <PrimaryActions />
      <div className="cs-query-rail" aria-hidden="true">
        <div className="cs-query-track" data-query-track>
          {[...queryCards, ...queryCards].map(([num, text, tag], i) => (
            <article className="cs-query-card" key={`${num}-${i}`}>
              <p className="cs-query-num">{num}</p>
              <p className="cs-query-text">{text}</p>
              <p className="cs-query-tag">{tag}</p>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}

function HomeManifesto() {
  return (
    <section className="manifesto" id="manifesto">
      <div className="manifesto-body">
        <p className="manifesto-text">
          Most assistants forget the room the moment you leave it.
        </p>
        <p className="manifesto-text">
          <span className="manifesto-computer-word">Omi</span> is private
          memory that stays with you — on the desk, in the meeting, on the
          pendant — so you can be present while it{" "}
          <span className="manifesto-computer-works">keeps the thread</span>.
        </p>
      </div>
    </section>
  );
}

function HomeUnifies() {
  return (
    <section className="omi-unifies" id="omi-unifies" aria-label="Omi unifies">
      <div className="unifies-sticky">
        <div className="unifies-canvas" data-unifies-canvas />
        <h2 className="unifies-title" data-unifies-title>
          Omi unifies
        </h2>
      </div>
    </section>
  );
}

function HomeHowItWorks() {
  return (
    <section className="how-it-works" id="how-it-works">
      <div className="how-it-works-header">
        <p className="section-label">How it works</p>
        <h2 className="section-heading">From capture to action, cited.</h2>
      </div>
      <div className="steps-stack">
        {howSteps.map(([num, title, body, src]) => (
          <article className="step-card" key={num}>
            <div className="step-card-inner">
              <div>
                <p className="step-num">{num}</p>
                <h3 className="step-card-title">{title}</h3>
                <p className="step-card-description">{body}</p>
              </div>
              <div className="step-image">
                <img src={src} alt="" width={1200} height={670} />
              </div>
            </div>
          </article>
        ))}
      </div>
    </section>
  );
}

function HomeFeatures() {
  return (
    <section className="cs-features" id="features">
      <p className="section-label">What it does</p>
      <h2 className="section-heading">Eight ways Omi stays useful.</h2>
      <div className="feature-rows">
        {features.map(([num, title, body]) => (
          <div className="feature-row" key={num}>
            <p className="feature-number">{num}</p>
            <div>
              <h3 className="feature-title">{title}</h3>
              <p className="feature-description">{body}</p>
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

function Band({
  id,
  label,
  title,
  children,
}: {
  id: string;
  label: string;
  title: string;
  children: ReactNode;
}) {
  return (
    <section className="band wrap" id={id}>
      <div className="section-intro reveal">
        <p className="label">{label}</p>
        <h2 className="big">{title}</h2>
      </div>
      <div className="reveal">{children}</div>
    </section>
  );
}

function HomeMemory() {
  return (
    <Band id="memory" label="Memory" title="Remembered once, available everywhere you use Omi.">
      <ul className="notes">
        <li>
          <strong>On your computer.</strong> Omi keeps a private copy of what it
          has learned from chats, transcripts, and what it sees on screen — so
          recall still works when you&apos;re offline.
        </li>
        <li>
          <strong>Synced to your account.</strong> Nothing counts as remembered
          until it&apos;s safely stored in your account. Your devices catch up
          from there — so they stay consistent, not invent their own version of
          the truth.
        </li>
        <li>
          <strong>Offline, without guessing.</strong> Desktop can answer from
          the last sync. It may be a little behind; it won&apos;t make things
          up. On the web, you always see what&apos;s in your account.
        </li>
        <li>
          <strong>Cited answers.</strong> Search and chat only return things
          they can point back to. If the source is gone, the answer is gone —
          not kept without a citation.
        </li>
      </ul>
      <p className="links band-gap">
        <Ln href="/architecture#memory" style={arrowStyle}>
          How remembering stays honest →
        </Ln>
      </p>
    </Band>
  );
}

function HomeReach() {
  return (
    <Band id="reach" label="Reach" title="Same brain, other inboxes.">
      <ColumnGroup groups={reachChannels} />
      <p className="small measure band-gap">
        Link Telegram or iMessage in Settings with a short code from the app.
        Managed Omi AI billing rolls out when checkout is live; until then, bring
        your own keys or negotiate.
      </p>
    </Band>
  );
}

function HomeHardware() {
  return (
    <Band
      id="hardware"
      label="The hardware"
      title="Two and a half centimetres of listening."
    >
      <img
        className="photo photo--wide"
        src="/omi-pendant-1200.webp"
        alt="The Omi pendant, 2.5cm across, on a display plinth."
        width={1200}
        height={670}
      />
      <p className="mid measure">
        Omi is a 2.5cm disc, 1.5cm deep, on a lanyard or a wrist band. It
        records what you say and hear, streams it to your phone over Bluetooth
        LE 5.1, and keeps recording when the phone is out of range — the audio
        catches up when it comes back.
      </p>
      <ul className="notes specs">
        {specs.map(([term, value]) => (
          <li key={term}>
            <strong>{term}</strong> {value}
          </li>
        ))}
      </ul>
      <div className="shot-pair">
        <img
          className="photo"
          src="/omi-worn-1200.webp"
          alt="Omi worn on a lanyard in an open-plan office."
          width={1200}
          height={670}
        />
        <img
          className="photo"
          src="/omi-desk-1200.webp"
          alt="Omi on a meeting-room table beside two laptops."
          width={1200}
          height={670}
        />
      </div>
      <ColumnGroup groups={hardwareCapabilities} />
      <p className="small measure band-gap">
        Omi is open hardware as well as open software: the enclosure, the board
        and the firmware are published, and this build talks to the same device.
      </p>
    </Band>
  );
}

function HomeOpenSurface() {
  return (
    <Band id="open" label="Open surface" title="/mcp">
      <p className="label">
        <span style={codeStyle}>POST</span>
      </p>
      <p className="mid measure">
        Other apps can ask your second brain too — through a public HTTP API
        and an MCP server.
      </p>
      <ul className="notes">
        <li>
          <strong>The same boundary as the app.</strong> Every request carries
          your credential; every row is scoped to your account before it is
          read.
        </li>
        <li>
          <strong>OpenAI-compatible chat.</strong>{" "}
          <code style={codeStyle}>/v1/chat/completions</code> streams in the
          shape your clients already speak.
        </li>
        <li>
          <strong>Memory, Currents, channels, FaceTime.</strong> Search memory,
          list or create Currents with optional Now Brief widgets, and place
          FaceTime calls — all scoped to your account.
        </li>
      </ul>
      <p className="links band-gap">
        <a className="arrow" href="/docs/api">
          Read the API reference →
        </a>
        <a className="arrow" href="/architecture">
          See how it is built →
        </a>
      </p>
    </Band>
  );
}

function HomePrivacy() {
  return (
    <Band id="privacy" label="Privacy" title="Your memory stays yours.">
      <ul className="notes">
        <li>
          <strong>Your account is the source of truth.</strong> Your account is
          the source of truth.
        </li>
        <li>
          <strong>On-device summaries.</strong> Summaries can stay on your Mac.
        </li>
        <li>
          <strong>Open source.</strong> The boundary is open source.
        </li>
      </ul>
    </Band>
  );
}

function HomePricing() {
  return (
    <section className="band wrap" id="pricing">
      <div className="section-intro reveal">
        <p className="label">Pricing</p>
      </div>
      <div className="plans reveal">
        <div className="plan">
          <p className="label">Omi with your own keys</p>
          <p className="big">More than 60% off</p>
          <p className="small">vs managed Omi AI at ~$35/month</p>
          <p className="small measure">
            Sign in with an xAI or ChatGPT subscription you already pay for and
            there is no separate inference bill, or bring an API key for OpenAI,
            Anthropic, Gemini or a compatible endpoint and pay that provider
            directly. Either way, what you settle with Omi is Omi&apos;s own
            price, and that is the figure you negotiate.
          </p>
          <a className="btn btn-line" href="#negotiate">
            Negotiate
          </a>
        </div>
        <div className="plan">
          <p className="label">Omi AI</p>
          <p className="big">
            ~$35 <span className="small">/ month, managed</span>
          </p>
          <p className="small">No keys, no provider accounts. We run them.</p>
          <p className="small">
            Checkout opens when billing is live; until then, bring your own keys
            or negotiate.
          </p>
          <a className="btn btn-solid" href={portalUrl}>
            Open Omi
          </a>
        </div>
      </div>
    </section>
  );
}

function HomeNegotiate() {
  return (
    <Band
      id="negotiate"
      label="Negotiate"
      title="Haggle with Omi. It is not a metaphor."
    >
      <p className="mid measure">
        Bring your own key and the price is not a plan you pick, it is a
        conversation you have. Omi opens a session, you argue your case, and
        what you agree is what you are charged — because the agreement is
        enforced on the server, not in the app.
      </p>
      <ul className="notes">
        <li>
          <strong>The model never sets the price.</strong> It may suggest at
          most one concession per reply, from a closed list the server sent it.
          The server turns codes into money.
        </li>
        <li>
          <strong>There is a floor.</strong> Grants are de-duplicated,
          subtracted from the standard price, and clamped. No combination —
          forged or replayed — lands below it.
        </li>
        <li>
          <strong>The prose cannot lie.</strong> Any figure in a reply is
          rewritten to the figure the server computed before you ever see it.
        </li>
        <li>
          <strong>Accepting recomputes.</strong> Checkout reads the agreed
          price server-side; no caller passes one in. The transcript is kept
          with the outcome.
        </li>
        <li>
          <strong>Skipping is a real path.</strong> Take the standard price and
          it is recorded like any other outcome.
        </li>
      </ul>
      <p className="links band-gap">
        <a className="btn btn-solid" href={downloadUrl}>
          Download Omi and negotiate
        </a>
        <a className="arrow" href="/architecture">
          How the band works →
        </a>
      </p>
    </Band>
  );
}

function HomeGetStarted() {
  return (
    <section className="get-started" id="get-started">
      <div className="get-started-inner">
        <h2 className="get-started-heading">Put Omi on your desk.</h2>
        <p className="get-started-sub">
          Open the app, or keep scrolling for a live demo of the desktop
          surface.
        </p>
        <a className="btn btn-solid" href={portalUrl}>
          Open Omi
        </a>
      </div>
    </section>
  );
}

function HomeDemoCue() {
  return (
    <ScrollCue
      id="demo-cue"
      align="end"
      text="keep scrolling to access a demo of the omi desktop app"
    />
  );
}

function HomeDemo() {
  return (
    <section className="home-demo" id="hub" aria-label="Omi desktop app demo">
      <div
        id="hub-frame"
        className="shot-frame"
        data-state="idle"
        tabIndex={0}
      />
    </section>
  );
}

export function HomePage() {
  return (
    <App rail={homeRail}>
      <div data-computer-stage>
        <ScrollStage>
          <HomeHero />
          <HomeManifesto />
          <HomeUnifies />
          <HomeHowItWorks />
          <HomeFeatures />
          <HomeMemory />
          <HomeReach />
          <HomeHardware />
          <HomeOpenSurface />
          <HomePrivacy />
          <HomePricing />
          <HomeNegotiate />
          <HomeGetStarted />
          <HomeDemoCue />
          <HomeDemo />
        </ScrollStage>
      </div>
    </App>
  );
}

export default HomePage;
