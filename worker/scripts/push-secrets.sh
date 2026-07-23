#!/usr/bin/env bash
set -euo pipefail

# Pushes the secrets in .dev.vars to a deployed worker.
#
# Values are piped straight from the file into `wrangler secret put` and are
# never echoed, logged, or passed as arguments (argv is world-readable via ps).
# Only key NAMES are printed, so the output is safe to paste into a terminal
# someone else can see.
#
#   ./scripts/push-secrets.sh                 # dry run against the default env
#   ./scripts/push-secrets.sh --apply         # actually set them
#   ./scripts/push-secrets.sh --apply --env staging
#   WORKER_DIR=../worker-rs ./scripts/push-secrets.sh --apply

cd "$(dirname "$0")/.."
WORKER_DIR="${WORKER_DIR:-.}"
VARS_FILE="${VARS_FILE:-.dev.vars}"

apply=0
env_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --env) shift; env_args=(--env "$1") ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ ! -f "${VARS_FILE}" ]; then
  echo "no ${VARS_FILE} in $(pwd)" >&2
  exit 1
fi

# Only these reach a deployed worker. Everything else in .dev.vars is either a
# local-development toggle (DEV_FAKE_PRO), a plain non-secret config value, or
# belongs to a subsystem that no longer exists — pushing those would resurrect
# dead configuration as live state.
PUSHABLE="
TELEGRAM_BOT_TOKEN
TELEGRAM_WEBHOOK_SECRET
BLOOIO_API_KEY
BLOOIO_WEBHOOK_SIGNING_SECRET
GEMINI_API_KEY
MIMO_API_KEY
DEEPGRAM_API_KEY
"

pushable() {
  case "${PUSHABLE}" in
    *"
$1
"*) return 0 ;;
  esac
  return 1
}

pushed=0
skipped=0
while IFS= read -r line || [ -n "${line}" ]; do
  case "${line}" in
    ''|'#'*) continue ;;
    *=*) ;;
    *) continue ;;
  esac
  key="${line%%=*}"
  # Trim whitespace and reject anything that is not a plain env-var name, so a
  # malformed line can never turn into a wrangler flag.
  key="$(printf '%s' "${key}" | tr -d '[:space:]')"
  case "${key}" in
    ''|*[!A-Za-z0-9_]*) continue ;;
  esac
  if ! pushable "${key}"; then
    printf 'skip  %s (not in the pushable set)\n' "${key}"
    skipped=$((skipped + 1))
    continue
  fi
  if [ "${apply}" -eq 0 ]; then
    printf 'would push  %s\n' "${key}"
    pushed=$((pushed + 1))
    continue
  fi
  # The value is read again here rather than held in a variable, and goes in
  # over stdin so it never appears in argv.
  value="$(grep -m1 "^${key}=" "${VARS_FILE}" | cut -d= -f2-)"
  printf '%s' "${value}" | bunx wrangler secret put "${key}" "${env_args[@]+"${env_args[@]}"}" >/dev/null
  unset value
  printf 'pushed  %s\n' "${key}"
  pushed=$((pushed + 1))
done < "${VARS_FILE}"

if [ "${apply}" -eq 0 ]; then
  printf '\ndry run — %d would be pushed, %d skipped. Re-run with --apply.\n' \
    "${pushed}" "${skipped}"
else
  printf '\n%d pushed, %d skipped.\n' "${pushed}" "${skipped}"
fi
