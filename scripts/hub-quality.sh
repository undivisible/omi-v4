#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
hub="$root/app/native/hub"
app="$root/app"

# shellcheck source=lib/macos-swift-dyld.sh
source "$(cd "$(dirname "$0")" && pwd)/lib/macos-swift-dyld.sh"

echo "== hub: fmt =="
(cd "$hub" && cargo fmt --check)

echo "== hub: praefectus target graph =="
bash "$app/tool/check_native_target_dependencies.sh"

echo "== hub: clippy =="
(cd "$hub" && cargo clippy --all-targets --all-features -- -D warnings)

echo "== hub: test =="
(cd "$hub" && cargo test --all-features)

echo "hub quality gates passed"
