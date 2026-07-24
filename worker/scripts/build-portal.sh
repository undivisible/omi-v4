#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
worker="$(dirname "$here")"
repo="$(dirname "$worker")"
app="$repo/app"
out="$worker/public/portal"

command -v flutter >/dev/null 2>&1 || {
  echo "build-portal: flutter not found on PATH" >&2
  exit 1
}

# The signed-in web app: no OMI_DEMO, so no seeded services and no demo path in
# the output at all. It boots to sign-in and, once signed in, to the same hub
# the desktop build shows. This is the deployment /portal serves; the public
# demo is built separately by build-hub.sh and lives at /hub/.
(cd "$app" && flutter build web --release --base-href=/portal/)

rm -rf "$out"
mkdir -p "$out"
cp -R "$app/build/web/." "$out/"

rm -f "$out/.last_build_id" "$out/flutter_service_worker.js" "$out/manifest.json"

# CanvasKit and the fallback face are shared with the /hub/ build and live at
# /engine/; portal-index.html points its base URLs there.
bash "$here/build-web-engine.sh" "$app/build/web"
rm -rf "$out/canvaskit"

cp "$here/portal-index.html" "$out/index.html"

echo "build-portal: wrote $out ($(du -sh "$out" | cut -f1) on disk)"
