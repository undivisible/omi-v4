# References

External projects we study, port ideas from, or depend on. This is a working
map, not an endorsement — read the licence column before lifting anything.

**Rule:** the repo takes only permissively-licensed code (MIT/BSD/Apache), no
telemetry. An **AGPL** or **GPL** entry means *ideas only* — read the design,
reimplement clean, never transcribe files. Where a reference has shaped a
specific file, that file cites it in a comment.

## Product / feature references

| Project | What we take | Licence | Notes |
|---|---|---|---|
| [FuJacob/cotabby](https://github.com/FuJacob/cotabby) | Accessibility-tree focus/caret reading, prompt-budgeting, latency-adaptive debounce, `stopAtArgmaxEOG` early-stop — as **design only** | **AGPL-3.0** | Ideas informed `AXContextReader.swift` and the cursor-pill assist. No code copied. Its `cotabbyinference` llama.cpp wrapper is separately **MIT** if we ever need it. |
| [sohzm/cheating-daddy](https://github.com/sohzm/cheating-daddy) | Cross-platform live meeting assist — reference for Windows/Linux meeting capture + on-screen assist | _verify_ | Basis for taking meeting mode off macOS-only. Confirm licence before porting code. |
| [fastrepl/anarlog](https://github.com/fastrepl/anarlog) | Desktop meeting-mode structure | _verify_ | Reviewed for meeting mode. |
| [Zackriya-Solutions/meetily](https://github.com/Zackriya-Solutions/meetily) | Meeting notes / live transcription patterns | _verify_ | Reviewed for meeting mode. |
| [basedhardware/omi](https://github.com/basedhardware/omi) (`~/projects/omi`) | Upstream Omi — firmware, the app we diverge from, brand assets (the `omi` mark) | MIT | We are lighter, steadier, broader. See `ARCHITECTURE.md` §5. `omi_logo.png` / `omi_wordmark.png` are vendored from here. |

## Agent / infrastructure references

| Project | What we take | Licence | Notes |
|---|---|---|---|
| [unthinkclaw](../unthinkclaw) (`~/projects/unthinkclaw`) | Multi-channel agent structure: one channel trait + one command table + thin per-channel transports (`src/channels/traits.rs`, `formatting.rs`, `telegram_runtime.rs`) | _local_ | Shaped the Telegram/Blooio shared command dispatcher. Note the `@botname` command-suffix handling and per-channel formatting. |
| [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | How an agent exposes its capability surface and tells the model what it can do | _verify_ | Informs "the assistant must know its channel commands exist". |

## Runtime dependencies with a reference character

| Project | Role | Licence |
|---|---|---|
| [robertmsale/rinf](https://github.com/robertmsale/rinf) (PR #681 branch) | Dart↔Rust bridge via Native Assets, replacing the CocoaPods-driven Rust build | MIT |
| mcumgr_flutter | In-app MCUboot DFU for the nRF5340 pendant | BSD-3-Clause |
| rs_ai_local | Apple FoundationModels binding (meeting notes, local chat routing) | _see crate_ |

## Notes on things we evaluated and did NOT adopt

- **llama.cpp ghost-text engine** — planned for autocomplete, then dropped: the
  feature is prompt-driven (seconds budget), not per-keystroke, so Apple
  FoundationModels (~333 ms TTFT, measured) is fine and no separate engine is
  needed. See the cursor-pill assist instead.
- **cotabby wholesale port** — blocked by AGPL and not portable to a
  Rust-core + Flutter app; we reimplement the few ideas worth having.
