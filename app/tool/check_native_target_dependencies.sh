#!/usr/bin/env bash
set -euo pipefail

app_dir="$(cd "$(dirname "$0")/.." && pwd)"
hub_dir="$app_dir/native/hub"

for target in aarch64-apple-ios aarch64-linux-android wasm32-unknown-unknown x86_64-unknown-linux-gnu x86_64-pc-windows-msvc; do
  if cargo tree --manifest-path "$hub_dir/Cargo.toml" --target "$target" --edges normal --prefix none | grep -q '^praefectus '; then
    echo "praefectus must not resolve for $target" >&2
    exit 1
  fi
done

praefectus_version="$(sed -n 's/^praefectus = "=\([0-9][^"]*\)"$/\1/p' "$hub_dir/Cargo.toml" | head -n 1)"
if [ -z "$praefectus_version" ]; then
  echo "could not read the pinned praefectus version from $hub_dir/Cargo.toml" >&2
  exit 1
fi

for target in aarch64-apple-darwin; do
  if ! cargo tree --manifest-path "$hub_dir/Cargo.toml" --target "$target" --edges normal --prefix none | grep -qx "praefectus v$praefectus_version"; then
    echo "praefectus $praefectus_version must resolve for $target" >&2
    exit 1
  fi

  if cargo tree --manifest-path "$hub_dir/Cargo.toml" --target "$target" --edges normal --prefix none | grep -q '^rs_peekaboo '; then
    echo "rs_peekaboo must not resolve for $target" >&2
    exit 1
  fi
done
