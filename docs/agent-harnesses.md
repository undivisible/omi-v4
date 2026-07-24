# Agent harnesses

How an assistant turn actually runs. The subject here is the harness around the
model — what picks the model, what the model is allowed to ask for, what stands
between an asked-for action and an executed one, and what the run costs — rather
than the prompts.

Read this before changing `app/native/hub/src/runtime.rs`,
`chat_router.rs`, `approval.rs`, `self_improve.rs`, or
`worker/src/assistant*.ts`.

## 1. The hub is not a sidecar

`app/native/hub` is a Rust crate compiled into the Flutter application and
addressed over rinf signals (`write_interface!()` in `lib.rs`; `ClientCommand`
in and `NativeEvent` out, both generated types). There is no agent daemon, no
local HTTP port, and no Python process. Chat, memory, transcription, meeting
capture, the workspace scan, the currents brief and computer use are modules of
one binary sharing one `RuntimeState` behind one mutex, which is why an approval
decided in the chat surface can reach the computer-use executor without a
protocol between them.

The consequences are worth being explicit about, because they are the reason for
the choice:

* **One memory handle.** `MemoryContext` holds the `zkr::MemoryDb` and the
  tenant/person scope; every module that reads or writes memory takes it from
  the same state rather than opening its own store. `self_improve.rs` is the one
  deliberate exception — it opens a second connection to the same database file
  so a reflection write cannot contend with the turn that produced it.
* **Cancellation is a value, not a signal.** Every command runs under a
  `CancellationToken` held in the runtime's active-command table, so cancelling
  a chat turn also cancels the provider stream, the accessibility observation it
  was waiting on, and the receipt claim it was about to make.
* **No hub, no capability.** The web target does not build the hub, and the
  surfaces that need it report their real unavailable state rather than
  degrading silently. `computer_use::available()` returns `false` on any
  platform that is not macOS, Windows or Linux, and the tool definitions are
  never offered to the provider when it does.

## 2. Capability-aware routing

Two independent questions decide which model a request goes to, and the split is
the point.

**What is this worth paying for?** `chat_router.rs` wraps rx4's `ModelRouter`.
Search intent and vision intent are detected from the prompt first (fixed marker
lists — `"search the web"`, `"this screenshot"`, and so on) because rx4 has no
`TaskTier` for either; everything else defers to rx4's heuristics, extended with
a list of keywords that push hard reasoning to `Heavy`. The rx4 tiers map onto
the hub's own: `Lite`→speed, `Standard`→balanced, `Heavy`→smart, `Subagent`→
balanced, each with balanced as its fallback. The per-tier model ids are read
from `model_tier.rs` rather than restated, so a slug is corrected in one place.

**What must the model be able to read?** `model_tier.rs` carries a capability
table (`text`, `audioIn`, `audioOut`, `imageIn`, `realtime`) keyed by model id,
checked against the live OpenRouter model list. `select_model_for` takes the
capabilities a call site needs and an ordered tier preference, and returns the
first tier whose model declares all of them. If none does it returns
`CapabilityMismatch` — it does not fall back to a model that cannot read the
input. Sending audio to a text-only model is how a transcription becomes a
confident invention, so the refusal is the feature.

Three details make the table honest rather than decorative:

* A model id the table has not verified satisfies **nothing**. An environment
  override naming an unknown model is refused at the point of use, not accepted
  on trust. A new id declares itself through `OMI_MODEL_CAPABILITIES`
  (`vendor/model=text+audioIn,...`); a malformed value declares nothing, so a
  typo degrades to "unverified" and is refused rather than silently honoured.
* `realtime` is deliberately claimed by no entry. A bidirectional live session
  runs over Gemini Live (`live_voice.rs`), not over a chat completion, so asking
  the tier table for a realtime model is asking the wrong layer.
* Asynchronous audio prefers balanced (`ASYNC_AUDIO_TIER_PREFERENCE` is
  balanced → transcribe → multimodal), because the balanced model takes audio
  input at half the transcribe tier's price. A balanced override that is
  text-only moves that path to the transcribe tier automatically instead of
  breaking it.

The tier the router picked is reported to the client alongside the model id it
resolved to (`ONLINE_CHAT_MODEL_DETAIL`), through the provider's own
`model_for_tier`, so the tier chosen and the model named cannot drift apart.

## 3. The approval gate

Nothing with an effect outside the app happens because a model asked for it.

A provider stream can emit tool calls; the hub turns a valid one into an
`ActionProposal` carrying a title, a summary, an `ActionRisk`
(`Reversible` / `External` / `Destructive`) and an expiry, and registers it in
the `ProposalRegistry` (`approval.rs`). The proposal is surfaced to the user as
a `NativeEvent::ActionProposal`. Only an `ApprovalDecision::ApproveOnce` arriving
back for that proposal id can produce an effect, and only once — there is no
"approve always".

The registry is a small state machine, and every rule in it exists to close a
specific hole:

| Rule | What it prevents |
| --- | --- |
| A proposal is fingerprinted over uid, authority generation, parent request, expiry, risk, title, summary and the bound action. Re-registering the same id with a different fingerprint is `Conflict`; re-registering it identically is an `ExactReplay`. | A retried stream silently replacing the action behind an id the user is already looking at. |
| Decisions carry the uid and authority generation; a mismatch is `WrongAuthority`. | A proposal raised for one account being approved after a sign-out or a reconfiguration. |
| Expiry is checked on registration, on every decision, and by a sweep on every registry touch. Expired proposals move to terminal `Expired`. | Approving something the assistant proposed against a screen that no longer exists. |
| Deciding a proposal moves it out of `pending` into `terminal`; a second decision is `AlreadyDecided`. | Double execution from a double tap or a replayed command. |
| `invalidate_parent` retires every pending proposal from a parent request when that request ends; `invalidate_generation` retires all of them when the authority changes. | Orphan proposals outliving the turn that produced them. |
| `pending` is capped at 64 and `terminal` at 256 with FIFO eviction. | A misbehaving provider filling memory with proposals. |

Approval of a proposal that carries no computer action simply reports the
decision. Approval of one that does is where the rest of §4 of
[`computer-use.md`](./computer-use.md) begins — including the requirement that
the approval be independently consumed server-side before any effect.

## 4. Evidence and self-improvement

Two loops feed the harness back into itself, and both are bounded and
fail-quiet.

**Workspace evidence.** `scan.rs` and `evidence.rs` build the local picture the
assistant starts from: applications and Dock entries, developer activity
(project markers, shell history, SSH hosts, editor recents), browser history,
and short gists skimmed from documents — plus Apple Notes and Mail, but only
when the client passes those flags. Every collector is capped (at most 120
applications, 80 browser rows over a 14-day window, 60 shell commands, 120
documents at 2 KB read each) so a scan cannot balloon on a large machine, and
each source reports `Complete`, `Denied`, `Unavailable` or `Failed` rather than
silently returning nothing. Redaction happens at collection, not at display: a
URL whose text matches `auth`, `bank`, `checkout`, `login`, `password`,
`signin`, `token` is dropped entirely rather than domain-reduced, and a shell
command containing `api_key`, `secret`, `password`, `token` or `key=` never
becomes an evidence line.

**Turn reflection.** `self_improve.rs` wraps rx4's `SelfImprove` over the same
memory database. Before an online turn, `augment` retrieves at most
`LESSON_LIMIT` (3) lessons relevant to the query and appends them to the prompt;
if retrieval fails or finds nothing, the base prompt is returned unchanged.
After the turn closes, `record_turn` classifies it through rx4's
`ProactiveMonitor`, extracts a lesson (falling back to a generic note when none
is detectable) and records it — spawned as fire-and-forget so the write never
adds latency to the turn that produced it, and swallowing errors so a failed
write never surfaces to the user. If the database cannot be opened, `open`
returns `None` and both halves become no-ops.

Two other loops run on the same footing: `daily_review.rs` composes the previous
local day into a review recorded as citable zkr records, and `brief.rs` asks the
model for the currents brief as a `.crepus` document constrained to the node
kinds the Flutter renderer actually draws and the four action strings the app
dispatches. Both treat model output as untrusted: the brief has a hand-built
fallback, so a refusal or an unsupported node costs presentation, never the
brief.

## 5. Admission control and cost

The managed path has a real budget, enforced before the upstream call rather
than reconciled after it.

`AssistantAdmission` (`worker/src/assistant-admission.ts`) is a single global
Durable Object (`managed-ai-global`) holding a SQL table of reservations, with
requests serialised through a promise chain so two admissions cannot read the
same usage. Before any managed completion, the caller estimates its input tokens
from the message bytes plus a per-message and per-request framing reserve,
computes an estimated cost from the configured per-million input and output
prices, and asks for a reservation. Admission is refused with `429` and a
`retry-after` when any of six limits would be exceeded:

| Limit | Default | Override |
| --- | --- | --- |
| In-flight requests per uid | 2 | `MIMO_UID_IN_FLIGHT_LIMIT` |
| In-flight requests globally | 32 | `MIMO_GLOBAL_IN_FLIGHT_LIMIT` |
| Tokens per uid per window | 100,000 | `MIMO_UID_TOKEN_BUDGET` |
| Tokens globally per window | 2,000,000 | `MIMO_GLOBAL_TOKEN_BUDGET` |
| Cost per uid per window | 1,000,000 µUSD | `MIMO_UID_COST_BUDGET_MICROUSD` |
| Cost globally per window | 20,000,000 µUSD | `MIMO_GLOBAL_COST_BUDGET_MICROUSD` |

The window defaults to one hour (`MIMO_BUDGET_WINDOW_SECONDS`) and reservations
older than it are deleted on each admission, so the budget is rolling rather
than calendar-aligned. A repeated `requestId` returns the existing reservation's
state instead of taking a second one, which makes admission idempotent under
client retries.

Settlement is where the estimate becomes the truth. The streaming route keeps a
16 KB tail of the SSE body, reads `usage.prompt_tokens` and
`usage.completion_tokens` out of it at end of stream, recomputes the actual cost
and calls `/settle`, which rewrites the reservation's token and cost figures and
clears its in-flight flag. Every terminal path settles — normal completion,
client cancellation, upstream timeout, upstream failure — and each is persisted
to `managed_ai_requests` with its status. When a settle or a persist fails, it is
retried three times and then deferred through `waitUntil`; anything that still
escapes is swept up by `reconcileManagedAssistantRequests`, which finds requests
that are finalized but unsettled, or stuck in `started`/`streaming` for more than
two minutes, marks them failed and releases their reservation. A reservation that
is never released would silently shrink the budget, so nothing is allowed to
leak one.

The request body itself is validated before any of this: unknown top-level keys
are rejected, the model must equal the tier's configured model, `stream` must be
`true`, `stream_options` must be exactly `{include_usage: true}` (so usage is
always available to settle from), at most 64 messages and 32,000 input
characters, `max_tokens` in 1–4096, and the body is read through a 64 KB bounded
reader that cancels rather than buffers when the limit is passed.

## 6. Where the model provider itself comes from

The hub dispatches through `rs_ai` against whichever provider the user
configured — OpenAI, Anthropic, Gemini, xAI, an arbitrary OpenAI-shaped HTTPS
endpoint, or the managed worker. See [`byok.md`](./byok.md) for the
configuration surface, the endpoint validation, and where the credential lives.
