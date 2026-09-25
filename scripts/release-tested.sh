#!/usr/bin/env bash
# Called only after all CI checks pass. Resume a frozen tag instead of allocating
# another version if either portal publication or the mirror fails.
set -euo pipefail
archive=${1:?path to the validated archive}
: "${FACTORIO_VERSION:?}" "${MOD_VERSION:?}" "${RELEASE_DATE:?}" "${RELEASE_BRANCH:?}" "${RUN_URL:?}"
export RELEASE_KIND=${RELEASE_KIND:-factorio}
export RELEASE_CHANNEL=${RELEASE_CHANNEL:-experimental}
[[ "$RELEASE_KIND" = factorio || "$RELEASE_KIND" = main ]]
[[ "$RELEASE_CHANNEL" = experimental || "$RELEASE_CHANNEL" = stable ]]
[[ "$FACTORIO_VERSION" =~ ^2\.1\.[0-9]+$ ]]
[[ "$MOD_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
tag="v$MOD_VERSION"

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git fetch origin "$RELEASE_BRANCH" --tags
SOURCE_COMMIT=$(git rev-parse HEAD)
export SOURCE_COMMIT

if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
  # Re-running just the publication job checks out the original source again.
  # Verify the channel even when a retry already checked out the frozen tag.
  python3 - "$tag" <<'PY'
import json, os, subprocess, sys
state = json.loads(subprocess.check_output(["git", "show", f"{sys.argv[1]}:.github/factorio-releases.json"], text=True))
checkpoint = subprocess.check_output(["git", "rev-parse", sys.argv[1] + "^{commit}"], text=True).strip()
key = "stable_checked" if os.environ["RELEASE_CHANNEL"] == "stable" else "checked"
entry = (state.get("main_release", {}) if os.environ["RELEASE_KIND"] == "main"
         else state.get(key, {}).get(os.environ["FACTORIO_VERSION"], {}))
if (os.environ["SOURCE_COMMIT"] not in {entry.get("source_commit"), checkpoint}
        or entry.get("mod_version") != os.environ["MOD_VERSION"]
        or entry.get("release_date") != os.environ["RELEASE_DATE"]):
    raise SystemExit("Existing tag belongs to a different release")
PY
  git checkout --detach "$tag"
else
  # Do not include code pushed while tests were running. State-only commits do
  # not change the tested package and can be included in the fast-forward.
  git diff --exit-code HEAD "origin/$RELEASE_BRANCH" -- . ':!.github/factorio-releases.json'
  git checkout --detach "origin/$RELEASE_BRANCH"
fi

python3 scripts/factorio-releases.py prepare --engine "$FACTORIO_VERSION" --mod-version "$MOD_VERSION" --date "$RELEASE_DATE" --kind "$RELEASE_KIND" --channel "$RELEASE_CHANNEL"

# Check every archived file, not just info.json: publication must use exactly the
# package that passed the engine scenarios. No rebuilding after validation.
python3 - "$archive" <<'PY'
import json, os, pathlib, sys, zipfile
source = pathlib.Path("no-quality-no-problem")
prefix = f"no-quality-no-problem_{os.environ['MOD_VERSION']}/"
with zipfile.ZipFile(sys.argv[1]) as archive:
    files = {item.filename: archive.read(item) for item in archive.infolist() if not item.is_dir()}
    expected = {prefix + str(p.relative_to(source)): p.read_bytes() for p in source.rglob("*") if p.is_file()}
    if files != expected:
        raise SystemExit("Validated archive does not match the release source")
    info = json.loads(files[prefix + "info.json"])
    assert "quality >= 2.1.0" in info["dependencies"], "Required Quality dependency changed"
PY

if ! git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
  # Save the tested version before any remote upload. A partial publication can
  # then be resumed from this exact tag by a CI retry or the next hourly check.
  python3 - <<'PY'
import json, os, pathlib, subprocess
path = pathlib.Path(".github/factorio-releases.json")
state = json.loads(path.read_text())
entry = {
    "status": "passed",
    "mod_version": os.environ["MOD_VERSION"], "release_ref": "v" + os.environ["MOD_VERSION"],
    "source_commit": os.environ["SOURCE_COMMIT"],
    "source_fingerprint": subprocess.check_output(["python3", "scripts/factorio-releases.py", "fingerprint"], text=True).strip(),
    "run_url": os.environ["RUN_URL"],
    "release_date": os.environ["RELEASE_DATE"],
}
if os.environ["RELEASE_KIND"] == "main":
    state["main_release"] = entry
else:
    entry["release_status"] = "pending"
    key = "stable_checked" if os.environ["RELEASE_CHANNEL"] == "stable" else "checked"
    state.setdefault(key, {})[os.environ["FACTORIO_VERSION"]] = entry
path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
PY
  git add no-quality-no-problem/info.json no-quality-no-problem/changelog.txt .github/factorio-releases.json
  message="Release $MOD_VERSION"
  if [ "$RELEASE_KIND" = factorio ]; then
    message+=" for Factorio $FACTORIO_VERSION $RELEASE_CHANNEL"
  fi
  git commit -m "$message"
  git tag "$tag"
  git push --atomic origin "HEAD:refs/heads/$RELEASE_BRANCH" "refs/tags/$tag"
fi

./publish.sh --zip "$archive" --sync-details
notes=$(mktemp)
trap 'rm -f -- "$notes"' EXIT
awk -v v="$MOD_VERSION" '
  /^Version: / { p = ($2 == v); next }
  /^----/ { p = 0; next }
  p' no-quality-no-problem/changelog.txt > "$notes"
printf '\nValidation: %s\n\nMod portal: https://mods.factorio.com/mod/no-quality-no-problem\n' "$RUN_URL" >> "$notes"
title="$tag"
if [ "$RELEASE_KIND" = factorio ]; then title+=" — Factorio $FACTORIO_VERSION $RELEASE_CHANNEL"; fi
if gh release view "$tag" >/dev/null 2>&1; then
  gh release upload "$tag" "$archive" --clobber
else
  gh release create "$tag" "$archive" --verify-tag --title "$title" --notes-file "$notes"
fi
