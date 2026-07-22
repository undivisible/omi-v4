#!/usr/bin/env bash
# Runs each test suite in its own bun process (workerd/Miniflare state does
# not survive well across suites), retrying a failed suite once: Miniflare's
# instance disposal can race under machine load ("Broken pipe ... killed 1
# dangling process") and fail a healthy suite. A suite that fails twice in a
# row is a real failure.
set -u
suites=(
  test/app.test.ts
  test/routes.test.ts
  test/account.test.ts
  test/memory-sync.test.ts
  test/memory-vectors.test.ts
  test/currents.test.ts
  test/assistant.test.ts
  test/inbox-fallback.test.ts
  test/assistant-admission.test.ts
  test/stt.test.ts
  test/stt-admission.test.ts
  test/webhooks.test.ts
  test/desktop-auth.test.ts
  test/voice-oauth.test.ts
  test/asr-oauth-proxy.test.ts
)
for suite in "${suites[@]}"; do
  if ! bun test "$suite"; then
    echo "retrying $suite once (possible miniflare disposal flake)" >&2
    if ! bun test "$suite"; then
      exit 1
    fi
  fi
done
