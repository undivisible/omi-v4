# AI Routing & Observability

How Omi selects models, transcribes audio, and what we run for DevOps /
observability. This is the decision record — the "why" behind the config.

## 1. Model tiers

One env-driven tier table is the single source of truth, mirrored in
`app/native/hub/src/model_tier.rs`, `worker/src/model-tiers.ts`, and
`worker-rs/src/managed_ai.rs`. All four defaults are **OpenRouter slugs**, so
the completions endpoint must be OpenRouter (or an AI Gateway in front of it —
see §4).

| Tier | When | Default (OpenRouter slug) | Env override |
|------|------|---------------------------|--------------|
| speed | latency-sensitive: live meeting insights, classification, answers | `inception/mercury-2` | `OMI_MODEL_SPEED` |
| balanced | default, ~80% of tasks: **meeting notes**, general chat | `xiaomi/mimo-v2.5` | `OMI_MODEL_BALANCED` |
| smart | hard reasoning | `xiaomi/mimo-v2.5-pro` | `OMI_MODEL_SMART` |
| multimodal | vision / visual computer-use | `google/gemini-3.6-flash` | `OMI_MODEL_MULTIMODAL` |
| search | web-grounded answers (live search) | `perplexity/sonar` | `OMI_MODEL_SEARCH` |

Balanced also falls back to the legacy `MIMO_MODEL` when unset.

**Notes**
- **Auto-router (`openrouter/auto`): not the default.** It re-classifies every
  prompt and picks a model, which defeats the point of tiers — unpredictable
  cost on the high-volume balanced path and an extra routing hop on the
  latency-critical speed path. Available as an opt-in `OMI_MODEL_SMART`
  override for "best answer, cost be damned", nothing more.
- **`xiaomi/mimo-v2.5` is the tier to watch.** It carries ~80% of traffic and
  is newer/less proven; A/B it against `google/gemini-3.5-flash` or
  `deepseek/deepseek-chat` on real transcripts before fully trusting it.

## 2. Speech-to-text (transcription)

**Off Deepgram, onto `x-ai/grok-stt-1.0` via OpenRouter.**

- **Primary: `x-ai/grok-stt-1.0`** — xAI's dedicated STT model, released
  2026-07 on OpenRouter, cheap. A purpose-built transcription model beats
  bending a chat model into STT.
- **Fallback / batch: `google/gemini-2.5-flash-lite`** (audio→text, ~$0.30/M
  audio) — unifies on Gemini and covers the case where grok-stt is
  unavailable. `openai/gpt-audio-mini` is the next option. (`inception/mercury-2`
  and `xiaomi/mimo-v2.5*` are not audio models.)

**Verify before shipping:** whether `grok-stt-1.0` supports *streaming*
transcription or only batch. Deepgram was a streaming WebSocket; if grok-stt is
request/response we chunk audio at ~2–5s (added latency). For the truly
realtime path, Gemini Live's **built-in streaming transcription** remains the
lowest-latency option and needs no separate STT call.

## 2a. Embeddings

**Keep them on Cloudflare Workers AI; reach for a multimodal model only for
non-text.**

- **Today:** `@cf/baai/bge-base-en-v1.5` (768-dim) via Workers AI
  (`worker/src/embeddings.ts`), wired to Vectorize. It runs on our own
  infrastructure (not a third party, not per-token-billed like OpenRouter),
  and the free tier is generous — effectively the "local" option for the
  cloud memory index.
- **Recommendation:** keep Workers AI as the **primary text embedder**. It is
  cheapest and already integrated; switching the primary to a paid API means
  re-indexing the whole Vectorize store (dimension change) plus per-call cost
  on a high-volume path.
- **Multimodal:** when we index images/screenshots, add a multimodal embedder
  for *that content only* — either a Cloudflare Workers AI multimodal model
  (stays on-infra) or `gemini-embedding-2` (multimodal, high quality, but data
  leaves and it costs per call). Prefer the on-infra option unless
  gemini-embedding-2's quality is measurably needed.
- **Net:** hybrid — Workers AI for text (the 95% path), a multimodal model for
  images. Going all-in on `gemini-embedding-2` is only worth it if multimodal
  quality is the priority and the re-index + cost are acceptable.

## 3. Gemini Live

- **Still needs a direct `GEMINI_API_KEY`.** Gemini Live is Google's realtime
  bidirectional WebSocket API (`generativelanguage.googleapis.com`).
  OpenRouter does **not** proxy realtime/Live APIs — it is request/response
  only. So Gemini Live is a separate credential + transport from the
  OpenRouter/chat path.
- **Consolidate onto `rs_ai`.** Today `app/native/hub/src/live_voice.rs` is a
  hand-rolled tungstenite WebSocket. `rs_ai_providers` already ships
  `gemini/live_api.rs` (Gemini Live), `openai-compatible` (OpenRouter), and
  `ollama` / `rs_ai_local` (local) — plus a `langfuse` feature. Moving the Live
  path and the provider plumbing onto rs_ai kills the custom socket, unifies
  the provider layer, and gives Langfuse tracing for free.

## 4. Cloudflare AI Gateway

All LLM calls route through a Cloudflare AI Gateway sitting in front of
OpenRouter. It gives, at one endpoint swap: response **caching**, automatic
**retries / fallback**, per-model **cost + latency analytics**, and **rate
limiting** — server-side, no client involvement.

**Setup**
1. Cloudflare dashboard → AI Gateway → create a gateway (note the *account id*
   and *gateway id*). A gateway named `default` is also auto-created on the
   first request that carries a `cf-aig-authorization` header — but that needs
   a **scoped API token**, not the OAuth token `wrangler auth token` prints.
   Create one at dash → API Tokens → Custom Token with `AI Gateway - Read`,
   `AI Gateway - Edit`, `Workers AI - Read`. Without it every call returns
   `AiGatewayError 2009 Unauthorized` (and the management API returns
   `10000 Authentication error`) — which is exactly where the wiring stands
   today. `wrangler` has no `ai-gateway` command, so there is no CLI path.
   Once the gateway exists and is left unauthenticated, normal traffic needs
   no Cloudflare token at all: the OpenRouter key alone is enough.
2. Set the worker `vars` (non-secret): `CF_AI_GATEWAY_ACCOUNT_ID` and
   `CF_AI_GATEWAY_ID`.
3. With both set, the OpenRouter base is rewritten to
   `https://gateway.ai.cloudflare.com/v1/{account}/{gateway}/openrouter/v1`.
   Unset → calls go direct to OpenRouter (no behavior change).
4. The OpenRouter API key still travels as the `Authorization` bearer; the
   gateway forwards it.

Wired in `worker/src/assistant.ts` (see `aiGatewayBase`). Mirror in
`worker-rs` and the hub for full parity.

## 4a. Cloudflare AI Search

**Not for us, at least not yet.** AI Search (the product formerly called
AutoRAG) is a managed RAG pipeline: point it at R2, a website, or uploaded
files and it handles chunking, embeddings, Vectorize indexing, continuous
sync, hybrid (semantic + keyword) retrieval, reranking, and optionally the
generated answer — plus a built-in MCP endpoint per instance.

It is built *on* Vectorize, and we already run the layer underneath it:
Workers AI `bge-base` embeddings into our own Vectorize index, with our own
chunking and our own evidence/claim model on top. Handing that to AI Search
would mean re-indexing and giving up control of the retrieval pipeline for
convenience we do not need — Cloudflare's own guidance is Vectorize when you
want to own retrieval, AI Search when you want it managed.

Where it *would* earn its place: indexing a corpus we do not own the
ingestion for — user-uploaded documents, or a per-tenant file store — since
it does continuous sync and per-tenant isolation for free. Worth revisiting
when we ship document upload.

## 5. Observability stack

Server-side observability is on; client telemetry is now permitted (crash
reporting, usage) — earlier this doc assumed no client telemetry; that
constraint was lifted.

| Layer | Pick | Alternatives | Status |
|-------|------|--------------|--------|
| Workers logs/metrics | **Workers Observability** (native) | Logpush → Better Stack/Datadog | ✅ enabled both workers |
| LLM gateway | **Cloudflare AI Gateway** | Portkey, Kong AI Gateway | wiring in §4 |
| LLM tracing/eval | **Hold** — covered for now by AI Gateway + Better Stack logs | foglamp.dev (hosted, add for eval), Langfuse (self-host — impractical on Cloudflare, see below) | deferred |
| Errors / APM | **Sentry** (worker **and** Flutter client) | Bugsnag, Rollbar, Highlight, GlitchTip (self-host) | to wire |
| Uptime + status + on-call | **Better Stack** (uptime + logs + incidents in one) | **Hyperping** (uptime/status/on-call focus), Pingdom, Checkly, UptimeRobot | to wire |

### Tool notes (the four you flagged)
- **foglamp.dev** — LLM observability: cost/latency/quality per call, "catch
  bad output before users do." Hosted, agent-focused. A strong hosted
  alternative to Langfuse; pick it if we'd rather not self-host tracing.
- **hyperping.com** — multi-region uptime monitoring + branded status pages +
  on-call escalation. Focused and clean; good if we want a dedicated status
  page.
- **betterstack.com** — Better Stack: uptime **+** log management **+** incident
  /on-call in one product. Best all-in-one for a small team; subsumes what
  Hyperping does and adds logs.
- **sentry.io** — error tracking + performance (APM) + session replay. The
  standard for application errors on both the worker and the Flutter app.

### Recommended shape
- **LLM:** Cloudflare AI Gateway (caching/cost/retries) **+** log prompt/
  completion events into Better Stack Logs. That covers cost, latency, and
  request inspection without another vendor.
  - **LLM tracing/eval is deferred.** Langfuse self-hosting is impractical on
    Cloudflare (its Postgres + ClickHouse + Redis + S3 stack has no managed
    Cloudflare equivalent — you'd run external DBs, defeating the point). If we
    later want prompt-level eval/quality scoring (the one thing AI Gateway +
    Better Stack don't give), add hosted **foglamp.dev** then.
- **Errors:** Sentry on the worker and the Flutter client.
- **Uptime/incidents:** Better Stack (one tool for uptime + status page +
  on-call + log sink), Hyperping if we want status-page-first.
- **Infra logs:** Workers Observability now; Logpush into Better Stack if we
  want everything in one pane.

## 6. What needs your input to go live
- **OpenRouter key** + point the endpoint at OpenRouter (or the AI Gateway).
- **AI Gateway:** create it, set `CF_AI_GATEWAY_ACCOUNT_ID` / `CF_AI_GATEWAY_ID`.
- **Langfuse / Sentry / Better Stack:** accounts + keys (secrets you set).
- **`GEMINI_API_KEY`** stays required for Gemini Live.
