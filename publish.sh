#!/usr/bin/env bash
# Publish this mod to the Factorio mod portal.
#
#   FACTORIO_API_KEY=... ./publish.sh [mod-dir] [flags]
#
#   (no flags)        upload a new release of an already-published mod
#   --first-publish   create the mod on the portal for the very first time
#   --sync-details    also push portal.json (title/summary/description/tags/...)
#   --check-key       verify the API key works, then exit (no upload)
#   --target 2.0      build and upload the 2.0-targeted release instead of 2.1
#
# API key: https://factorio.com/profile -> API keys. Required "usages":
#   ModPortal: Upload Mods    for a normal release
#   ModPortal: Publish Mods   additionally, for --first-publish
#   ModPortal: Edit Mods      additionally, for --sync-details
#
# Endpoints (wiki.factorio.com/Mod_upload_API, /Mod_publish_API, /Mod_details_API):
#   POST /api/v2/mods/releases/init_upload  Bearer + form `mod`   -> {upload_url}
#   POST /api/v2/mods/init_publish          Bearer + form `mod`   -> {upload_url}
#   POST $upload_url                        multipart `file`      -> {success:true}
#   POST /api/v2/mods/edit_details          Bearer + form fields  -> {success:true}
#
# There is no delete API: a published mod name is permanent.
set -euo pipefail

: "${FACTORIO_API_KEY:?set FACTORIO_API_KEY}"
API="https://mods.factorio.com/api"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

first_publish=0; sync_details=0; check_key=0; target=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --first-publish) first_publish=1 ;;
    --sync-details)  sync_details=1 ;;
    --check-key)     check_key=1 ;;
    --target)        target="${2:?--target needs a value}"; shift ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) args+=("$1") ;;
  esac
  shift
done
mod_dir="${args[0]:-no-quality-no-problem}"

name=$(jq -r .name "$root/$mod_dir/info.json")

post() { # post <endpoint> [curl args...]
  local ep="$1"; shift
  curl -sS -X POST "$API/v2/mods/$ep" -H "Authorization: Bearer $FACTORIO_API_KEY" "$@"
}

# A valid key on a nonexistent mod answers UnknownMod; a bad key answers InvalidApiKey.
if [ "$check_key" -eq 1 ]; then
  probe=$(post edit_details --data-urlencode "mod=this-mod-does-not-exist-$RANDOM")
  case "$(jq -r '.error // "none"' <<<"$probe")" in
    UnknownMod) echo "API key works (has at least Edit Mods)"; exit 0 ;;
    InvalidApiKey) echo "API key rejected: $(jq -r .message <<<"$probe")" >&2; exit 1 ;;
    *) echo "unexpected probe response: $(jq -c . <<<"$probe")" >&2; exit 1 ;;
  esac
fi

# build.sh prints the zip it produced; the 2.0 target gets its own version.
zip=$("$root/build.sh" "$mod_dir" "$target")
[ -f "$zip" ] || { echo "build produced no zip" >&2; exit 1; }
version=$(unzip -p "$zip" '*/info.json' | jq -r .version)

# The portal rejects zips containing executables (exe/bat/ps1/sh/py).
if unzip -Z1 "$zip" | grep -qiE '\.(exe|bat|ps1|sh|py)$'; then
  echo "zip contains executable files; the portal will reject it" >&2; exit 1
fi

# Skip (not fail) re-uploading an existing version, so --sync-details still
# runs when the release itself is already up (e.g. after a manual first upload).
skip_upload=0
if [ "$first_publish" -ne 1 ] \
   && curl -fsS "$API/mods/$name/full" 2>/dev/null \
      | jq -e --arg v "$version" '.releases[]? | select(.version == $v)' >/dev/null; then
  echo "version $version is already on the portal; skipping upload"
  skip_upload=1
fi

if [ "$skip_upload" -eq 0 ]; then
  if [ "$first_publish" -eq 1 ]; then
    init=$(post init_publish --data-urlencode "mod=$name")
  else
    init=$(post releases/init_upload --data-urlencode "mod=$name")
  fi

  upload_url=$(jq -r '.upload_url // empty' <<<"$init")
  [ -n "$upload_url" ] || { echo "init failed: $(jq -c . <<<"$init")" >&2; exit 1; }
  echo "::add-mask::$upload_url"   # upload_url is bearer-equivalent; no-op outside GH Actions

  res=$(curl -sS -X POST "$upload_url" -F "file=@${zip};type=application/x-zip-compressed")
  [ "$(jq -r '.success // false' <<<"$res")" = "true" ] \
    || { echo "upload failed: $(jq -c . <<<"$res")" >&2; exit 1; }
  echo "published $name $version"
fi

# ---------------------------------------------------------------------------
# Portal page content lives in the repo (portal.json + the referenced markdown),
# so the mod page is reproducible from git instead of hand-edited on the web.
# ---------------------------------------------------------------------------
if [ "$sync_details" -eq 1 ]; then
  cfg="$root/portal.json"
  [ -f "$cfg" ] || { echo "--sync-details needs $cfg" >&2; exit 1; }

  fields=(--data-urlencode "mod=$name")
  for k in title summary category license homepage source_url; do
    v=$(jq -r --arg k "$k" '.[$k] // empty' "$cfg")
    [ -n "$v" ] && fields+=(--data-urlencode "$k=$v")
  done
  for k in description faq; do
    f=$(jq -r --arg k "${k}_file" '.[$k] // empty' "$cfg")
    [ -n "$f" ] && [ -f "$root/$f" ] && fields+=(--data-urlencode "$k@$root/$f")
  done
  while IFS= read -r tag; do
    [ -n "$tag" ] && fields+=(--data-urlencode "tags=$tag")
  done < <(jq -r '.tags[]? // empty' "$cfg")

  det=$(post edit_details "${fields[@]}")
  [ "$(jq -r '.success // false' <<<"$det")" = "true" ] \
    || { echo "edit_details failed: $(jq -c . <<<"$det")" >&2; exit 1; }
  echo "synced portal page details from portal.json"
fi
