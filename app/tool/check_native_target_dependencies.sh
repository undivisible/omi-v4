#!/usr/bin/env bash
set -euo pipefail

app_dir="$(cd "$(dirname "$0")/.." && pwd)"
hub_dir="$app_dir/native/hub"

for target in aarch64-apple-ios aarch64-linux-android wasm32-unknown-unknown; do
  if cargo tree --manifest-path "$hub_dir/Cargo.toml" --target "$target" --edges normal --prefix none | grep -q '^praefectus '; then
    echo "praefectus must not resolve for $target" >&2
    exit 1
  fi
done

for target in aarch64-apple-darwin x86_64-unknown-linux-gnu x86_64-pc-windows-msvc; do
  if ! cargo tree --manifest-path "$hub_dir/Cargo.toml" --target "$target" --edges normal --prefix none | grep -q '^praefectus v0\.3\.0$'; then
    echo "praefectus 0.3.0 must resolve for $target" >&2
    exit 1
  fi

  if cargo tree --manifest-path "$hub_dir/Cargo.toml" --target "$target" --edges normal --prefix none | grep -q '^rs_peekaboo '; then
    echo "rs_peekaboo must not resolve for $target" >&2
    exit 1
  fi
done
