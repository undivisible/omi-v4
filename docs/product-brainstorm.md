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

## Cloudflare architecture and upstream tradeoff

This is the smallest justified target architecture, not a claim that every
component is deployed today. **Capture remains local-first.** The Rust hub owns
recording, the on-disk WAL, encryption before upload, and recovery from network
loss. Cloudflare must improve sync and availability; it must never become a
prerequisite for recording or the only copy of unacknowledged audio.

| Responsibility | Omi v4 mapping | Closest upstream role | Deliberate tradeoff |
| --- | --- | --- | --- |
| Public API and policy edge | Workers authenticate requests, resolve the Firebase tenant, enforce retention policy, and orchestrate sync, deletion, and export | GCP-hosted FastAPI services | One globally deployed request layer and simpler operations, but less framework portability and less production history than upstream |
| Ordered ingest and capture health | One Durable Object per device owns the capture cursor, idempotency keys, deduplication, reconnect retries, and last-known health; use a per-user object only when cross-device ordering needs one authority | Redis-backed coordination and service state | Strong per-entity serialization removes a separate coordination service, but object boundaries and hot users must be designed and field-tested |
| Authoritative cloud journal | D1 stores tenant metadata, consent and retention settings, evidence records, sync cursors, correction history, and approval/action receipts | Firestore plus parts of the upstream service data model | Relational queries and one migration path are easier to reason about, but D1 is less mature and offers fewer portability options than upstream's broader data stack |
| Optional raw media | R2 stores only opt-in, client-encrypted raw-audio backup or export bundles, with explicit lifecycle expiry; it is not the default memory store | GCP storage infrastructure around upstream services | Cheap object storage and straightforward export are useful, but retaining ambient audio increases privacy and breach cost, so absence is the default |
| Memory retrieval | Memory is created and cited before Workers AI produces derived embeddings for Vectorize; D1 evidence remains authoritative and every vector result resolves back to it | Pinecone, Qdrant, Typesense, and Modal-backed processing | One vector service is operationally smaller, but it has less field proof and less specialized lexical, hybrid, and multi-engine flexibility |
| Model routing and cost visibility | AI Gateway observes managed-provider latency, errors, and cost without becoming the source of memory truth | Modal and upstream's multi-provider inference layer | Central visibility helps BYOK and managed inference economics, but increases Cloudflare concentration and does not replace model-level evaluation |
| Product delivery | Static Assets serves the public site and lightweight web portal beside the API | Separately hosted upstream web surfaces | One deployment boundary is simple and inexpensive, but is not itself a product advantage |

Add more Cloudflare products only when the workload proves the need:

- **Queues:** use for retryable fan-out such as embeddings, notifications, and
  integrations after the canonical D1 write. Do not put ordered capture ingest
  behind a queue; the device Durable Object and local WAL already own order and
  recovery.
- **Workflows:** use when export, account deletion, or an approved action becomes
  a long-running multi-step operation that needs durable retries and visible
  progress. Skip it for ordinary request/response work.
- **Containers:** use only for the FaceTime/Agora media bridge or a native media
  or model workload that cannot run within Workers. Skip it for the core API,
  retrieval, and standard provider calls.

Compared with upstream's GCP, FastAPI, Firestore, Redis, Pinecone, Qdrant,
Typesense, and Modal composition, this consolidates more of the system under one
vendor and should be simpler and cheaper to operate at Omi v4's current scale.
The cost is concentration, fewer escape hatches, less specialized retrieval,
and substantially less maturity and field proof. Preserve portable data formats,
the local SQLite mirror, model-provider abstractions, and rebuildable vector
indexes so Cloudflare is an implementation advantage rather than the product's
point of failure.

## Competitive field

Checked on 2026-07-25. Prices are public US prices in USD and per user unless
noted. Annual prices are monthly equivalents billed annually. Promotions, tax,
hardware, and enterprise contracts can change the effective price. Capability,
security, compliance, accuracy, battery-life, and scale statements below are
vendor claims unless the code-verified Omi v4 comparison says otherwise; they
are not independent performance findings.

### Pricing and product posture

| Product | Current public entry point | Paid plans | Product posture |
| --- | --- | --- | --- |
| Granola | Basic: free, with limited meeting history | Business: $14/month; Enterprise: $35/month | Bot-free meeting notes and cross-meeting chat, moving into team knowledge and integrations |
| Cluely | Starter: free, with limited AI and notes | Pro: $19.99/month; Pro + Undetectability: $149.99/month | Realtime, hidden on-screen assistance during calls; no public API or MCP was found |
| Otter | Basic: free | Pro: $8.33/month annually; Business: $19.99/month annually; Enterprise: custom | Mature meeting transcription, live collaboration, chat, and sales workflows |
| Fireflies | Free | Pro: $10/month annually; Business: $19/month annually; Enterprise: $39/month annually | Broad meeting capture, searchable knowledge, AI Skills, and integration automation |
| Fathom | Free for individuals | Premium: $16/month annually; Team: $15/month annually, two-seat minimum; Business: $25/month annually, two-seat minimum; Enterprise: custom | Generous individual wedge, polished recaps, team deal intelligence, API, and MCP |
| Read AI | Free: five meeting transcripts/month | Pro: $15/month annually; Enterprise: $22.50/month annually; Enterprise+: $29.75/month annually | Meeting analytics plus an assistant spanning meetings, email, chat, documents, and CRM |
| Plaud | Starter: free, 300 transcription minutes/month | Pro: $8.33/month annually or $17.99 monthly; Unlimited: $19.99/month annually or $29.99 monthly; Team launch pricing: $20/month annually | Dedicated recorders plus a post-capture workflow; hardware is purchased separately |
| Limitless | Not available to new buyers | Existing Pendant users receive Unlimited at no charge during the announced support period | Discontinued benchmark: acquired by Meta, Pendant sales ended, and non-Pendant recording was disabled |
| Bee | Pioneer wearable: $49.99 one-time, US only | Future Premium subscription: price not announced | Low-cost ambient wearable with personal summaries, facts, todos, chat, and a developer surface; iOS is current, while Android early access is not actively supported |
| Upstream Omi | Free: 1,200 listening minutes/month | Unlimited: $19/month | Open-source wearable ecosystem with live transcription, memories, apps, integrations, SDK, and MCP |
| Omi v4 | Proposed proof-of-value allowance | Proposed BYOK: $5; proposed managed Omi AI: $35 | Developer-first, evidence-backed second memory that reaches the user and acts with approval |

The Omi v4 prices are hypotheses, not current offers. The Worker is currently
configured around a $12 BYOK standard price and a $7 floor, with Stripe disabled
during testing. Cluely's pricing page title advertises Pro “from $11.99,” while
the monthly selector observed during this review showed $19.99; the table uses
the visible monthly plan price. Plaud's Team launch pricing is advertised
through 2026-08-31 and is scheduled to rise to $25/month annually. Limitless
committed to supporting existing Pendants throughout 2026, not indefinitely.

### Before, during, and after the conversation

| Product | Before | During | After |
| --- | --- | --- | --- |
| Granola | Reads calendar context; user starts a bot-free capture; templates can shape notes | Captures microphone and system audio and combines the user's typed notes with transcription | Produces notes, cross-meeting chat, shared folders, and automated posts to connected tools |
| Cluely | Loads custom instructions, files, and prior-meeting context | Provides no-bot transcript and realtime answers, objection handling, and coaching overlays | Produces notes, follow-ups, missed-opportunity analysis, and searchable past meetings |
| Otter | Calendar agent can auto-join; users can choose bot, desktop, browser, mobile, or upload capture | Shows multilingual live transcript, collaboration, summary, and AI Chat | Generates summaries, action items, cross-meeting answers, channel sharing, exports, and CRM workflows |
| Fireflies | Calendar bot can auto-join; bot-free desktop, mobile, browser, dialer, upload, and Meet SDK routes are also offered | Live Assist shows transcript, notes, catch-up, answers, and suggested actions | AskFred searches meetings; AI Skills and integrations can transform and route outputs |
| Fathom | Calendar-connected capture; the standard bot remains available; bot-free desktop modes are in beta on Mac and English-only | Newer desktop beta can capture transcript-only, audio-only, or audio and video and show a live summary | Creates recordings, transcripts, summaries, clips, action items, Account-Wide Ask, alerts, and CRM views |
| Read AI | Calendar agent or native Google integration prepares capture; desktop, mobile, and in-person modes extend it | Live transcript, dashboard, engagement, talk-time, timer, and assistant feedback | Recaps, coaching, Ask Read, scheduled updates, email/calendar/CRM actions, and workspace analytics |
| Plaud | User carries a dedicated recorder and can configure AutoFlow | One-press in-person capture or phone-call vibration capture; highlight support is advertised as coming soon | Sync triggers transcript, summary, mind map, Ask Plaud, export, sharing, and optional AutoFlow email |
| Limitless | A Pendant was paired with phone and account while it was commercially available | Pendant captured ambient audio, indicated recording with a white LED, and buffered speech when offline | The service produced transcripts and memory; current users can export or delete data during wind-down |
| Bee | User wears a low-cost button-and-LED device connected to iOS | Captures ambient conversation and processes audio in realtime without retaining the audio, according to Bee | Produces daily summaries, patterns, insights, facts, todos, chat, and developer-readable sync data |
| Upstream Omi | User pairs one of several supported wearables or uses a client capture path | Live transcription, background execution, and an offline write-ahead log support continuous capture | Builds conversations and memories, then exposes them through apps, integrations, SDK, and MCP |
| Omi v4 | Pendant pairing and shared identity exist; reliable background capture is not yet proven | Desktop realtime exists; mobile relay still lacks a durable on-disk WAL and production physical-device proof | Evidence-backed memory, Currents, shared conversations, and two approval-fenced actions exist, but the complete proactive loop still needs field proof |

This is the important category split: most meeting products optimize a scheduled
event, then create an artifact. Omi should optimize a continuing relationship:
capture wherever work happens, remember across months, interrupt only when
useful, and close the loop through a message, call, or approved action.

### Capture, consent, and privacy

| Product | Capture model | Consent and visibility | Data posture |
| --- | --- | --- | --- |
| Granola | Bot-free microphone and system-audio capture; Mac and Windows do not retain audio, while iOS temporarily caches it before deletion | The user is responsible for consent. Zoom consent messaging is currently supported only on macOS; Google Meet support is paused and iOS has no consent messaging | Notes are private by default; individual and organization training opt-outs are offered |
| Cluely | Bot-free desktop capture with an overlay marketed as invisible to screen-sharing software | The “undetectable” plan makes participant awareness an explicit product risk | Its public privacy page says it does not train on user data, while its Terms grant training rights for Free and Pro data; treat this conflict as unresolved |
| Otter | Visible meeting bot plus desktop, browser, mobile, and upload paths | Bot presence and meeting chat can disclose capture; optional pre-meeting email and enterprise affirmative-consent controls are available | Enterprise administrative, retention, and security controls are offered |
| Fireflies | Visible bot plus bot-free desktop/system audio, browser, mobile, dialer, upload, and Google Meet SDK paths | Consent can be sent by email or chat, and the bot can be paused, resumed, or removed | Fireflies claims SOC 2, GDPR, HIPAA, private storage, and no default model training |
| Fathom | Visible bot; bot-free transcript-only, audio-only, and audio/video desktop modes are beta | Offers advance consent email and visible in-meeting notice | Fathom claims SOC 2, GDPR, and HIPAA. It says subprocessors cannot train on customer data, but its own de-identified-data use is opt-out |
| Read AI | Visible bot, Google-native integration, desktop, mobile, and in-person capture | Any participant can use Read Stop for a partial report or Opt Out to delete the session | Read claims SOC 2, TLS/AES protection, and model training only with explicit opt-in |
| Plaud | Dedicated, visible hardware for in-person and phone-call capture | The owner remains responsible for lawful notice and consent; hardware is physically observable | Plaud claims ISO 27001/27701, GDPR, SOC 2, HIPAA, and EN 18031 compliance |
| Limitless | Dedicated Pendant with offline buffering and phone relay | Required proactive notice and consent, a visible white LED, and stopping capture if anyone declined | Offered granular audio retention plus export and deletion; current service is winding down |
| Bee | Dedicated wearable with button and LED; Bee says it processes audio in realtime and immediately deletes it | Terms put consent responsibility on the user, with additional care required around minors | Bee says it does not retain audio, sell personal data, or train models on user data |
| Upstream Omi | Wearables and desktop capture with background operation and durable recovery | Open hardware makes capture visible, but the application still needs explicit, jurisdiction-aware consent UX | Open source and exportability improve inspectability; deployed-service controls still matter |
| Omi v4 | Pendant, desktop system audio, and planned realtime channel capture | Must make recording state unmissable and provide participant notice, pause, delete, and retention controls before “record anywhere” is marketed broadly | Local mirror, authoritative cloud log, provenance, and BYOK are strong primitives; policy UX and field verification remain work |

Omi should explicitly reject covert or “undetectable” capture. Ambient memory
only compounds if people trust it. The defensible interaction is a clear capture
signal, a fast pause/delete path, understandable retention, and evidence that
lets the owner correct what Omi believes.

### Sharing, growth loops, APIs, MCP, and actions

| Product | Sharing and growth loop | API, MCP, integrations, and actions |
| --- | --- | --- |
| Granola | Private-by-default notes become shareable web summaries, collaborator notes, folders, and team spaces | Business includes an API and MCP; native and Zapier integrations push notes into Slack, Notion, HubSpot, Attio, Affinity, and other systems |
| Cluely | Realtime demonstrations and generated follow-ups are the visible sharing objects | Enterprise advertises CRM integrations and custom live actions; no public API or MCP was found |
| Otter | Shared transcripts, folders, channels, comments, and sales artifacts pull teammates into the workspace | Broad integrations and MCP; API and webhooks are Enterprise features |
| Fireflies | Shareable recaps and searchable team meeting knowledge support seat expansion | GraphQL API, MCP, more than 100 integrations, and more than 200 advertised AI Skills; workflows can run across meetings |
| Fathom | Free individual use, clips, share links, and team folders create a bottom-up team funnel | Public API, MCP, webhooks, OAuth, Zapier, CRM sync, alerts, and account-wide search |
| Read AI | Recaps, highlights, workspace benchmarking, and scheduled reports spread results beyond attendees | REST and live APIs are beta; MCP, webhooks, Zapier, email, CRM, and calendar actions are available |
| Plaud | Public or invite-only links can expose selected transcript, summary, mind map, and audio, with expiration controls | MCP is beta and can list or search recordings, transcripts, summaries, and action items; no general public API was found |
| Limitless | Shared memories and a developer API once extended the recorder; acquisition ended the acquisition loop | Export and API access remain relevant to user migration, not a growing platform |
| Bee | Device affordability and Markdown-readable personal data can create a hacker and automation community | CLI, local HTTP proxy, bearer-token API, realtime stream, MCP, skill support, and full Markdown sync |
| Upstream Omi | Open source, hardware choice, apps, community integrations, and shared workflows form the strongest existing developer loop | Mature SDK, API, MCP, app marketplace, integrations, and broad agent/tool runtime |
| Omi v4 | The result should travel through iMessage, Telegram, or a shared Current without exposing private source material | BYOK and compatible endpoints exist; API/MCP should expose the proven memory-to-action loop, while computer use remains two typed, approval-fenced actions |

The best K-factor is not an invitation prompt. It is a result somebody forwards,
a reusable workflow a developer publishes, or a meeting artifact that makes
another participant ask how it was produced. Private memory and raw audio should
never be the growth payload.

### Commodity versus defensible

| Increasingly commodity | Potentially defensible for Omi |
| --- | --- |
| Speech-to-text and speaker labels | Capture continuity across wearable, desktop, phone, and offline gaps |
| Generic meeting summaries and action-item extraction | Longitudinal memory with evidence, provenance, correction, and portability |
| Chat with one transcript | Correct retrieval and useful synthesis across months of personal context |
| Calendar bots and standard meeting capture | A trusted, visible, consent-aware ambient capture relationship |
| A gallery of generic note templates | AI-selected presentation that adapts to the conversation without making the user manage templates |
| Share links, clips, exports, and basic CRM sync | Zero-open delivery over iMessage, Telegram, and FaceTime Audio |
| A thin wrapper over frontier models | Reliable completion through bounded actions, approvals, receipts, and audit history |
| A long integration checklist | An open developer surface built around memory and action primitives that already work |

The moat is therefore not the transcript, model, prompt library, or number of
templates. It is the compounding system: dependable capture produces trusted
memory; trusted memory produces well-timed insight; the user corrects or accepts
it; Omi completes an action; that outcome improves future relevance.

### Explicit Omi v4 response

1. **Win “record anywhere,” not “meeting notes.”** Build background relay,
   on-disk WAL recovery, gap visibility, participant controls, and physical
   device evidence before making continuous capture the hero promise.
2. **Turn evidence-backed memory into the product moment.** Every important
   recall should expose its source, accept a correction, and make the next
   useful Current better.
3. **Let AI choose the presentation.** The user never opens a template picker.
   Omi selects the summary, decision log, follow-up, reflection, or task view
   from context; the user can correct the result, not administer a template
   library.
4. **Reach the user without another inbox.** iMessage and Telegram carry useful
   Currents and approvals; FaceTime Audio is the premium synchronous interface
   to the same memory, not a separate assistant.
5. **Open the proven loop.** API, MCP, prompts, and published workflows become
   distribution only after capture, memory, delivery, and approval-fenced action
   work as one dependable loop.

Do not copy Cluely's covert-capture posture, Plaud's template-count arms race,
or the category's habit of equating more generated text with more value.
Upstream Omi remains the hardest comparison because it already combines open
source, hardware, live capture, memory, SDK, MCP, and integrations. Omi v4 must
be narrower and unmistakably better at evidence-backed recall, zero-open
delivery, and safe completion.

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

### The phased roadmap

| Phase | Build | Exit gate |
| --- | --- | --- |
| 0. Establish truth | Instrument capture gaps, cited recall, Current acceptance, action completion, channel delivery, retention, and cost without broad surveillance telemetry | A repeatable field-test script and baseline exist for the complete pendant-to-outcome path |
| 1. Prove record anywhere | Background mobile relay, on-disk WAL, ordered replay, visible capture state, pause/delete/retention controls, and physical pendant tests | Intended audio survives app suspension, network loss, reconnect, and replay with every gap explained |
| 2. Create the memory miracle | Evidence-backed commitment recall, correction, proactive ranking, and AI-selected output presentation with no human template picker | A user receives one correct, cited, useful Current from a real conversation and can improve it with one correction |
| 3. Deliver without opening Omi | iMessage and Telegram response/approval loops, shareable result artifacts, then quota-bounded FaceTime Audio over the same identity and memory | A user can receive, answer, approve, and verify the highest-value workflow without opening the destination app |
| 4. Act and distribute | Harden the two typed computer actions, receipts and audit history, then expose the loop through API, MCP, compatible endpoints, prompts, and reusable workflows | Approved actions complete reliably, external developers can reproduce the loop, and managed inference unit economics support the proposed tiers |

Do not advance a phase because its UI exists. Advance it when the exit gate is
demonstrated with real devices, real interruptions, and traceable outcomes.

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

Official product, pricing, documentation, help, privacy, and developer pages
checked on 2026-07-25. These links support current plan and capability
descriptions; vendor claims remain vendor claims.

- **Granola:** [pricing](https://www.granola.ai/pricing),
  [consent](https://docs.granola.ai/help-center/consent-security-privacy/getting-consent),
  [security and data FAQ](https://docs.granola.ai/help-center/consent-security-privacy/security-privacy-data-faqs),
  [sharing notes](https://docs.granola.ai/help-center/sharing/sharing-notes),
  [integrations](https://docs.granola.ai/help-center/sharing/integrations/integrations-with-granola),
  [MCP](https://docs.granola.ai/help-center/sharing/integrations/mcp), and
  [API](https://docs.granola.ai/api-reference/list-notes).
- **Cluely:** [product](https://cluely.com/),
  [pricing](https://cluely.com/pricing),
  [documentation](https://docs.cluely.com/),
  [privacy policy](https://cluely.com/privacy-policy), and
  [Terms](https://cluely.com/terms).
- **Otter:** [product](https://otter.ai/),
  [pricing](https://otter.ai/pricing),
  [integrations](https://otter.ai/integrations),
  [AI Chat](https://help.otter.ai/hc/en-us/articles/19682180167575-Otter-AI-Chat-Overview),
  [recording permissions](https://help.otter.ai/hc/en-us/articles/39339238308503-Recording-Permissions-with-Otter), and
  [enterprise controls](https://help.otter.ai/hc/en-us/articles/13352505516695-Enterprise-Admin-Controls-Overview).
- **Fireflies:** [product features](https://fireflies.ai/product/features),
  [pricing](https://fireflies.ai/pricing),
  [security](https://fireflies.ai/security),
  [developer documentation](https://docs.fireflies.ai/),
  [Global AskFred](https://guide.fireflies.ai/articles/1512776728-learn-about-global-askfred),
  [AI Skills](https://guide.fireflies.ai/articles/6161594443-learn-about-ai-skills-create-automated-workflows-from-your-meetings), and
  [consent guidance](https://guide.fireflies.ai/articles/7003995379-do-i-need-to-disclose-that-i-am-recording-meetings).
- **Fathom:** [product](https://fathom.video/),
  [pricing](https://fathom.video/pricing),
  [API overview](https://developers.fathom.ai/api-overview),
  [MCP](https://developers.fathom.ai/mcp-docs),
  [webhooks](https://developers.fathom.ai/webhooks),
  [bot-free modes](https://help.fathom.video/en/articles/11577345), and
  [security and privacy](https://help.fathom.video/en/articles/296512).
- **Read AI:** [meetings](https://www.read.ai/meetings),
  [Ask Read](https://www.read.ai/ask-read),
  [pricing](https://www.read.ai/plans-pricing),
  [API reference](https://support.read.ai/hc/en-us/articles/49381161088659-API-Reference),
  [Ask Read actions](https://support.read.ai/hc/en-us/articles/48863788829971-Using-Ask-Read-actions),
  [stop and opt out](https://support.read.ai/hc/en-us/articles/52118782802579-How-to-Stop-or-Opt-Out-of-a-Read-AI-Recording-Read-AI), and
  [security and privacy](https://support.read.ai/hc/en-us/articles/25702259763091-Security-Privacy-Overview).
- **Plaud:** [AI plan pricing](https://global.plaud.ai/pages/plaud-ai-plan-pricing),
  [Plaud Note](https://www.plaud.ai/products/plaud-note-plaud-ai-pro-plan),
  [AutoFlow](https://support.plaud.ai/hc/en-us/articles/51885855749785-AutoFlow),
  [sharing](https://support.plaud.ai/hc/en-us/articles/50835493131289-Share-link),
  [export](https://support.plaud.ai/hc/en-us/articles/51023259082393-Export-files), and
  [MCP beta](https://support.plaud.ai/hc/en-us/articles/57751078986265-Plaud-MCP).
- **Limitless:** [acquisition and service status](https://www.limitless.ai/),
  [Pendant storage and relay](https://help.limitless.ai/en/articles/10761340-pendant-storage),
  [consent guidance](https://help.limitless.ai/en/articles/10540861-how-to-ask-for-consent-and-let-others-know-you-are-recording), and
  [privacy](https://www.limitless.ai/privacy).
- **Bee:** [product](https://bee.computer/bee-pioneer),
  [privacy](https://bee.computer/privacy),
  [developer documentation](https://docs.bee.computer/),
  [realtime stream](https://docs.bee.computer/docs/realtime),
  [local API proxy](https://docs.bee.computer/docs/proxy), and
  [Markdown sync](https://docs.bee.computer/docs/sync).
- **Upstream Omi:** [introduction](https://docs.omi.me/doc/get_started/introduction)
  and [subscriptions](https://help.omi.me/en/articles/12058411-understanding-omi-subscriptions).
- **Cloudflare core architecture:** [Workers](https://developers.cloudflare.com/workers/),
  [Durable Objects](https://developers.cloudflare.com/durable-objects/),
  [D1](https://developers.cloudflare.com/d1/),
  [R2](https://developers.cloudflare.com/r2/),
  [Vectorize](https://developers.cloudflare.com/vectorize/),
  [Workers AI](https://developers.cloudflare.com/workers-ai/),
  [AI Gateway](https://developers.cloudflare.com/ai-gateway/), and
  [Static Assets](https://developers.cloudflare.com/workers/static-assets/).
- **Conditional Cloudflare services:** [Queues](https://developers.cloudflare.com/queues/),
  [Workflows](https://developers.cloudflare.com/workflows/), and
  [Containers](https://developers.cloudflare.com/containers/).
- **Infrastructure economics:** [Cloudflare Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)
  and [Xiaomi MiMo pricing](https://mimo.mi.com/docs/en-US/price/pay-as-you-go).
