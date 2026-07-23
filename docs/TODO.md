# TODO

Living punch list. `[x]` done, `[~]` in progress, `[ ]` open, `(you)` needs
your account/keys/hardware. See `docs/ai-and-observability.md` for the "why".

## AI routing & models
- [x] Model-tier table (speed/balanced/smart/multimodal/search), env-driven, mirrored across hub + worker + worker-rs
- [x] Fix doubled slug prefixes (`xiaomi/xiaomi/…`, `google/google/…`)
- [x] Speed tier → `inception/mercury-2`; search tier → `perplexity/sonar`
- [ ] Wire the **search tier** into an actual search-intent path (config exists; nothing routes to it yet)
- [ ] **STT: drop Deepgram → `x-ai/grok-stt-1.0`** (verify streaming vs batch; Gemini Live built-in transcription for the realtime path)
- [ ] **Embeddings:** keep Cloudflare Workers AI (`bge-base`) for text; add a multimodal embedder only for images (CF multimodal model on-infra, or `gemini-embedding-2`)
- [ ] **rs_ai consolidation:** move Gemini Live + OpenRouter + local onto `rs_ai` (replace the hand-rolled `live_voice.rs` WebSocket)
- [ ] A/B `xiaomi/mimo-v2.5` (balanced, ~80% of traffic) vs `google/gemini-3.5-flash` / `deepseek` before fully trusting it
- [ ] Skip OmniRoute — redundant with Cloudflare AI Gateway + OpenRouter (both already give routing/fallback)
- [ ] (you) Set the OpenRouter key + point the endpoint at OpenRouter (or the AI Gateway)

## Cloudflare AI Gateway
- [x] Wire the gateway into the TS worker (`aiGatewayRoute`), ids validated before they reach the URL path
- [x] `default` gateway confirmed live and **authenticated**; `CF_AI_GATEWAY_TOKEN` set as a secret on both workers; vars set and deployed
- [ ] Mirror the gateway route in `worker-rs` and the hub
- [ ] Document upload → Cloudflare **AI Search** instance (memory/claims stay on our own Vectorize index)

## Observability / DevOps
- [x] Native Workers Observability on both workers
- [ ] **Better Stack — wire up the whole suite** (logs + uptime + status page + on-call + error tracking; their error product replaces standalone Sentry)
- [ ] foglamp.dev — LLM tracing (cost/latency/quality per call)
- [ ] (you) Better Stack + foglamp accounts + tokens/DSNs

## Cutover / release
- [ ] (you) `dart pub publish` crepuscularity_flutter (dry-run clean; auth is yours)
- [x] Secrets on the shadow Rust worker; [x] both missing worker-rs routes ported
- [ ] Production cutover to worker-rs (after the AI-gateway + observability land)

## Hardware bring-up (you, needs devices)
- [ ] nRF5340 DFU flash on a real pendant (dual-core, `eraseAppSettings:false`)
- [ ] Windows WASAPI meeting capture on real hardware
- [ ] AXContextReader against Mail / Chromium / Electron

## Product (from the audit brainstorm)
- [ ] Meeting → currents → channel closed loop (action items auto-become currents, pushed to the owner's linked channel)
- [ ] AXContextReader bundle-ID privacy denylist (exclude sensitive apps)
