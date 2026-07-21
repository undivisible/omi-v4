#!/usr/bin/env bash
set -euo pipefail

app_dir="$(cd "$(dirname "$0")/.." && pwd)"
generated_dir="$app_dir/lib/native/generated"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/omi-rinf-bindings.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

mkdir -p "$temp_dir/native/hub"
cp "$app_dir/pubspec.yaml" "$temp_dir/pubspec.yaml"
cp "$app_dir/native/hub/Cargo.toml" "$app_dir/native/hub/Cargo.lock" "$temp_dir/native/hub/"
cp -R "$app_dir/native/hub/src" "$temp_dir/native/hub/"

(
  cd "$temp_dir"
  rinf gen
  dart format lib/native/generated >/dev/null
)

diff -ru "$generated_dir" "$temp_dir/lib/native/generated"
