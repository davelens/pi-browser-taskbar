#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
version=$(<"$root/VERSION")
epoch=946684800
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pi-browser-taskbar-repro.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

for distribution in pi-browser-taskbar-rails-$version.gem pi_browser_taskbar_phoenix-$version.tar; do
  [[ -f "$root/build/$distribution" ]] || { echo "missing candidate build/$distribution; build artifacts once before checking reproducibility" >&2; exit 1; }
done

for run in first second; do
  copy="$tmp/$run"
  mkdir -p "$copy"
  (
    cd "$root"
    git ls-files -z | tar --null --files-from=- -cf -
  ) | tar -C "$copy" -xf -
  SOURCE_DATE_EPOCH="$epoch" TZ=UTC LC_ALL=C "$copy/tooling/build_packages.sh" >"$tmp/$run.log"
  node "$copy/tooling/build_browser_assets.mjs" --check

done

for distribution in pi-browser-taskbar-rails-$version.gem pi_browser_taskbar_phoenix-$version.tar; do
  first="$tmp/first/build/$distribution"
  second="$tmp/second/build/$distribution"
  candidate="$root/build/$distribution"
  cmp "$first" "$second" || { echo "$distribution differs between clean builds" >&2; sha256sum "$first" "$second" >&2; exit 1; }
  cmp "$candidate" "$first" || { echo "candidate $distribution differs from its clean rebuild" >&2; sha256sum "$candidate" "$first" >&2; exit 1; }
  sha256sum "$candidate"
done

printf '%s\n' 'artifact bytes reproduce across two clean tracked-file copies'
