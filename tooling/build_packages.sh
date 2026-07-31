#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
version=$(<"$root/VERSION")
build="$root/build"
export SOURCE_DATE_EPOCH=946684800
export TZ=UTC
export LC_ALL=C

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
  MIX_ENV=docs mix deps.get >/dev/null
  MIX_ENV=docs mix run "$root/tooling/build_hex_docs.exs" "$build/pi_browser_taskbar_phoenix-docs-$version.tar.gz"
)

mkdir "$build/pi_browser_taskbar_phoenix"
tar -xOf "$build/pi_browser_taskbar_phoenix-$version.tar" contents.tar.gz \
  | tar -xz -C "$build/pi_browser_taskbar_phoenix"

printf 'built package artifacts and local Phoenix dependency in %s\n' "$build"
