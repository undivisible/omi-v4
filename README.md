# Omi v4

A proactive second brain across mobile, desktop, web, Omi hardware, Telegram, and Blooio.

## Architecture

- `app`: Flutter UI for iOS, Android, macOS, Windows, and web
- `app/native/hub`: Rinf Rust runtime for native assistant orchestration
- `worker`: Bun, Hono, Cloudflare Workers, and D1
- `firmware`: Omi pendant firmware (nRF5340, Zephyr / nRF Connect SDK). Built out of band with the Zephyr SDK, excluded from CI — see [`firmware/README.md`](firmware/README.md), [`firmware/BLE_CONTRACTS.md`](firmware/BLE_CONTRACTS.md) and [`firmware/PROVENANCE.md`](firmware/PROVENANCE.md)
- [`tschk/zkr`](https://github.com/tschk/zkr): reusable evidence-backed temporal memory engine

The product and implementation decisions live in [`PLAN.md`](PLAN.md). Domain language lives in [`CONTEXT.md`](CONTEXT.md).

## Quality gates

```sh
cd app
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build web

cd ../worker
bun install --frozen-lockfile
bun run check
bunx wrangler deploy --dry-run

cd ../app/native/hub
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo check --all-targets --all-features
cargo test --all-features
```
