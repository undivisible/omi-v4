#!/usr/bin/env bash
# Builds the static site and copies it over the Worker's asset directory.
#
# The Worker serves `worker/public/` as static assets, so that directory is
# the site's output — everything in it except `hub/`, `portal/` and `engine/`
# is generated. Those three are Flutter web output produced separately
# (`worker/scripts/build-hub.sh`, `build-portal.sh`, `build-web-engine.sh`) and
# are left untouched here.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
site="$(dirname "$here")"
repo="$(dirname "$site")"
out="$repo/worker/public"
staged="$site/build/jaspr"

# The Jaspr CLI needs a real Dart SDK on PATH; the Homebrew shim resolves
# outside one, so fall back to the SDK bundled with Flutter.
if ! dart --version >/dev/null 2>&1 ||
  ! [ -f "$(dirname "$(readlink -f "$(command -v dart)")")/../version" ]; then
  flutter_bin="$(dirname "$(readlink -f "$(command -v flutter)")")"
  export PATH="$flutter_bin:$PATH"
fi

export PATH="$PATH:$HOME/.pub-cache/bin"
command -v jaspr >/dev/null 2>&1 || {
  echo "build-site: jaspr not found. Run: dart pub global activate jaspr_cli" >&2
  exit 1
}

(cd "$site" && dart pub get >/dev/null && jaspr build)

# Build artefacts that must never be served: the dev-compiler's package tree,
# the build manifest, and the package config. Jaspr writes them beside the
# pages; none of them belong on a public origin.
rm -rf "$staged/packages" "$staged/.dart_tool"
rm -f "$staged/.build.manifest"

mkdir -p "$out"

# Replace every generated file, and delete the ones a previous build left
# behind, without touching the separately built Flutter surfaces.
rsync --archive --delete \
  --exclude '/hub/' --exclude '/portal/' --exclude '/engine/' \
  "$staged/" "$out/"

echo "build-site: wrote $out ($(du -sh "$staged" | cut -f1) of site, apps kept)"
