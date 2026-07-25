#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/app"

echo "== flutter format =="
(cd "$app" && dart format --output=none --set-exit-if-changed lib test)

echo "== flutter analyze =="
(cd "$app" && bash tool/analyze.sh)

echo "== flutter test (computer-use + app services) =="
(cd "$app" && flutter test test/app_services_test.dart test/features/cursor_pill_test.dart)

echo "== hub quality =="
bash "$root/scripts/hub-quality.sh"

echo "== hub computer-use =="
bash "$root/scripts/hub-computer-use.sh"

if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "== flutter build macos (unsigned smoke) =="
  (cd "$app" && flutter build macos --debug --config-only)
  (cd "$app/macos" && xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
    build 2>&1 | tail -20)
fi

echo "omi desktop smoke passed"
