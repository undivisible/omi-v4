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
| speed | latency-sensitive: live meeting insights, classification, answers | `google/gemini-3.1-flash-lite` | `OMI_MODEL_SPEED` |
| balanced | default, ~80% of tasks: **meeting notes**, general chat | `xiaomi/mimo-v2.5` | `OMI_MODEL_BALANCED` |
| smart | hard reasoning | `xiaomi/mimo-v2.5-pro` | `OMI_MODEL_SMART` |
| multimodal | vision / visual computer-use | `google/gemini-3.6-flash` | `OMI_MODEL_MULTIMODAL` |

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

**Off Deepgram, onto OpenRouter/Gemini audio models.**

- **Grok is not an option** — xAI models on OpenRouter are text/image only, no
  audio input. (Checked the live model list.)
- **No dedicated `transcription`-output models** on OpenRouter; STT is done by
  audio-input multimodal models (`audio → text`).
- **Cheapest audio→text:** `google/gemini-2.5-flash-lite` / `gemini-3.5-flash-lite`
  at ~$0.30/M audio tokens, then `google/gemini-3.1-flash-lite` (~$0.50),
  `openai/gpt-audio-mini` (~$0.60). (Mistral `voxtral` is ~$100/M — avoid.)

**Decision:**
- **Batch / file transcription →** `google/gemini-2.5-flash-lite` — cheapest,
  and it unifies on Gemini (already used by two tiers).
- **Realtime / live (meetings, voice) →** Gemini Live's **built-in streaming
  transcription**. This is the important tradeoff: Deepgram was a streaming
  WebSocket; OpenRouter audio models are request/response (you'd chunk audio at
  ~2–5s and eat the latency). Gemini Live transcribes the stream natively, so
  for the realtime path use Gemini Live, not chunked OpenRouter.

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
   and *gateway id*).
2. Set the worker `vars` (non-secret): `CF_AI_GATEWAY_ACCOUNT_ID` and
   `CF_AI_GATEWAY_ID`.
3. With both set, the OpenRouter base is rewritten to
   `https://gateway.ai.cloudflare.com/v1/{account}/{gateway}/openrouter/v1`.
   Unset → calls go direct to OpenRouter (no behavior change).
4. The OpenRouter API key still travels as the `Authorization` bearer; the
   gateway forwards it.

Wired in `worker/src/assistant.ts` (see `aiGatewayBase`). Mirror in
`worker-rs` and the hub for full parity.

## 5. Observability stack

Server-side observability is on; client telemetry is now permitted (crash
reporting, usage) — earlier this doc assumed no client telemetry; that
constraint was lifted.

| Layer | Pick | Alternatives | Status |
|-------|------|--------------|--------|
| Workers logs/metrics | **Workers Observability** (native) | Logpush → Better Stack/Datadog | ✅ enabled both workers |
| LLM gateway | **Cloudflare AI Gateway** | Portkey, Kong AI Gateway | wiring in §4 |
| LLM tracing | **Langfuse** (self-host, `rs_ai` native) | **foglamp.dev** (hosted, purpose-built for agents), Helicone, LangSmith | to wire |
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
- **LLM:** Cloudflare AI Gateway (caching/cost/retries) **+** Langfuse
  (per-request traces with cost attribution by tier/model). foglamp is the
  drop-in if we skip self-hosting.
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
