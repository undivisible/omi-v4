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

# OMI_DEMO=1 builds the public demo: the same shell and the same widgets, but
# booted against seeded in-process services (app/lib/demo/). It never signs in,
# never reaches onboarding, and makes no network request of any kind. This is
# the build the marketing site's "Try the hub" embed loads; the signed-in web
# app is a different deployment and must not be built from here.
(cd "$app" && flutter build web --release --base-href=/hub/ \
  --dart-define=OMI_DEMO=1)

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

# The optional on-device model tier. transformers.js and the ONNX runtime are
# vendored onto this origin so the demo never loads code from a third party;
# only the model weights are fetched, and only after the visitor has clicked
# an opt-in that named the download size. If this step cannot run — no
# network, no bun — the tier is simply not offered: hub-llm.js probes for
# vendor/transformers.js and reports the tier unavailable when it is absent.
vendor="$out/vendor"
cache="$worker/.cache/hub-vendor"
if command -v bun >/dev/null 2>&1; then
  mkdir -p "$cache"
  # Its own manifest, so the install lands here and not in the Worker's
  # node_modules: bun installs into the nearest package.json above the cwd.
  [ -f "$cache/package.json" ] ||
    printf '{"name":"omi-hub-vendor","private":true}\n' >"$cache/package.json"
  runtime="$cache/node_modules/@huggingface/transformers/dist/transformers.web.js"
  if (cd "$cache" && bun add @huggingface/transformers@4.2.0 >/dev/null 2>&1) &&
    [ -f "$runtime" ]; then
    mkdir -p "$vendor"
    cp "$runtime" "$vendor/transformers.js"
    cp "$cache/node_modules/@huggingface/transformers/LICENSE" \
      "$vendor/transformers-LICENSE.txt" 2>/dev/null || true
    # Only the runtime variants this tier can reach: the WebGPU builds and the
    # plain SIMD one they fall back to. The JSPI build is another 14 MB of
    # wasm that nothing here would load.
    # transformers.js imports the ONNX runtime by bare specifier; the import
    # map in index.html points those two names at these files.
    cp "$cache/node_modules/onnxruntime-web/dist/ort.webgpu.bundle.min.mjs" \
      "$vendor/" 2>/dev/null || true
    mkdir -p "$vendor/ort-common"
    cp "$cache"/node_modules/onnxruntime-common/dist/esm/*.js "$vendor/ort-common/" \
      2>/dev/null || true
    for variant in ort-wasm-simd-threaded ort-wasm-simd-threaded.jsep \
      ort-wasm-simd-threaded.asyncify; do
      cp "$cache/node_modules/onnxruntime-web/dist/$variant.wasm" "$vendor/" \
        2>/dev/null || true
      cp "$cache/node_modules/onnxruntime-web/dist/$variant.mjs" "$vendor/" \
        2>/dev/null || true
    done
    echo "build-hub: vendored transformers.js ($(du -sh "$vendor" | cut -f1))"
  else
    echo "build-hub: transformers.js not vendored — the WebGPU tier is off" >&2
  fi
else
  echo "build-hub: bun not found — the WebGPU tier is off" >&2
fi

echo "build-hub: wrote $out ($(du -sh "$out" | cut -f1) on disk)"
