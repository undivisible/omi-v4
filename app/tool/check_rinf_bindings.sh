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
  echo "generated credential redaction is missing or ambiguous" >&2
  exit 1
fi

transcription_auth_file="$generated_dir/signals/transcription_auth.dart"
for field in firebaseToken apiKey; do
  if grep -Fq "'$field: \$$field'" "$transcription_auth_file"; then
    echo "generated transcription $field debug output is not redacted" >&2
    exit 1
  fi
  if [[ "$(grep -Fc "'$field: [REDACTED]'" "$transcription_auth_file")" -ne 1 ]]; then
    echo "generated transcription $field redaction is missing or ambiguous" >&2
    exit 1
  fi
done

message_block="$(sed -n '/^class CommandSendMessage /,/^@immutable$/p' "$command_file")"
if grep -Fq "'text: \$text, '" <<<"$message_block"; then
  echo "generated send-message text debug output is not redacted" >&2
  exit 1
fi
if [[ "$(grep -Fc "'text: [REDACTED], '" <<<"$message_block")" -ne 1 ]]; then
  echo "generated send-message text redaction is missing or ambiguous" >&2
  exit 1
fi

correction_block="$(sed -n '/^class CommandCorrectMemory /,/^@immutable$/p' "$command_file")"
for field in text value; do
  if grep -Fq "'$field: \$$field, '" <<<"$correction_block"; then
    echo "generated correction $field output is not redacted" >&2
    exit 1
  fi
  if [[ "$(grep -Fc "'$field: [REDACTED], '" <<<"$correction_block")" -ne 1 ]]; then
    echo "generated correction $field redaction is missing or ambiguous" >&2
    exit 1
  fi
done

action_file="$generated_dir/signals/computer_use_action.dart"
for field in targetName value; do
  if grep -Fq "'$field: \$$field, '" "$action_file"; then
    echo "generated computer-use $field debug output is not redacted" >&2
    exit 1
  fi
done
if [[ "$(grep -Fc "'targetName: [REDACTED], '" "$action_file")" -ne 2 ]] ||
   [[ "$(grep -Fc "'value: [REDACTED], '" "$action_file")" -ne 1 ]]; then
  echo "generated computer-use redaction is missing or ambiguous" >&2
  exit 1
fi

capture_block="$(sed -n '/^class CommandCaptureEvent /,/^@immutable$/p' "$command_file")"
for field in text application windowTitle; do
  if grep -Fq "'$field: \$$field, '" <<<"$capture_block"; then
    echo "generated capture $field debug output is not redacted" >&2
    exit 1
  fi
  if [[ "$(grep -Fc "'$field: [REDACTED], '" <<<"$capture_block")" -ne 1 ]]; then
    echo "generated capture $field redaction is missing or ambiguous" >&2
    exit 1
  fi
done

transcript_file="$generated_dir/signals/transcript_delta.dart"
if grep -Fq "'text: \$text, '" "$transcript_file"; then
  echo "generated transcript text debug output is not redacted" >&2
  exit 1
fi
if [[ "$(grep -Fc "'text: [REDACTED], '" "$transcript_file")" -ne 1 ]]; then
  echo "generated transcript text redaction is missing or ambiguous" >&2
  exit 1
fi

assistant_file="$generated_dir/signals/assistant_delta.dart"
if grep -Fq "'text: \$text, '" "$assistant_file"; then
  echo "generated assistant text debug output is not redacted" >&2
  exit 1
fi

scan_file="$generated_dir/signals/onboarding_scan_completed.dart"
if grep -Fq "'summary: \$summary'" "$scan_file"; then
  echo "generated onboarding summary output is not redacted" >&2
  exit 1
fi
if [[ "$(grep -Fc "'summary: [REDACTED]'" "$scan_file")" -ne 1 ]]; then
  echo "generated onboarding summary redaction is missing or ambiguous" >&2
  exit 1
fi
if [[ "$(grep -Fc "'text: [REDACTED], '" "$assistant_file")" -ne 1 ]]; then
  echo "generated assistant text redaction is missing or ambiguous" >&2
  exit 1
fi
