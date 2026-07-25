#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
hub="$root/app/native/hub"
app="$root/app"

export DYLD_FALLBACK_LIBRARY_PATH="${DYLD_FALLBACK_LIBRARY_PATH:-}:$(xcode-select -p 2>/dev/null)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macos:/usr/lib/swift"

echo "== hub: fmt =="
(cd "$hub" && cargo fmt --check)

echo "== hub: praefectus target graph =="
bash "$app/tool/check_native_target_dependencies.sh"

echo "== hub: clippy =="
(cd "$hub" && cargo clippy --all-targets --all-features -- -D warnings)

echo "== hub: test =="
(cd "$hub" && cargo test --all-features)

echo "hub quality gates passed"
