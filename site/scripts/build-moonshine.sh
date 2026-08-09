#!/usr/bin/env bash
# Builds the moonshine marketing site into cloud/public/.
# Keeps /hub/, /portal/, and /engine/ (Flutter surfaces) untouched.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
moonshine="$(cd "$here/../web-moonshine" && pwd)"

cd "$moonshine"
bun install --frozen-lockfile
bun run build:static

echo "build-moonshine: done"
