#!/usr/bin/env bash
set -euo pipefail

app_dir="$(cd "$(dirname "$0")/.." && pwd)"

cd "$app_dir"
rinf gen
dart format lib/native/generated >/dev/null
dart run tool/redact_rinf_bindings.dart lib/native/generated
