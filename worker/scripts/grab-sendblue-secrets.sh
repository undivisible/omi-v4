#!/usr/bin/env bash
set -euo pipefail

# Pull Sendblue API credentials into worker/.dev.vars.
#
# Source order:
#   1. ~/.sendblue/credentials.json (written by `sendblue setup` / `sendblue login`)
#   2. `npx @sendblue/cli show-keys` when the JSON file is absent
#   3. Existing SENDBLUE_API_KEY / SENDBLUE_SECRET_KEY already in .dev.vars
#
# Writes both naming schemes:
#   SENDBLUE_API_KEY / SENDBLUE_SECRET_KEY       (Sendblue CLI / dashboard names)
#   SENDBLUE_API_KEY_ID / SENDBLUE_API_KEY_SECRET (worker header env names)
#
# Stripe is intentionally untouched — billing stays disabled until STRIPE_* is
# provisioned deliberately. Use push-secrets.sh --apply to upload Sendblue vars
# to the deployed worker after this script runs.
#
#   ./scripts/grab-sendblue-secrets.sh
#   ./scripts/grab-sendblue-secrets.sh --push          # grab + wrangler secret put
#   ./scripts/grab-sendblue-secrets.sh --number-only   # only refresh SENDBLUE_NUMBER

cd "$(dirname "$0")/.."
VARS_FILE="${VARS_FILE:-.dev.vars}"
CREDS_FILE="${HOME}/.sendblue/credentials.json"
push=0
number_only=0

while [ $# -gt 0 ]; do
  case "$1" in
    --push) push=1 ;;
    --number-only) number_only=1 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

read_var() {
  local key="$1"
  [ -f "${VARS_FILE}" ] || return 1
  local line
  line="$(grep -m1 "^${key}=" "${VARS_FILE}" 2>/dev/null || true)"
  [ -n "${line}" ] || return 1
  printf '%s' "${line#*=}"
}

upsert_var() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  if [ -f "${VARS_FILE}" ]; then
    awk -v k="${key}" -v v="${value}" '
      BEGIN { done = 0 }
      $0 ~ "^" k "=" { print k "=" v; done = 1; next }
      { print }
      END { if (!done) print k "=" v }
    ' "${VARS_FILE}" >"${tmp}"
  else
    printf '%s=%s\n' "${key}" "${value}" >"${tmp}"
  fi
  mv "${tmp}" "${VARS_FILE}"
  chmod 600 "${VARS_FILE}" 2>/dev/null || true
}

json_field() {
  local file="$1"
  local field="$2"
  python3 - "${file}" "${field}" <<'PY'
import json, sys
path, field = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(field, "")
if not isinstance(value, str) or not value.strip():
    raise SystemExit(1)
print(value.strip(), end="")
PY
}

parse_show_keys() {
  local raw key secret
  raw="$(npx -y @sendblue/cli show-keys 2>/dev/null || true)"
  key="$(printf '%s\n' "${raw}" | sed -n 's/^[[:space:]]*API Key:[[:space:]]*//p' | head -1)"
  secret="$(printf '%s\n' "${raw}" | sed -n 's/^[[:space:]]*API Secret:[[:space:]]*//p' | head -1)"
  if [ -z "${key}" ] || [ -z "${secret}" ]; then
    return 1
  fi
  printf '%s\n%s' "${key}" "${secret}"
}

fetch_lines_number() {
  local api_key="$1"
  local api_secret="$2"
  local raw number
  raw="$(SENDBLUE_API_KEY_ID="${api_key}" SENDBLUE_API_KEY_SECRET="${api_secret}" \
    npx -y @sendblue/cli lines 2>/dev/null || true)"
  number="$(printf '%s\n' "${raw}" | grep -Eo '\+[0-9]{10,15}' | head -1 || true)"
  [ -n "${number}" ] || return 1
  printf '%s' "${number}"
}

api_key=""
api_secret=""

if [ -f "${CREDS_FILE}" ]; then
  api_key="$(json_field "${CREDS_FILE}" apiKey)" || true
  api_secret="$(json_field "${CREDS_FILE}" apiSecret)" || true
fi

if [ -z "${api_key}" ] || [ -z "${api_secret}" ]; then
  if parsed="$(parse_show_keys)"; then
    api_key="$(printf '%s\n' "${parsed}" | sed -n '1p')"
    api_secret="$(printf '%s\n' "${parsed}" | sed -n '2p')"
  fi
fi

if [ -z "${api_key}" ] || [ -z "${api_secret}" ]; then
  api_key="$(read_var SENDBLUE_API_KEY || read_var SENDBLUE_API_KEY_ID || true)"
  api_secret="$(read_var SENDBLUE_SECRET_KEY || read_var SENDBLUE_API_KEY_SECRET || true)"
fi

if [ "${number_only}" -eq 0 ]; then
  if [ -z "${api_key}" ] || [ -z "${api_secret}" ]; then
    cat >&2 <<'EOF'
Could not find Sendblue credentials.

Run one of:
  npx -y @sendblue/cli setup
  npx -y @sendblue/cli login

Then re-run:
  ./scripts/grab-sendblue-secrets.sh
EOF
    exit 1
  fi

  upsert_var SENDBLUE_API_KEY "${api_key}"
  upsert_var SENDBLUE_SECRET_KEY "${api_secret}"
  upsert_var SENDBLUE_API_KEY_ID "${api_key}"
  upsert_var SENDBLUE_API_KEY_SECRET "${api_secret}"
  printf 'updated  SENDBLUE_API_KEY\n'
  printf 'updated  SENDBLUE_SECRET_KEY\n'
  printf 'updated  SENDBLUE_API_KEY_ID\n'
  printf 'updated  SENDBLUE_API_KEY_SECRET\n'
fi

if [ -n "${api_key}" ] && [ -n "${api_secret}" ]; then
  if number="$(fetch_lines_number "${api_key}" "${api_secret}")"; then
    upsert_var SENDBLUE_NUMBER "${number}"
    printf 'updated  SENDBLUE_NUMBER\n'
  else
    printf 'skip     SENDBLUE_NUMBER (run sendblue lines after login)\n'
  fi
fi

if [ "${push}" -eq 1 ]; then
  exec "$(dirname "$0")/push-secrets.sh" --apply
fi

printf '\nStripe left disabled (STRIPE_* not written). Push Sendblue with:\n'
printf '  ./scripts/push-secrets.sh --apply\n'
