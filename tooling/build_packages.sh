#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
version=$(<"$root/VERSION")
build="$root/build"

ruby "$root/tooling/stage_shared_docs.rb"
rm -rf "$build"
mkdir -p "$build"

(
  cd "$root/packages/rails"
  gem build pi-browser-taskbar-rails.gemspec \
    --output "$build/pi-browser-taskbar-rails-$version.gem"
)

(
  cd "$root/packages/phoenix"
  mix hex.build --output "$build/pi_browser_taskbar_phoenix-$version.tar"
)

mkdir "$build/pi_browser_taskbar_phoenix"
tar -xOf "$build/pi_browser_taskbar_phoenix-$version.tar" contents.tar.gz \
  | tar -xz -C "$build/pi_browser_taskbar_phoenix"

printf 'built package artifacts and local Phoenix dependency in %s\n' "$build"
