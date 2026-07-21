#!/usr/bin/env bash
set -euo pipefail

app_dir="$(cd "$(dirname "$0")/.." && pwd)"
hub_dir="$app_dir/native/hub"

for target in aarch64-apple-ios aarch64-linux-android wasm32-unknown-unknown; do
  if cargo tree --manifest-path "$hub_dir/Cargo.toml" --target "$target" --edges normal --prefix none | grep -q '^rs_peekaboo '; then
    echo "rs_peekaboo must not resolve for $target" >&2
    exit 1
  fi
done

if ! cargo tree --manifest-path "$hub_dir/Cargo.toml" --target aarch64-apple-darwin --edges normal --prefix none | grep -q '^rs_peekaboo '; then
  echo "rs_peekaboo must resolve for desktop targets" >&2
  exit 1
fi
