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
  dart run "$app_dir/tool/redact_rinf_bindings.dart" lib/native/generated
)

diff -ru "$generated_dir" "$temp_dir/lib/native/generated"

command_file="$generated_dir/signals/command.dart"
if grep -Fq "'credential: \$credential'" "$command_file"; then
  echo "generated assistant credential debug output is not redacted" >&2
  exit 1
fi
if [[ "$(grep -Fc "'credential: [REDACTED]'" "$command_file")" -ne 1 ]]; then
  echo "generated assistant credential redaction is missing or ambiguous" >&2
  exit 1
fi
