# TODO

Living punch list. `[x]` done, `[~]` in progress, `[ ]` open, `(you)` needs
your account/keys/hardware. See `docs/ai-and-observability.md` for the "why".

## AI routing & models
- [x] Model-tier table (speed/balanced/smart/multimodal/search), env-driven, mirrored across hub + worker + worker-rs
- [x] Fix doubled slug prefixes (`xiaomi/xiaomi/…`, `google/google/…`)
- [x] Speed tier → `inception/mercury-2`; search tier → `perplexity/sonar`
- [x] Wire the **search tier** into an actual search-intent path: `chat_router` detects search intent and returns `ModelTier::Search`; managed (paying) turns resolve to `perplexity/sonar` and the worker assistant route forwards them to OpenRouter, BYOK OpenAI/xAI turns run the provider-hosted `web_search` tool via the Responses API (`hosted_search.rs`), and citations are surfaced on the reply in every case
- [x] **STT: drop Deepgram → xAI Speech to Text** (`wss://api.x.ai/v1/stt`; Gemini Live built-in transcription remains the realtime voice path)
- [x] **Embeddings:** keep Cloudflare Workers AI (`bge-base`) for text; use `gemini-embedding-2` only for images
- [x] **rs_ai consolidation audit:** OpenRouter chat already uses `rs_ai`, and Apple Foundation Models already uses its platform crate `rs_ai_local`; keep `live_voice.rs` until the `rs_ai` realtime facade supports ephemeral-token auth, configurable setup/tools, input/output transcription, setup-complete gating, interruption events, tool results, session resumption, and GoAway draining
- [ ] A/B `xiaomi/mimo-v2.5` (balanced, ~80% of traffic) vs `google/gemini-3.5-flash` / `deepseek` before fully trusting it
- [x] Skip OmniRoute — redundant with Cloudflare AI Gateway + OpenRouter (both already give routing/fallback)
- [ ] (you) Set the OpenRouter key + point the endpoint at OpenRouter (or the AI Gateway)

## Cloudflare AI Gateway
- [x] Wire the gateway into the TS worker (`aiGatewayRoute`), ids validated before they reach the URL path
- [x] `default` gateway confirmed live and **authenticated**; `CF_AI_GATEWAY_TOKEN` set as a secret on both workers; vars set and deployed
- [x] Mirror the gateway route in `worker-rs` and the hub
- [x] Document upload → Cloudflare **AI Search** binding and tenant-isolated routes (memory/claims stay on our own Vectorize index)
- [ ] (you) Create the `omi-documents` Cloudflare AI Search instance before deployment

## Observability / DevOps
- [x] Native Workers Observability on both workers
- [x] **Better Stack code wiring** — opt-in Tail log export, successful-cron heartbeat, and Sentry-compatible error envelopes
- [x] **foglamp.dev code wiring** — opt-in managed-LLM cost/latency traces without prompt, response, or user content
- [ ] (you) Better Stack account + log token/URL + heartbeat URL + Errors DSN; create uptime monitors, status page, and on-call policy
- [ ] (you) foglamp account + API key

## Cutover / release
- [ ] (you) `dart pub publish` crepuscularity_flutter (dry-run clean; auth is yours)
- [x] Secrets on the shadow Rust worker; [x] both missing worker-rs routes ported
- [ ] Production cutover to worker-rs (after the AI-gateway + observability land)

## Hardware bring-up (you, needs devices)
- [ ] nRF5340 DFU flash on a real pendant (dual-core, `eraseAppSettings:false`)
- [ ] Windows WASAPI meeting capture on real hardware
- [ ] AXContextReader against Mail / Chromium / Electron

## Product (from the audit brainstorm)
- [x] Meeting → currents → channel closed loop (action items auto-become currents, pushed to the owner's linked channel)
- [x] AXContextReader bundle-ID privacy denylist (exclude sensitive apps)
- [x] **Multi-display Rewind:** capture and persist every active macOS display with stable layout metadata and per-display deduplication
- [ ] **Speech profiles:** blocked until an STT/provider supplies stable speaker embeddings or voiceprints; meeting-local diarization indices cannot identify a person across recordings
