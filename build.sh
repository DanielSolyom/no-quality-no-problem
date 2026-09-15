#!/usr/bin/env bash
# Package the mod into a portal-ready zip: <name>_<version>.zip containing a
# single top-level folder <name>_<version>/ (the layout the game expects).
#
#   ./build.sh [mod-dir] [target-factorio-version]
#
# The optional second argument retargets info.json to another major Factorio
# version (patch digit +1 to keep versions unique). The normal release needs
# no arguments.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mod_dir="${1:-no-quality-no-problem}"
[ -n "$mod_dir" ] || mod_dir=no-quality-no-problem
target_fv="${2:-}"
src="$root/$mod_dir"

[ -f "$src/info.json" ] || { echo "no info.json in $src" >&2; exit 1; }

name=$(jq -r .name "$src/info.json")
version=$(jq -r .version "$src/info.json")

# Syntax-check every Lua file first (luajit or luac, whichever exists).
if command -v luajit >/dev/null; then checker=(luajit -bl)
elif command -v luac >/dev/null; then checker=(luac -p)
else checker=(); fi
if [ ${#checker[@]} -gt 0 ]; then
  while IFS= read -r -d '' f; do
    "${checker[@]}" "$f" >/dev/null || { echo "lua syntax error: $f" >&2; exit 1; }
  done < <(find "$src" -name '*.lua' -print0)
fi

if [ -n "$target_fv" ] && [ "$target_fv" != "$(jq -r .factorio_version "$src/info.json")" ]; then
  version=$(python3 -c "
major, minor, patch = '$version'.split('.')
print(f'{major}.{minor}.{int(patch) + 1}')")
fi

stage="$root/.build/${name}_${version}"
out="$root/dist/${name}_${version}.zip"

rm -rf "$root/.build"; mkdir -p "$stage" "$root/dist"; rm -f "$out"
# Copy mod content, excluding VCS/editor noise.
(cd "$src" && tar --exclude-vcs --exclude='*.zip' -cf - .) | (cd "$stage" && tar -xf -)

if [ -n "$target_fv" ]; then
  python3 -c "
import json
p = '$stage/info.json'
i = json.load(open(p))
i['version'] = '$version'
i['factorio_version'] = '$target_fv'
i['dependencies'] = ['quality >= ${target_fv}.0']
json.dump(i, open(p, 'w'), indent=2)
open(p, 'a').write('\n')"
fi

(cd "$root/.build" && zip -qr "$out" "${name}_${version}")
rm -rf "$root/.build"

echo "$out"
