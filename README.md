# Omi v4

A proactive second brain that listens, remembers with evidence, and acts — across the Omi pendant, mobile, desktop, web, Telegram, and Blooio.

Omi v4 captures what happens around you (pendant audio, meetings, your workspace), turns it into cited, evidence-backed memory, and exposes it through one continuous assistant conversation that reaches you wherever you are. On desktop it can also act on your behalf, behind an explicit approval step.

## What's here

| Path | What it is |
| --- | --- |
| `app` | Flutter client for iOS, Android, macOS, Windows, and web — one codebase, mobile and desktop surfaces |
| `app/native/hub` | The Rust "hub" (Rinf-bridged): assistant dispatch, Gemini Live voice, workspace scan, meetings, memory, computer-use |
| `app/macos/Runner` | macOS native layer — window chrome, summoned input overlay, voice waveform/glow overlays, global input, menu bar, EventKit |
| `worker` | Cloudflare Worker (Bun, Hono, TypeScript) — auth, D1 persistence, billing, channel delivery |
| `worker-rs` | Rust/workers-rs parity port of the Worker, cutover-ready |
| `firmware` | Pendant firmware (nRF5340 CV1 and nRF52840 DevKits), vendored from upstream with our feature work. Built out of band with the nRF Connect SDK and excluded from CI — see [`firmware/README.md`](firmware/README.md), [`firmware/BLE_CONTRACTS.md`](firmware/BLE_CONTRACTS.md), [`firmware/PROVENANCE.md`](firmware/PROVENANCE.md) |

External engines: [`tschk/zkr`](https://github.com/tschk/zkr) for evidence-backed temporal memory, `rx4` for extraction and ranking, `praefectus` for desktop computer-use.

## How it fits together

The pendant streams Opus audio over BLE to the phone; the desktop hub captures voice, meetings, and workspace context directly. Everything becomes evidenced memory in `zkr`, projected to Cloudflare D1 and Vectorize so the messaging channels stay memory-aware. One assistant conversation spans every surface, keyed by a single Firebase UID. Ordinary chat turns run on-device via Apple Foundation Models; heavier turns escalate to a hosted model.

## Documentation

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — the system as a whole, with a comparison against the upstream Omi project
- [`app/ARCHITECTURE-mobile.md`](app/ARCHITECTURE-mobile.md) — mobile companion and BLE pendant relay
- [`app/ARCHITECTURE-desktop.md`](app/ARCHITECTURE-desktop.md) — desktop UI, Rust hub, and macOS Runner
- [`firmware/ARCHITECTURE.md`](firmware/ARCHITECTURE.md) — pendant firmware
- [`PLAN.md`](PLAN.md) — product and implementation decisions · [`CONTEXT.md`](CONTEXT.md) — domain language

Each architecture document states plainly what we skip relative to upstream, what we do differently, and where upstream is ahead.

## Quality gates

```sh
cd app
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build macos --debug

cd native/hub
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test --all-features

cd ../../../worker
bun install --frozen-lockfile
bun run check
bunx wrangler deploy --dry-run
```

The Rust hub's tests link against the Swift runtime; if `cargo test` fails to load libraries, prefix it with:

```sh
DYLD_FALLBACK_LIBRARY_PATH="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macos:/usr/lib/swift"
```

The pendant firmware is not built by these gates — it needs the nRF Connect SDK. See [`firmware/README.md`](firmware/README.md).
