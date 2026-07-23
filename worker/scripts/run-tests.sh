#!/usr/bin/env bash
# Runs each test suite in its own bun process (workerd/Miniflare state does
# not survive well across suites), retrying a failed suite once: Miniflare's
# instance disposal can race under machine load ("Broken pipe ... killed 1
# dangling process") and fail a healthy suite. A suite that fails twice in a
# row is a real failure.
set -u
for suite in test/*.test.ts; do
  if ! bun test "$suite"; then
    echo "retrying $suite once (possible miniflare disposal flake)" >&2
    if ! bun test "$suite"; then
      exit 1
    fi
  fi
done
