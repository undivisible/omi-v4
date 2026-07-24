#!/usr/bin/env bash
set -euo pipefail

# The engine assets both web builds load, published once at /engine/ instead of
# once per build. CanvasKit alone is 13 MB on disk; the demo at /hub/ and the
# signed-in app at /portal/ are the same Flutter version and would otherwise
# ship two byte-identical copies to the same origin. Both build scripts call
# this, so either one on its own leaves the origin complete.
#
#   $1  a finished `flutter build web` output directory (source of canvaskit)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
worker="$(dirname "$here")"
build="$1"
out="$worker/public/engine"

rm -rf "$out"
mkdir -p "$out"
cp -R "$build/canvaskit" "$out/canvaskit"

rm -rf "$out/canvaskit/experimental_webparagraph"
find "$out/canvaskit" -maxdepth 2 -name '*.symbols' -delete
find "$out/canvaskit" -maxdepth 1 \( -name 'skwasm*' -o -name 'wimp*' \) -delete

# The engine's glyph fallback, served from this origin rather than from
# fonts.gstatic.com — see fontFallbackBaseUrl in the two index.html files. The
# licence travels with the face.
cp -R "$worker/assets/hub-fallback-fonts" "$out/fallback-fonts"

echo "build-web-engine: wrote $out ($(du -sh "$out" | cut -f1) on disk)"
