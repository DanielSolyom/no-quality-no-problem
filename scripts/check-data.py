"""Validate flattened quality and world invariants against an unmodified dump."""

import argparse
import json
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("baseline")
parser.add_argument("modded")
parser.add_argument("--kept-item", action="append", default=[])
args = parser.parse_args()

with open(args.baseline) as stream:
    base_raw = json.load(stream)
with open(args.modded) as stream:
    mod_raw = json.load(stream)
base = base_raw["quality"]
mod = mod_raw["quality"]

best_name, best = max(base.items(), key=lambda kv: kv[1].get("level", 0))
top = best.get("level", 0)
print(f"  baseline top quality: {best_name} (level {top}), {len(base)} qualities")
assert top > 0, "baseline has no levelled quality -- is the quality mod enabled?"

bad = []
stat_fields = {
    k
    for q in base.values()
    for k in q
    if k == "level" or k.endswith(("_multiplier", "_bonus"))
}
if set(mod) != set(base):
    bad.append(f"quality set changed: {sorted(set(mod) ^ set(base))}")
for name, q in mod.items():
    if q.get("level") != top:
        bad.append(f"{name}.level={q.get('level')} (want {top})")
    if q.get("hidden") is not True:
        bad.append(f"{name}.hidden={q.get('hidden')} (want true)")
    if q.get("next") is not None:
        bad.append(f"{name}.next={q.get('next')} (want nil)")
    if q.get("hidden_in_factoriopedia") is not True:
        bad.append(f"{name} still visible in Factoriopedia")
    if q.get("draw_sprite_by_default") is not False:
        bad.append(f"{name} still draws a quality badge")
    for k in (
        "next_probability",
        "chain_probability",
        "previous_probability",
        "previous_chain_probability",
    ):
        if q.get(k, 0) != 0:
            bad.append(f"{name}.{k} still upgrades/downgrades quality")
    for k in sorted(stat_fields):
        if q.get(k) != best.get(k):
            bad.append(f"{name}.{k}={q.get(k)} (want {best.get(k)})")
# The quality mechanic itself must be gone, not just re-levelled.
q_modules = {
    n
    for n, m in base_raw.get("module", {}).items()
    if (m.get("effect") or {}).get("quality")
}
assert q_modules, "baseline has no quality modules -- is the quality mod enabled?"
for n in sorted(q_modules):
    module = mod_raw.get("module", {}).get(n)
    item = mod_raw.get("item", {}).get(n)
    if module:
        if "quality" in (module.get("effect") or {}):
            bad.append(f"module {n} still has a quality effect")
        if not module.get("effect"):
            bad.append(f"inert module {n} was not converted to an ordinary item")
    elif item:
        if item.get("effect") or item.get("type") != "item":
            bad.append(f"{n} is not an inert ordinary item")
        for field in ("hidden", "hidden_in_factoriopedia"):
            if bool(item.get(field)) != (n not in args.kept_item):
                bad.append(f"{n}.{field} does not match expected recipe demand")
    else:
        bad.append(f"quality-bearing item {n} disappeared")

for name in ("quality-module", "quality-module-2", "quality-module-3"):
    recipe = mod_raw["recipe"][name]
    tech = mod_raw["technology"][name]
    if name in args.kept_item:
        if recipe != base_raw["recipe"][name]:
            bad.append(f"{name} recipe changed despite being kept for crafting")
        original = base_raw["technology"][name]
        expected = {
            **original,
            "effects": [e for e in original["effects"] if e["type"] != "unlock-quality"],
        }
        if tech != expected:
            bad.append(f"{name} research changed beyond removing quality unlocks")
    elif not (recipe.get("hidden") and recipe.get("enabled") is False
              and tech.get("hidden") and tech.get("enabled") is False):
        bad.append(f"unused {name} recipe/research is still available")

# Speed modules are useful even though their original quality effect is
# negative. Stripping that penalty must not hide them or reduce their speed.
for name in ("speed-module", "speed-module-2", "speed-module-3"):
    original = base_raw["module"][name]["effect"]
    actual = mod_raw["module"][name]
    expected = {k: v for k, v in original.items() if k != "quality"}
    if actual.get("effect") != expected or actual.get("hidden") is True:
        bad.append(f"{name} lost useful effects or became hidden")

unlocks = [
    t
    for t, v in mod_raw.get("technology", {}).items()
    if any(e.get("type") == "unlock-quality" for e in (v.get("effects") or []))
]
if unlocks:
    bad.append(f"technologies still unlock qualities: {unlocks}")

# Health compensation must not quietly weaken armour, alter asteroid drops,
# regeneration, collisions or movement. These fields do not gain quality.
# The expected world scope lives in the tests, not the mod's exclusion table.
world_types = {
    "asteroid",
    "unit",
    "unit-spawner",
    "turret",
    "spider-unit",
    "segmented-unit",
    "segment",
    "tree",
    "plant",
    "simple-entity",
}
world_fields = (
    "resistances",
    "loot",
    "minable",
    "healing_per_tick",
    "damage_per_hp",
    "movement_speed",
    "distance_per_frame",
    "collision_box",
    "collision_mask",
    "autoplace",
    "result_units",
    "spawning_cooldown",
    "max_speed",
    "mass",
)
world_count = 0
for kind in sorted(world_types):
    for name, original in base_raw.get(kind, {}).items():
        actual = mod_raw.get(kind, {}).get(name)
        if actual is None:
            bad.append(f"missing world prototype: {kind}/{name}")
            continue
        for field in world_fields:
            if original.get(field) != actual.get(field):
                bad.append(f"{kind}/{name}.{field} changed")
        world_count += 1


# --- Tech tree integrity: every remaining visible tech must stay reachable. ---
def vis_techs(d):
    return {
        n: t
        for n, t in d.get("technology", {}).items()
        if t.get("hidden") is not True and t.get("enabled") is not False
    }


mt = vis_techs(mod_raw)
dangling = {
    n: [p for p in (t.get("prerequisites") or []) if p not in mt] for n, t in mt.items()
}
dangling = {n: ps for n, ps in dangling.items() if ps}
if dangling:
    bad.append(f"visible techs with dangling prerequisites: {dangling}")
R, changed = set(), True
while changed:
    changed = False
    for n, t in mt.items():
        if n not in R and all(p in R for p in (t.get("prerequisites") or [])):
            R.add(n)
            changed = True
unreachable = sorted(set(mt) - R)
if unreachable:
    bad.append(f"unreachable visible techs: {unreachable}")


# --- Craftability: items whose last visible recipe the mod hid must not be
# consumed by any visible recipe, tech unit, or research trigger. ---
def producible(d):
    out = set()
    for r in d.get("recipe", {}).values():
        if r.get("hidden") is True:
            continue
        for res in r.get("results") or []:
            if res.get("name"):
                out.add(res["name"])
    return out


lost = producible(base_raw) - producible(mod_raw)
extra_lost = lost - q_modules
if extra_lost:
    bad.append(
        f"non-quality-module items lost their last visible recipe: {sorted(extra_lost)}"
    )
for n, r in mod_raw.get("recipe", {}).items():
    if r.get("hidden") is True or n.endswith("-recycling"):
        continue
    if any("recycling" in c for c in r.get("categories", [r.get("category", "crafting")])):
        continue
    for ing in r.get("ingredients") or []:
        if ing.get("name") in lost:
            bad.append(f"visible recipe {n} needs uncraftable {ing['name']}")
for n, t in mt.items():
    for ing in (t.get("unit") or {}).get("ingredients") or []:
        nm = ing[0] if isinstance(ing, list) else ing.get("name")
        if nm in lost:
            bad.append(f"tech {n} unit needs uncraftable {nm}")
    trig = json.dumps(t.get("research_trigger") or {})
    for it in lost:
        if f'"{it}"' in trig:
            bad.append(f"tech {n} research trigger needs uncraftable {it}")

for b in bad:
    print("  " + b)
print(
    f"  checked {len(mod)} quality prototypes against baseline '{best_name}', "
    f"{len(stat_fields)} quality stat fields, {world_count} world invariants, "
    f"{len(q_modules)} quality modules, {len(mt)} visible techs "
    f"(all reachable: {not unreachable}), {len(lost)} items made uncraftable"
)
sys.exit(1 if bad else 0)
