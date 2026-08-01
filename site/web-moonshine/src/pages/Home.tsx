import type { CSSProperties } from "react";
import {
  App,
  PrimaryActions,
  downloadUrl,
  portalUrl,
  OmiMark,
  OmiMarkHero,
} from "../App";

const homeRail: Array<[string, string]> = [
  ["top", "Omi"],
  ["omi-unifies", "Thread"],
  ["how", "How"],
  ["capabilities", "Does"],
  ["hardware", "Hardware"],
  ["reach", "Reach"],
  ["pricing", "Price"],
  ["hub", "Demo"],
];

const floatReplies: Array<[string, string, string]> = [
  ["omi", "You asked about the launch window — from Tuesday’s standup: ship Friday if QA clears the pendant sync path.", "Cited · standup"],
  ["you", "What did we decide about pricing?", ""],
  ["omi", "BYOK standard vs managed Omi AI. Negotiation session still open — floor is enforced server-side.", "Cited · chat"],
  ["omi", "Now Brief: 3 Currents need a look. Top one is the FaceTime follow-up with Maya.", "Currents"],
  ["you", "Summarize the last meeting.", ""],
  ["omi", "Live notes: 4 action items, 2 blockers. I can draft the follow-up from what was actually said.", "Meeting"],
];

const steps: Array<[string, string, string]> = [
  [
    "01",
    "Capture",
    "Meetings, voice, workspace, and the pendant feed one private memory — cited, not guessed.",
  ],
  [
    "02",
    "Recall",
    "Every claim keeps a source trail. Correct or delete it, and anything built on it updates.",
  ],
  [
    "03",
    "Act",
    "Clicks, typing, and outbound messages need your OK. Approve once; every action is recorded.",
  ],
];

const capabilities: Array<[string, string, string]> = [
  ["01", "Cited memory", "zkr keeps facts with sources. Uncited claims are dropped — search never invents."],
  ["02", "Live meetings", "System audio + mic, live transcription, structured notes while the meeting still runs."],
  ["03", "Currents & Now Brief", "What matters next, ranked and cited. The top Current can render as a Now Brief graphic."],
  ["04", "Double-Shift voice", "Both Shift keys open a small overlay — full-duplex voice without taking the screen."],
  ["05", "Approve-once actions", "Desktop computer use is two AX actions only. Destructive work waits on a server receipt."],
  ["06", "The pendant", "BLE audio to your phone; the phone relays; your desktop remembers."],
  ["07", "Telegram & iMessage", "Same conversation as desktop. Link once with a short code in Settings."],
  ["08", "FaceTime Audio", "Ask Omi to ring a phone number — a real call, not a join link."],
  ["09", "API & MCP", "REST plus streamable MCP. Scoped keys. Same account boundary as the app."],
];

const hwChips: Array<[string, string]> = [
  ["Size", "2.5cm · 1.5cm deep"],
  ["Battery", "150 mAh · 10–14h"],
  ["Radio", "Bluetooth 5.1"],
  ["Disk", "AES-256-GCM"],
  ["Transit", "TLS"],
  ["Training", "Never on your data"],
];

function SectionMark() {
  return (
    <OmiMark variant="omi-mark--sm" className="ed-section-mark" decorative />
  );
}

function HomeHero() {
  return (
    <section className="ed-hero" id="top" data-hero>
      <div className="ed-hero-media" data-hero-media aria-hidden="true">
        <img
          src="/omi-worn-1200.webp"
          alt=""
          width={1200}
          height={670}
        />
      </div>
      <div className="ed-hero-veil" aria-hidden="true" />
      <div
        className="ed-float-replies"
        data-float-replies
        aria-hidden="true"
      >
        {floatReplies.map(([who, text, tag], i) => (
          <article
            className={`ed-float-card ed-float-card--${who}`}
            data-float-card
            style={{ "--i": String(i) } as CSSProperties}
            key={`${who}-${i}`}
          >
            <header>
              <OmiMark
                variant="omi-mark--rail"
                className="ed-float-mark"
                decorative
              />
              <span>{who === "omi" ? "Omi" : "You"}</span>
              {tag ? <em>{tag}</em> : null}
            </header>
            <p>{text}</p>
          </article>
        ))}
      </div>
      <div className="ed-hero-inner">
        <div data-hero-in>
          <OmiMarkHero className="omi-mark--on-dark" />
        </div>
        <p className="ed-kicker" data-hero-in>
          OMI · PRIVATE MEMORY
        </p>
        <h1 className="ed-hero-title" data-hero-in>
          Be here. Omi keeps the thread.
        </h1>
        <p className="ed-hero-sub" data-hero-in>
          Evidence-backed memory across desktop, pendant, and the inboxes you
          already use — with your OK before it acts.
        </p>
        <div data-hero-in>
          <PrimaryActions />
        </div>
      </div>
    </section>
  );
}

function HomeDissolve() {
  return (
    <section className="ed-dissolve" id="omi-unifies" aria-label="Omi keeps the thread">
      <div className="ed-dissolve-sticky">
        <div className="ed-thread-shader" data-thread-shader aria-hidden="true" />
        <div className="ed-dissolve-canvas" data-dissolve-canvas />
        <div className="ed-dissolve-copy" data-dissolve-copy>
          <div className="ed-dissolve-mark" data-reveal>
            <OmiMark className="omi-mark--on-dark" glow decorative={false} />
          </div>
          <p className="ed-kicker">The thread</p>
          <h2 className="ed-dissolve-title">
            Most assistants forget the room the moment you leave it.
          </h2>
          <p className="ed-dissolve-body">
            Omi keeps one continuous, cited memory — capture, currents, and
            action on every surface you use.
          </p>
        </div>
      </div>
    </section>
  );
}

function HomeHow() {
  return (
    <section className="ed-section" id="how">
      <header className="ed-section-head" data-reveal>
        <SectionMark />
        <p className="ed-kicker">How it works</p>
        <h2 className="ed-h2">Capture → recall → act.</h2>
      </header>
      <div className="ed-steps">
        {steps.map(([n, title, body]) => (
          <article className="ed-step" data-step key={n}>
            <div className="ed-step-mark" aria-hidden="true">
              <OmiMark variant="omi-mark--rail" decorative />
              <span>{n}</span>
            </div>
            <h3 className="ed-step-title">{title}</h3>
            <p className="ed-step-body">{body}</p>
          </article>
        ))}
      </div>
    </section>
  );
}

function HomeCapabilities() {
  return (
    <section className="ed-section" id="capabilities">
      <header className="ed-section-head" data-reveal>
        <SectionMark />
        <p className="ed-kicker">What it does</p>
        <h2 className="ed-h2">The omi-v4 surface, brief.</h2>
      </header>
      <div className="ed-caps" data-stagger>
        {capabilities.map(([n, title, body]) => (
          <article className="ed-cap" key={n}>
            <div className="ed-cap-top">
              <OmiMark variant="omi-mark--rail" className="ed-cap-mark" decorative />
              <p className="ed-cap-num">{n}</p>
            </div>
            <h3 className="ed-cap-title">{title}</h3>
            <p className="ed-cap-body">{body}</p>
          </article>
        ))}
      </div>
    </section>
  );
}

function HomeHardware() {
  return (
    <section className="ed-hardware" id="hardware">
      <div className="ed-hardware-inner" data-hw-stage>
        <div className="ed-hardware-copy" data-reveal>
          <SectionMark />
          <p className="ed-kicker">The hardware</p>
          <h2 className="ed-h2">Two and a half centimetres of listening.</h2>
          <p className="ed-lead">
            Omi CV1 captures the day over Bluetooth. Your phone relays; your
            desktop remembers. Open hardware, same device this build talks to.
          </p>
        </div>
        <div className="ed-hardware-stage">
          <div className="ed-hw-orbit" aria-hidden="true" data-hw-orbit>
            <OmiMark className="ed-hw-orbit-mark" decorative />
          </div>
          <img
            className="ed-hardware-photo"
            data-hw-photo
            src="/omi-pendant-1200.webp"
            alt="The Omi pendant, 2.5cm across."
            width={1200}
            height={670}
          />
          <ul className="ed-hw-chips" aria-label="Key specs">
            {hwChips.map(([label, value]) => (
              <li className="ed-hw-chip" data-hw-chip key={label}>
                <span>{label}</span>
                <strong>{value}</strong>
              </li>
            ))}
          </ul>
        </div>
        <div className="ed-hw-pillars" data-stagger>
          <div>
            <h3>Capture</h3>
            <p>Live stream or offline catch-up. Speech profiles know who said what.</p>
          </div>
          <div>
            <h3>Recall</h3>
            <p>Search summaries, tasks, and memory — or ask; it cites what it knows.</p>
          </div>
          <div>
            <h3>Automate</h3>
            <p>Meeting templates, task sync, share a transcript in one action.</p>
          </div>
        </div>
      </div>
    </section>
  );
}

function HomeReach() {
  return (
    <section className="ed-section ed-section--tight" id="reach">
      <header className="ed-section-head" data-reveal>
        <SectionMark />
        <p className="ed-kicker">Reach</p>
        <h2 className="ed-h2">Same brain, other inboxes.</h2>
      </header>
      <div className="ed-reach" data-stagger>
        <article>
          <h3>Telegram</h3>
          <p>Link with a short code. Plain-text replies in the same thread as desktop.</p>
        </article>
        <article>
          <h3>iMessage</h3>
          <p>Same linking flow. SMS/RCS fallback when the path needs it.</p>
        </article>
        <article>
          <h3>FaceTime</h3>
          <p>Place a FaceTime Audio call to a number when calling is enabled.</p>
        </article>
      </div>
    </section>
  );
}

function HomePrivacy() {
  return (
    <section className="ed-section ed-section--tight" id="privacy" data-reveal>
      <SectionMark />
      <p className="ed-kicker">Privacy</p>
      <h2 className="ed-h2">Your account is the source of truth.</h2>
      <ul className="ed-privacy">
        <li>Cloud memory is authoritative; devices may be a little behind, never invent.</li>
        <li>On-device Apple models can summarize on Mac — they do not replace cloud chat.</li>
        <li>BYOK keys stay in device secure storage. Consent is versioned before processing.</li>
      </ul>
    </section>
  );
}

function HomePricing() {
  return (
    <section className="ed-section" id="pricing">
      <header className="ed-section-head" data-reveal>
        <SectionMark />
        <p className="ed-kicker">Pricing</p>
        <h2 className="ed-h2">Managed, or bring your own keys.</h2>
      </header>
      <div className="ed-plans" data-stagger>
        <article className="ed-plan">
          <p className="ed-kicker">BYOK</p>
          <p className="ed-plan-price">More than 60% off</p>
          <p className="ed-plan-body">
            Use an xAI or ChatGPT subscription, or an API key. Inference is yours;
            what you settle with Omi is Omi&apos;s price — and you can negotiate it.
          </p>
          <a className="btn btn-line" href="#negotiate">
            Negotiate
          </a>
        </article>
        <article className="ed-plan ed-plan--solid">
          <p className="ed-kicker">Omi AI</p>
          <p className="ed-plan-price">
            ~$35 <span>/ month</span>
          </p>
          <p className="ed-plan-body">
            No keys. We run the models. Checkout when billing is live.
          </p>
          <a className="btn btn-solid" href={portalUrl}>
            Open Omi
          </a>
        </article>
      </div>
      <div className="ed-negotiate" id="negotiate" data-reveal>
        <h3>Haggle with Omi. It is not a metaphor.</h3>
        <p>
          The model never sets the price. It may suggest one concession per turn
          from a closed server list; the server turns codes into money, clamps a
          floor, and rewrites any figure in the prose before you see it.
        </p>
        <a className="btn btn-solid" href={downloadUrl}>
          Download Omi and negotiate
        </a>
      </div>
    </section>
  );
}

function HomeDemo() {
  return (
    <section className="home-demo" id="hub" aria-label="Omi desktop app demo">
      <div className="ed-demo-head" data-reveal>
        <OmiMark variant="omi-mark--sm" decorative />
        <p className="ed-kicker">Live demo</p>
        <h2 className="ed-h2">Try the desktop surface.</h2>
      </div>
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
      <div data-computer-stage className="ed-page">
        <HomeHero />
        <HomeDissolve />
        <HomeHow />
        <HomeCapabilities />
        <HomeHardware />
        <HomeReach />
        <HomePrivacy />
        <HomePricing />
        <HomeDemo />
      </div>
    </App>
  );
}

export default HomePage;
