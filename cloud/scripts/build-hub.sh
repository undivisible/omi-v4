#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cloud="$(dirname "$here")"
repo="$(dirname "$cloud")"
app="$repo/app"
out="$cloud/public/hub"

command -v flutter >/dev/null 2>&1 || {
  echo "build-hub: flutter not found on PATH" >&2
  exit 1
}

# OMI_DEMO=1 builds the public demo: the same shell and the same widgets, but
# booted against seeded in-process services (app/lib/demo/). It never signs in,
# never reaches onboarding, and makes no network request of any kind. This is
# the build the marketing site's "Try the hub" embed loads; the signed-in web
# app is a different deployment and must not be built from here.
(cd "$app" && flutter build web --release --base-href=/hub/ \
  --dart-define=OMI_DEMO=1 --no-wasm-dry-run)

rm -rf "$out"
mkdir -p "$out"
cp -R "$app/build/web/." "$out/"

rm -f "$out/.last_build_id" "$out/flutter_service_worker.js" "$out/manifest.json"

# CanvasKit and the fallback face are shared with the /portal/ build and live
# at /engine/; the two index.html files point their base URLs there.
bash "$here/build-web-engine.sh" "$app/build/web"
rm -rf "$out/canvaskit"

cp "$here/hub-index.html" "$out/index.html"
cp "$here/hub-llm.js" "$out/hub-llm.js"

echo "build-hub: wrote $out ($(du -sh "$out" | cut -f1) on disk)"
