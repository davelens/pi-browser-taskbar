#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
version=$(<"$root/VERSION")
build="$root/build"

mkdir -p "$build"
find "$build" -mindepth 1 -maxdepth 1 -type f -delete

(
  cd "$root/packages/rails"
  gem build pi-browser-taskbar-rails.gemspec \
    --output "$build/pi-browser-taskbar-rails-$version.gem"
)

(
  cd "$root/packages/phoenix"
  mix hex.build --output "$build/pi_browser_taskbar_phoenix-$version.tar"
)

printf 'built package artifacts in %s\n' "$build"
