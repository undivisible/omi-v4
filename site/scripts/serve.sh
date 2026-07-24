#!/usr/bin/env bash
# Runs the site with hot reload at http://localhost:8080.
#
# The hub embed is not available here: the iframe points at /hub/, which only
# the Worker serves. Run `bun run dev` in `worker/` to see the site and the
# hub together.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
site="$(dirname "$here")"

if ! dart --version >/dev/null 2>&1 ||
  ! [ -f "$(dirname "$(readlink -f "$(command -v dart)")")/../version" ]; then
  flutter_bin="$(dirname "$(readlink -f "$(command -v flutter)")")"
  export PATH="$flutter_bin:$PATH"
fi

export PATH="$PATH:$HOME/.pub-cache/bin"
cd "$site" && exec jaspr serve "$@"
