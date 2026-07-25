# Product brainstorm

Transcribed from a handwritten product board and corrected against the original
intent.

## Use case

**A proactive, open-source second memory — OSS, but more for developers.**

Get more from doing.

### What users want

- Good memory
- Know what to do
- Shit that works
- Responsiveness

## Talking points and K-factor

- Animations
- Proactivity
- Computer use?
- Poke/Folk parity: Bouncer, but better, over iMessage
- API and MCP prompts as a platform
- Personal
- Fucking good at remembering and knowing shit
- BYOK: $5, negotiable
- Omi inference: $35
- **Pendant: record anywhere**

## Interactions

- Messaging apps
- Proactivity features
- Realtime on desktop
- Input
- FaceTime Audio as the point of differentiation

### Notes

- Main interaction: send messages without opening the app
- Micro-interactions like Tinder and Google Photos, but for insights

## Features

- Mac agent
- Proactive computer use
- Second memory with a human-like feel

## Design

- Make it elegant
- Easy to understand
- Minimal
- Utilitarian
- Visual representations
- Delightful

**Show value everywhere.**

Asian utilitarianism; delightful.

## Future

- BCI
- Omi Glass with a display

## Stack

### Product and client

- Flutter and Dart across iOS, Android, macOS, Windows, and web
- Rinf typed bridge into the in-process Rust hub
- Native Swift macOS integrations and native Windows runners where needed
- Universal BLE for the Omi pendant
- Crepuscularity and FlowToken for AI-authored Currents

### Local hub

- Rust 2024 and Tokio
- `rs_ai` for model providers
- `rx4` for extraction, routing, ranking, and self-improvement
- `zkr` for evidence-backed temporal memory
- SQLite for the local memory mirror
- `praefectus` for approval-fenced computer use
- CoreAudio and WASAPI for desktop audio
- Apple Foundation Models for bounded local jobs on Apple Silicon

### Cloudflare

- Cloudflare Workers
- Rust `worker-rs` serving the production API
- TypeScript, Hono, and Bun Worker as the D1 migration source of truth and
  reference implementation
- D1 as the authoritative cloud memory log and relational store
- Durable Objects for ordered delivery, rate limits, admission, and realtime
  session coordination
- Vectorize for semantic memory retrieval
- Workers AI for text embeddings
- AI Gateway for provider routing, cost, and latency visibility
- Static Assets for the public site and web portal
- Containers for the planned FaceTime/Agora media bridge
- Native Workers Observability

### Identity, billing, and channels

- Firebase Authentication and Firebase UID as the tenant key
- Stripe entitlements for managed inference
- Telegram Bot API
- iMessage and FaceTime through Sendblue
- Agora for the FaceTime media bridge

### Inference

- Omi-managed inference
- Xiaomi MiMo 2.5 and MiMo 2.5 Pro
- MiMo 2.5 ASR for batch transcription
- Gemini Live for realtime voice and FaceTime
- Deepgram for the existing streaming transcription route
- Inception Mercury for the speed tier
- Perplexity Sonar for search
- OpenRouter for managed model access
- BYOK for OpenAI, Anthropic, Gemini, xAI, and OpenAI-compatible endpoints
- Local models for small, bounded jobs

## Omi v4 versus upstream Omi

The detailed, code-verified comparison lives in
[`COMPARISON.md`](../COMPARISON.md). The product-level version is:

| Area | Omi v4 | Upstream Omi | Business consequence |
| --- | --- | --- | --- |
| Product shape | Developer-first second memory that can proactively act | Broad consumer wearable, conversation, app, and integration ecosystem | v4 needs one sharp workflow; it should not race upstream on feature count |
| Client | One Flutter codebase plus an in-process Rust hub | Flutter mobile, native Swift macOS, and separate Electron Windows apps | v4 has less duplication; upstream has much more mature platform surface |
| Cloud | Cloudflare Workers, D1, Durable Objects, Vectorize, and Workers AI | GCP/FastAPI, Firestore, Redis, Pinecone, Qdrant, Typesense, and Modal | v4 is structurally simpler and cheaper to operate, but has less field proof |
| Memory | Evidence-backed `zkr` memory with an authoritative cloud log and local mirror | Server-owned conversations and memories across several search/vector services | Trust, correction, provenance, and portability can be v4's moat |
| Computer use | Two typed actions behind explicit approval and an audit trail | A broad agent/tool runtime with shell and browser capabilities | v4 is safer and easier to explain, but much less capable today |
| Hardware capture | One Omi pendant, relayed through the mobile companion | Many wearables, desktop BLE, offline WAL, and background execution | “Record anywhere” is the right promise but is not proven until background capture, WAL recovery, and physical-device testing pass |
| Channels | One shared conversation across app, web, Telegram, iMessage, and planned FaceTime Audio | Larger app/plugin ecosystem and broad integrations | v4 should win on zero-open interaction instead of building another destination app |
| Developer platform | BYOK, compatible endpoints, API/MCP direction, simple open stack | Mature SDK, MCP, app marketplace, and community integrations | Developers are a credible beachhead, but upstream currently has the broader platform |
| Pricing direction | Proposed $5 negotiated BYOK and $35 managed Omi AI | Free 1,200 listening minutes; $19/month unlimited | $35 must buy actions, proactivity, and reachability—not only inference |

## Codex opinion

### The business

**The product is not “an open-source second brain.”** That describes the
implementation and community strategy. The sellable promise is:

> Omi remembers what you said, saw, and committed to, tells you what matters
> next, and can handle it from iMessage, FaceTime, or your computer.

Open source and BYOK make developers trust and distribute it. The pendant makes
capture effortless. Evidence-backed memory makes it defensible. Proactivity and
computer use turn memory into an outcome.

The best initial customer is a developer, founder, or operator who:

- spends the day in conversations and on a computer;
- already pays for model access;
- values APIs, MCP, and inspectable data;
- will tolerate early hardware setup;
- can tell immediately when remembered context saves work.

“For developers” should define the beachhead, not make the product feel like a
framework. Lead with the finished outcome and let the developer affordances
close the trust gap.

### The order of operations

1. **Prove record anywhere.** Background mobile relay, an on-disk WAL, recovery
   after gaps, and physical pendant tests are prerequisites for the hero claim.
2. **Create one memory miracle.** After a real conversation, retrieve the exact
   commitment with evidence and surface one useful Current without being asked.
3. **Deliver it outside the app.** Let the user answer or act from iMessage or
   Telegram. FaceTime Audio becomes the premium “call my second brain” version.
4. **Act carefully.** Turn accepted Currents into the existing approval-fenced
   computer-use path. Reliability and auditability matter more than tool count.
5. **Only then add platform breadth.** API/MCP and reusable prompts should expose
   the proven loop, not compensate for a loop that does not work yet.

### Pricing

- **BYOK:** $5 can work as a developer/community plan because Cloudflare is
  inexpensive and the user pays inference. Do not make every $5 purchase a
  human negotiation. Use a visible standard price with an automatic,
  bounded early-adopter or annual concession.
- **Omi AI:** $35 is plausible only as an agent subscription: managed models,
  transcription, proactive hosted work, FaceTime Audio, higher action limits,
  and support. It is too high for “meeting notes plus chat.”
- **Free:** keep a real proof-of-value allowance. Upstream offers 1,200 listening
  minutes free, while Granola offers unlimited current notes with only 30 days
  of history. A trial should reach the memory miracle, not expire before it.
- **Meter the expensive edge:** FaceTime/realtime minutes need a quota or
  overage. Cheap MiMo tokens do not make realtime media, support, and abuse free.

The brainstorm's $5 proposal is not the current implementation: the Worker is
configured for a $12 BYOK standard price and a $7 floor, and Stripe is disabled
during testing. Treat $5/$35 as a pricing hypothesis until retention, usage, and
provider costs are measured.

### K-factor

The K-factor should come from useful outputs, not a generic referral screen:

- an insight or Current that is good enough to forward in iMessage;
- a shared prompt, MCP workflow, or automation that requires Omi to run;
- an opt-in “captured and remembered by Omi” artifact after a meeting;
- a developer publishing a reusable integration;
- a FaceTime interaction somebody demonstrates because it feels impossible.

Never leak personal-memory content to manufacture sharing. The shareable object
should be the result, template, or workflow—not the private source material.

### What to measure

- Percentage of intended audio captured without an unexplained gap
- Time from install to first cited, correct memory
- Cited-recall success rate
- Current acceptance and completion rate
- Tasks completed without opening the main app
- Week-four retained users who experienced at least one memory miracle
- Managed inference and realtime cost per retained user

There is no client product analytics in the repo today. Add only
privacy-preserving events for this funnel; do not ship broad surveillance
telemetry in a product built around ambient recording.

### What not to build yet

- More destination screens
- A general plugin marketplace
- Broad computer tools before the two approved actions are dependable
- Continuous screen recording
- BCI or glasses product work
- Animation that does not communicate capture, memory, progress, or action

Use micro-interactions where they make intelligence tangible: swipe to teach
ranking, expand to reveal evidence, hold to approve, and animate the transition
from remembered fact to completed action.

## Research checked

Checked on 2026-07-25:

- [Upstream Omi introduction](https://docs.omi.me/doc/get_started/introduction):
  fully open source, live transcription, memory, integrations, and an app
  marketplace.
- [Upstream Omi subscriptions](https://help.omi.me/en/articles/12058411-understanding-omi-subscriptions):
  1,200 free listening minutes and $19/month unlimited listening.
- [Granola pricing](https://www.granola.ai/pricing): $14/month Business with
  unlimited history, API, and MCP; $35/month Enterprise.
- [Limitless acquisition](https://www.limitless.ai/): Meta acquired Limitless,
  stopped new Pendant sales, and committed only time-bounded support for existing
  customers—a reminder that hardware alone is not the durable product.
- [Cloudflare Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/):
  $5/month paid-plan minimum with 10 million requests included.
- [Xiaomi MiMo pricing](https://mimo.mi.com/docs/en-US/price/pay-as-you-go):
  overseas MiMo 2.5 Pro at $0.435 per million input tokens and $0.87 per million
  output tokens; MiMo ASR at $0.074 per audio hour.
