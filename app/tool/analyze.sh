#!/usr/bin/env bash
set -euo pipefail

app_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$app_dir/build/ios/SourcePackages" "$app_dir/build/macos/SourcePackages"
cd "$app_dir"
flutter analyze
