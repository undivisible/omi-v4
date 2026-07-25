#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
hub="$root/app/native/hub"
live="${1:-}"

export DYLD_FALLBACK_LIBRARY_PATH="${DYLD_FALLBACK_LIBRARY_PATH:-}:$(xcode-select -p 2>/dev/null)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macos:/usr/lib/swift"

echo "== computer-use unit + integration (hub) =="
(cd "$hub" && cargo test --lib computer_use -- --nocapture)

echo "== audit regressions (trusted origin, apply memory, receipts) =="
for pattern in \
  trusted_assistant_origin \
  memory_apply_commits \
  client_context_caps \
  meeting_auth_without \
  apply_memory_requires \
  failed_receipt_claim \
  computer_action_is_approved \
  proposal_decisions_are_authority \
  prepare_computer_use_registration; do
  echo ">> $pattern"
  (cd "$hub" && cargo test --lib "$pattern" -- --nocapture)
done

if [[ "$live" == "--live" ]]; then
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "live computer-use probes require macOS" >&2
    exit 1
  fi
  echo "== live praefectus probe =="
  probe_out="$(cd "$hub" && cargo test --lib computer_use::tests::native_praefectus_capabilities_probe_is_internally_consistent -- --exact --nocapture 2>&1)"
  echo "$probe_out"
  if ! echo "$probe_out" | grep -q 'accessibility granted=true'; then
    echo "SKIP live semantic observation: grant Accessibility to Terminal/Cursor in System Settings, then re-run with --live"
    exit 0
  fi
  echo "== live semantic observation (OMI_LIVE_CU=1) =="
  (cd "$hub" && OMI_LIVE_CU=1 cargo test --lib computer_use::tests::live_semantic_observation_when_permitted -- --exact --nocapture)
fi

echo "computer-use checks passed"
