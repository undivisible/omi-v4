#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
worker="$(dirname "$here")"
repo="$(dirname "$worker")"
app="$repo/app"
out="$worker/public/hub"

command -v flutter >/dev/null 2>&1 || {
  echo "build-hub: flutter not found on PATH" >&2
  exit 1
}

(cd "$app" && flutter build web --release --base-href=/hub/)

rm -rf "$out"
mkdir -p "$out"
cp -R "$app/build/web/." "$out/"

rm -f "$out/.last_build_id" "$out/flutter_service_worker.js" "$out/manifest.json"
rm -rf "$out/canvaskit/experimental_webparagraph"
find "$out/canvaskit" -maxdepth 2 -name '*.symbols' -delete
find "$out/canvaskit" -maxdepth 1 \( -name 'skwasm*' -o -name 'wimp*' \) -delete

cp "$here/hub-index.html" "$out/index.html"

echo "build-hub: wrote $out ($(du -sh "$out" | cut -f1) on disk)"
