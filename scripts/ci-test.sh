#!/usr/bin/env bash
# CI test runner for the no-quality-no-problem mod.
#
#   ci-test.sh data       data-stage load + prototype assertions (vs. a baseline dump)
#   ci-test.sh runtime    control-stage assertions via --scenario2map
#   ci-test.sh all        both (default)
#
# Every Factorio invocation uses an isolated write-data directory and an explicit
# --mod-directory, so a run never touches real saves/mods/script-output.
#
# Env:
#   FACTORIO_BIN  path to the factorio executable (required)
#   MOD_ROOT      mod source dir (default: <repo>/no-quality-no-problem)
#   WORK          scratch dir (default: <repo>/.testrun)
#   TARGET_FV     Factorio major version under test: 2.1 (default) or 2.0.
#                 2.0 stages info.json with factorio_version 2.0 and drops the
#                 recycler mod, which does not exist in the 2.0 data files.
set -uo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MOD_ROOT="${MOD_ROOT:-$REPO/no-quality-no-problem}"
MOD_NAME="$(python3 -c "import json;print(json.load(open('$MOD_ROOT/info.json'))['name'])")"
MOD_VERSION="$(python3 -c "import json;print(json.load(open('$MOD_ROOT/info.json'))['version'])")"
FACTORIO="${FACTORIO_BIN:?set FACTORIO_BIN to the factorio executable}"
WORK="${WORK:-$REPO/.testrun}"
TARGET_FV="${TARGET_FV:-2.1}"

# read-data must be set explicitly: for the Linux tarball the default resolves to
# /usr/share/factorio and the run dies with "There is no package core in ...".
bindir="$(cd "$(dirname "$FACTORIO")" && pwd)"
READ_DATA=""
for c in "$bindir/../data" "$bindir/../../data" "$bindir/../../../data"; do
  [ -f "$c/base/info.json" ] && { READ_DATA="$(cd "$c" && pwd)"; break; }
done
[ -n "$READ_DATA" ] || { echo "could not locate the Factorio data dir near $FACTORIO"; exit 1; }

RED=$'\033[31m'; GREEN=$'\033[32m'; RESET=$'\033[0m'
FAILED=0
fail() { echo "${RED}FAIL${RESET} $*"; FAILED=1; }
pass() { echo "${GREEN}PASS${RESET} $*"; }

rm -rf "$WORK"

# make_env <name> <mod-enabled true|false> -> $WORK/<name>/{mods,data,config.ini}
make_env() {
  local env=$WORK/$1 enabled=$2
  local dest="$env/mods/${MOD_NAME}_${MOD_VERSION}"
  mkdir -p "$dest" "$env/data/script-output" "$env/data/scenarios"
  cp "$MOD_ROOT"/*.lua "$dest/"
  [ -f "$MOD_ROOT/changelog.txt" ] && cp "$MOD_ROOT/changelog.txt" "$dest/"
  # Retarget info.json when testing the other major version (same Lua, and that
  # is the point of the test: the technique is version-generic).
  python3 -c "
import json, sys
i = json.load(open('$MOD_ROOT/info.json'))
i['factorio_version'] = '$TARGET_FV'
i['dependencies'] = ['quality >= ${TARGET_FV}.0']
json.dump(i, open('$dest/info.json', 'w'), indent=2)"
  # Pin the full mod set; never rely on the install's defaults. The recycler mod
  # only exists from 2.1 on.
  local recycler='{"name":"recycler","enabled":true},'
  [ "$TARGET_FV" = "2.0" ] && recycler=''
  cat > "$env/mods/mod-list.json" <<JSON
{"mods":[{"name":"base","enabled":true},{"name":"elevated-rails","enabled":true},
{"name":"quality","enabled":true},${recycler}
{"name":"space-age","enabled":true},{"name":"$MOD_NAME","enabled":$enabled}]}
JSON
  printf '[path]\nread-data=%s\nwrite-data=%s\n[general]\nlocale=en\n' \
    "$READ_DATA" "$env/data" > "$env/config.ini"
}

# run_factorio <env> <logfile> <args...>
run_factorio() {
  local env=$WORK/$1 log=$2; shift 2
  local rc=0
  "$FACTORIO" -c "$env/config.ini" --mod-directory "$env/mods" "$@" > "$log" 2>&1 || rc=$?
  # Exit code is the primary signal; the log grep covers cases where the engine
  # reports an error but still exits 0.
  if [ $rc -ne 0 ] || grep -qE '^ *[0-9.]+ Error ' "$log"; then
    tail -40 "$log" | sed 's/^/  | /'
    return 1
  fi
  return 0
}

stage_data() {
  echo "== data stage =="
  make_env baseline false
  make_env modded   true

  run_factorio baseline "$WORK/baseline.log" --dump-data || { fail "baseline (mod disabled) data stage"; return; }
  run_factorio modded   "$WORK/modded.log"   --dump-data || { fail "data stage load with the mod"; return; }
  pass "data stage loads on Factorio $TARGET_FV with the full expansion mod set + $MOD_NAME"

  # Assert against the baseline dump, never against a hard-coded level: a
  # self-referential assertion ("everything equals the max level present")
  # passes even on a mod that flattens everything to the *worst* quality.
  python3 - "$WORK/baseline/data/script-output/data-raw-dump.json" \
            "$WORK/modded/data/script-output/data-raw-dump.json" <<'PY' || FAILED=1
import json, sys
base_raw = json.load(open(sys.argv[1]))
mod_raw  = json.load(open(sys.argv[2]))
base = base_raw["quality"]
mod  = mod_raw["quality"]

best_name, best = max(base.items(), key=lambda kv: kv[1].get("level", 0))
top = best.get("level", 0)
print(f"  baseline top quality: {best_name} (level {top}), {len(base)} qualities")
assert top > 0, "baseline has no levelled quality -- is the quality mod enabled?"

bad = []
if set(mod) != set(base):
    bad.append(f"quality set changed: {sorted(set(mod) ^ set(base))}")
for name, q in mod.items():
    if q.get("level") != top:       bad.append(f"{name}.level={q.get('level')} (want {top})")
    if q.get("hidden") is not True: bad.append(f"{name}.hidden={q.get('hidden')} (want true)")
    if q.get("next") is not None:   bad.append(f"{name}.next={q.get('next')} (want nil)")
    for k in ("beacon_power_usage_multiplier", "mining_drill_resource_drain_multiplier",
              "science_pack_drain_multiplier"):
        if q.get(k) != best.get(k):
            bad.append(f"{name}.{k}={q.get(k)} (want {best.get(k)})")
# The quality mechanic itself must be gone, not just re-levelled.
q_modules = {n for n, m in base_raw.get("module", {}).items()
             if (m.get("effect") or {}).get("quality")}
assert q_modules, "baseline has no quality modules -- is the quality mod enabled?"
for n in sorted(q_modules):
    m = mod_raw["module"][n]
    eff = m.get("effect") or {}
    if "quality" in eff:
        bad.append(f"module {n} still has a quality effect")
    # A module left with nothing but penalties must be hidden AND inert, so
    # leftovers in an existing save are harmless rather than a trap.
    if m.get("hidden") is True and eff:
        bad.append(f"hidden module {n} still has effects {eff}")
    if m.get("hidden") is not True and not eff:
        bad.append(f"module {n} was emptied but left visible")

unlocks = [t for t, v in mod_raw.get("technology", {}).items()
           if any(e.get("type") == "unlock-quality" for e in (v.get("effects") or []))]
if unlocks:
    bad.append(f"technologies still unlock qualities: {unlocks}")

# --- Tech tree integrity: every remaining visible tech must stay reachable. ---
def vis_techs(d):
    return {n: t for n, t in d.get("technology", {}).items()
            if t.get("hidden") is not True and t.get("enabled") is not False}
mt = vis_techs(mod_raw)
dangling = {n: [p for p in (t.get("prerequisites") or []) if p not in mt]
            for n, t in mt.items()}
dangling = {n: ps for n, ps in dangling.items() if ps}
if dangling:
    bad.append(f"visible techs with dangling prerequisites: {dangling}")
R, changed = set(), True
while changed:
    changed = False
    for n, t in mt.items():
        if n not in R and all(p in R for p in (t.get("prerequisites") or [])):
            R.add(n); changed = True
unreachable = sorted(set(mt) - R)
if unreachable:
    bad.append(f"unreachable visible techs: {unreachable}")

# --- Craftability: items whose last visible recipe the mod hid must not be
# consumed by any visible recipe, tech unit, or research trigger. ---
def producible(d):
    out = set()
    for r in d.get("recipe", {}).values():
        if r.get("hidden") is True: continue
        for res in (r.get("results") or []):
            if res.get("name"): out.add(res["name"])
    return out
lost = producible(base_raw) - producible(mod_raw)
extra_lost = lost - q_modules
if extra_lost:
    bad.append(f"non-quality-module items lost their last visible recipe: {sorted(extra_lost)}")
for n, r in mod_raw.get("recipe", {}).items():
    if r.get("hidden") is True: continue
    for ing in (r.get("ingredients") or []):
        if ing.get("name") in lost:
            bad.append(f"visible recipe {n} needs uncraftable {ing['name']}")
for n, t in mt.items():
    for ing in ((t.get("unit") or {}).get("ingredients") or []):
        nm = ing[0] if isinstance(ing, list) else ing.get("name")
        if nm in lost:
            bad.append(f"tech {n} unit needs uncraftable {nm}")
    trig = json.dumps(t.get("research_trigger") or {})
    for it in lost:
        if f'"{it}"' in trig:
            bad.append(f"tech {n} research trigger needs uncraftable {it}")

for b in bad: print("  " + b)
print(f"  checked {len(mod)} quality prototypes against baseline '{best_name}', "
      f"{len(q_modules)} quality modules, {len(mt)} visible techs "
      f"(all reachable: {not unreachable}), {len(lost)} items made uncraftable")
sys.exit(1 if bad else 0)
PY
  [ $FAILED -eq 0 ] && pass "every quality prototype matches the baseline top quality and is hidden"
}

stage_runtime() {
  echo "== runtime stage =="
  make_env runtime true
  local sc=$WORK/runtime/data/scenarios/al-check
  mkdir -p "$sc"
  cat > "$sc/control.lua" <<'LUA'
script.on_init(function()
  local fails = {}
  local function check(name, ok, got)
    log("CHECK " .. name .. " = " .. tostring(got) .. (ok and "  OK" or "  FAIL"))
    if not ok then fails[#fails + 1] = name .. " (got " .. tostring(got) .. ")" end
  end

  -- vanilla legendary values; these are the point of the mod
  check("quality.normal.level == 5", prototypes.quality.normal.level == 5, prototypes.quality.normal.level)
  check("quality.normal.hidden", prototypes.quality.normal.hidden == true, prototypes.quality.normal.hidden)

  local s = game.surfaces[1]
  local am = s.create_entity{name = "assembling-machine-3", position = {0, 0}, force = "player"}
  check("assembler crafting_speed == 3.125", math.abs(am.crafting_speed - 3.125) < 1e-6, am.crafting_speed)
  check("assembler quality name is normal", am.quality.name == "normal", am.quality.name)

  local acc = s.create_entity{name = "accumulator", position = {6, 0}, force = "player"}
  check("accumulator buffer == 30 MJ", math.abs(acc.electric_buffer_size - 30e6) < 1, acc.electric_buffer_size)

  if #fails > 0 then error("AL-CHECK FAILED: " .. table.concat(fails, "; ")) end
  log("AL-CHECK ALL PASSED")
end)
LUA
  # --scenario2map runs the data stage AND the scenario's on_init, then exits by
  # itself: 0 on success, 1 if on_init raises. No server, RCON or timeout needed.
  if run_factorio runtime "$WORK/runtime.log" --scenario2map al-check; then
    grep -E 'CHECK |AL-CHECK' "$WORK/runtime.log" | sed 's/^.*control\.lua:[0-9]*: /  /'
    pass "runtime assertions"
  else
    grep -E 'CHECK |AL-CHECK' "$WORK/runtime.log" | sed 's/^.*control\.lua:[0-9]*: /  /'
    fail "runtime assertions"
  fi
}

case "${1:-all}" in
  data)    stage_data ;;
  runtime) stage_runtime ;;
  all)     stage_data; stage_runtime ;;
  *)       echo "usage: $0 [data|runtime|all]"; exit 2 ;;
esac
exit $FAILED
