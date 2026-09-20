#!/usr/bin/env bash
# CI test runner for the no-quality-no-problem mod.
#
#   ci-test.sh data       data-stage load + prototype assertions (vs. a baseline dump)
#   ci-test.sh runtime    control-stage assertions and simulated enemy attacks
#   ci-test.sh all        both (default)
#
# Every Factorio invocation uses an isolated write-data directory and an explicit
# --mod-directory, so a run never touches real saves/mods/script-output.
#
# Env:
#   FACTORIO_BIN  path to the factorio executable (required)
#   MOD_ROOT      mod source dir (default: <repo>/no-quality-no-problem)
#   WORK          scratch dir (default: <repo>/.testrun)
#   TARGET_FV     Factorio major version under test: 2.1 (default).
#   TEST_PROFILE quality (no Space Age) or space-age (default).
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MOD_ROOT="${MOD_ROOT:-$REPO/no-quality-no-problem}"
MOD_NAME="$(python3 -c "import json;print(json.load(open('$MOD_ROOT/info.json'))['name'])")"
MOD_VERSION="$(python3 -c "import json;print(json.load(open('$MOD_ROOT/info.json'))['version'])")"
FACTORIO="${FACTORIO_BIN:?set FACTORIO_BIN to the factorio executable}"
WORK="${WORK:-$REPO/.testrun}"
TARGET_FV="${TARGET_FV:-2.1}"
TEST_PROFILE="${TEST_PROFILE:-space-age}"
case "$TEST_PROFILE" in quality|space-age) ;; *) echo "unknown TEST_PROFILE: $TEST_PROFILE" >&2; exit 2 ;; esac
WORK="$WORK/$TEST_PROFILE"

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

mkdir -p "$WORK"

# make_env <name> <mod-enabled true|false> -> $WORK/<name>/{mods,data,config.ini}
make_env() {
  local env=$WORK/$1 enabled=$2
  local dest="$env/mods/${MOD_NAME}_${MOD_VERSION}"
  rm -rf "$env"
  mkdir -p "$dest" "$env/data/script-output" "$env/data/scenarios"
  # Test the actual manifest too: rewriting dependencies here could make an
  # incompatible published package pass locally.
  cp -a "$MOD_ROOT/." "$dest/"
  local expansion=false
  [ "$TEST_PROFILE" = space-age ] && expansion=true
  cat > "$env/mods/mod-list.json" <<JSON
{"mods":[{"name":"base","enabled":true},{"name":"elevated-rails","enabled":$expansion},
{"name":"quality","enabled":true},{"name":"recycler","enabled":true},
{"name":"space-age","enabled":$expansion},{"name":"$MOD_NAME","enabled":$enabled}]}
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
  pass "data stage loads on Factorio $TARGET_FV ($TEST_PROFILE) + $MOD_NAME"

  # Assert against the baseline dump, never against a hard-coded level: a
  # self-referential assertion ("everything equals the max level present")
  # passes even on a mod that flattens everything to the *worst* quality.
  python3 "$REPO/scripts/check-data.py" \
    "$WORK/baseline/data/script-output/data-raw-dump.json" \
    "$WORK/modded/data/script-output/data-raw-dump.json" || FAILED=1
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
    grep -E 'CHECK |AL-CHECK' "$WORK/runtime.log" | sed 's/^.*control\.lua:[0-9]*: /  /' || true
    fail "runtime assertions"
  fi

  stage_player
  if [ "$TEST_PROFILE" = space-age ]; then stage_exclusions; fi
}

stage_player() {
  echo "== player gameplay ($TEST_PROFILE) =="
  local mode env sc fixture enabled
  for mode in baseline modded; do
    env="player-$mode"
    enabled=false
    [ "$mode" = modded ] && enabled=true
    make_env "$env" "$enabled"
    fixture="$WORK/$env/mods/player-fixture"
    mkdir -p "$fixture"
    cat > "$fixture/info.json" <<JSON
{"name":"player-fixture","version":"1.0.0","title":"Player test fixture",
 "author":"Tests","factorio_version":"$TARGET_FV","dependencies":["quality", "? no-quality-no-problem"]}
JSON
    cp "$REPO/scripts/player-fixture.lua" "$fixture/data-final-fixes.lua"
    python3 - "$WORK/$env/mods/mod-list.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f:
    d = json.load(f)
d['mods'].append({'name': 'player-fixture', 'enabled': True})
with open(p, 'w') as f:
    json.dump(d, f)
PY
    sc="$WORK/$env/data/scenarios/player-check"
    mkdir -p "$sc"
    cp "$REPO/scripts/player-control.lua" "$sc/control.lua"
    run_factorio "$env" "$WORK/$env-init.log" --scenario2map player-check || { fail "$env init"; return; }
    run_factorio "$env" "$WORK/$env-gameplay.log" --benchmark "$WORK/$env/data/saves/player-check.zip" \
      --benchmark-ticks 1801 --benchmark-runs 1 || { fail "$env gameplay"; return; }
  done
  if python3 "$REPO/scripts/check-player.py" \
    "$WORK/player-baseline/data/script-output/player.json" \
    "$WORK/player-modded/data/script-output/player.json"; then
    pass "player actions match the unmodified game's best quality"
  else
    fail "player gameplay"
  fi
}

stage_exclusions() {
  echo "== world exclusions =="
  local variant mode env sc fixture
  for variant in vanilla mythic; do
    for mode in baseline modded; do
      env="exclusions-$variant-$mode"
      local enabled=false
      [ "$mode" = modded ] && enabled=true
      make_env "$env" "$enabled"
      sc="$WORK/$env/data/scenarios/exclusions"
      mkdir -p "$sc"
      cp "$REPO/scripts/exclusions-control.lua" "$sc/control.lua"
      cp "$REPO/scripts/exclusions-movement.lua" "$sc/movement.lua"
      if [ "$variant" = mythic ]; then
        fixture="$WORK/$env/mods/exclusions-fixture"
        mkdir -p "$fixture"
        cat > "$fixture/info.json" <<JSON
{"name":"exclusions-fixture","version":"1.0.0","title":"Exclusion test fixture",
 "author":"Tests","factorio_version":"$TARGET_FV","dependencies":["quality", "space-age"]}
JSON
        cp "$REPO/scripts/exclusions-fixture.lua" "$fixture/data.lua"
        python3 - "$WORK/$env/mods/mod-list.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f:
    d = json.load(f)
d['mods'].append({'name': 'exclusions-fixture', 'enabled': True})
with open(p, 'w') as f:
    json.dump(d, f)
PY
      fi
      run_factorio "$env" "$WORK/$env-init.log" --scenario2map exclusions || { fail "$env init"; return; }
      run_factorio "$env" "$WORK/$env-combat.log" --benchmark "$WORK/$env/data/saves/exclusions.zip" \
        --benchmark-ticks 2401 --benchmark-runs 1 || { fail "$env combat"; return; }
    done
    if python3 "$REPO/scripts/check-exclusions.py" \
      "$WORK/exclusions-$variant-baseline/data/script-output/exclusions.json" \
      "$WORK/exclusions-$variant-modded/data/script-output/exclusions.json"; then
      pass "$variant world stats match the unmodified game; player bonuses remain"
    else
      fail "$variant world exclusions"
    fi
  done
  if [ "$FAILED" -eq 0 ]; then
    python3 "$REPO/scripts/check-regressions.py" "$WORK" || fail "regression checker self-test"
  fi
}

case "${1:-all}" in
  data)    stage_data ;;
  runtime) stage_runtime ;;
  player)  stage_player ;;
  exclusions) stage_exclusions ;;
  all)     stage_data; stage_runtime ;;
  *)       echo "usage: $0 [data|runtime|player|exclusions|all]"; exit 2 ;;
esac
exit $FAILED
