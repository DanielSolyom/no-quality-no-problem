#!/usr/bin/env bash
# Called only after both engine-test profiles pass. Resume a pending tag instead
# of allocating another version if either portal publication or the mirror fails.
set -euo pipefail
archive=${1:?path to the validated archive}
: "${FACTORIO_VERSION:?}" "${MOD_VERSION:?}" "${RELEASE_DATE:?}" "${RELEASE_BRANCH:?}" "${RUN_URL:?}"
[[ "$FACTORIO_VERSION" =~ ^2\.1\.[0-9]+$ ]]
[[ "$MOD_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
tag="v$MOD_VERSION"

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git fetch origin "$RELEASE_BRANCH" --tags

if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
  # The only legitimate existing tag here is the checkpoint from this release.
  test "$(git rev-parse HEAD)" = "$(git rev-parse "$tag^{commit}")"
else
  # Do not include code pushed while tests were running. State-only commits do
  # not change the tested package and can be included in the fast-forward.
  git diff --exit-code HEAD "origin/$RELEASE_BRANCH" -- . ':!.github/factorio-releases.json'
  git checkout --detach "origin/$RELEASE_BRANCH"
fi

python3 scripts/factorio-releases.py prepare --engine "$FACTORIO_VERSION" --mod-version "$MOD_VERSION" --date "$RELEASE_DATE"

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
    assert info["dependencies"] == ["quality >= 2.1.0"], "Quality dependency changed"
PY

if ! git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
  # Save the tested version before any remote upload. A partial publication can
  # then be resumed from this exact tag by the next hourly check.
  python3 - <<'PY'
import json, os, pathlib, subprocess
path = pathlib.Path(".github/factorio-releases.json")
state = json.loads(path.read_text())
state["checked"][os.environ["FACTORIO_VERSION"]] = {
    "status": "passed", "release_status": "pending",
    "mod_version": os.environ["MOD_VERSION"], "release_ref": "v" + os.environ["MOD_VERSION"],
    "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "source_fingerprint": subprocess.check_output(["python3", "scripts/factorio-releases.py", "fingerprint"], text=True).strip(),
    "run_url": os.environ["RUN_URL"],
}
path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
PY
  git add no-quality-no-problem/info.json no-quality-no-problem/changelog.txt .github/factorio-releases.json
  git commit -m "Release $MOD_VERSION for Factorio $FACTORIO_VERSION experimental"
  git tag "$tag"
  git push --atomic origin "HEAD:refs/heads/$RELEASE_BRANCH" "refs/tags/$tag"
fi

./publish.sh --zip "$archive" --sync-details
notes=$(mktemp)
trap 'rm -f -- "$notes"' EXIT
printf 'Compatibility release validated against Factorio %s experimental, with and without Space Age.\n\nValidation: %s\n\nMod portal: https://mods.factorio.com/mod/no-quality-no-problem\n' \
  "$FACTORIO_VERSION" "$RUN_URL" > "$notes"
if gh release view "$tag" >/dev/null 2>&1; then
  gh release upload "$tag" "$archive" --clobber
else
  gh release create "$tag" "$archive" --verify-tag --title "$tag — Factorio $FACTORIO_VERSION" --notes-file "$notes"
fi
