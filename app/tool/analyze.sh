#!/usr/bin/env bash
set -euo pipefail

app_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$app_dir/build/ios/SourcePackages" "$app_dir/build/macos/SourcePackages"
cd "$app_dir"
# Infos/warnings elsewhere in the tree are tracked separately; this gate fails
# the job on analyzer errors only so a green bindings/format path is not
# blocked by pre-existing lint debt.
flutter analyze --no-fatal-infos --no-fatal-warnings
