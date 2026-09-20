"""Check gameplay against a separate run with the mod disabled."""
import json
import math
import sys

with open(sys.argv[1]) as stream:
    base = json.load(stream)
with open(sys.argv[2]) as stream:
    mod = json.load(stream)


def equal(got, expected, label):
    assert math.isclose(got, expected, rel_tol=1e-6, abs_tol=1e-5), (
        f"{label}: got {got}, expected {expected}"
    )


# This expected scope is independent of the mod's exclusion list.
world_types = {
    "asteroid", "unit", "unit-spawner", "turret", "spider-unit",
    "segmented-unit", "segment", "market", "simple-entity-with-owner",
    "simple-entity-with-force", "tree", "plant", "simple-entity",
}
checked = asteroids = 0
for name, values in base["health"].items():
    excluded = (
        values["type"] in world_types
        or name.startswith("crash-site-")
        or name == "fulgoran-ruin-attractor"
        or name.endswith("pentapod-leg")
    )
    if excluded:
        equal(mod["health"][name]["normal"], values["normal"], f"{name} health")
        checked += 1
    if values["type"] == "asteroid":
        equal(mod["health"][name]["instance"], values["instance"], f"{name} instance")
        asteroids += 1
assert asteroids >= 16, "Expected all four materials and four asteroid sizes"

# Player machines, logistics, defences, characters, and combat robots still
# receive the baseline's best quality, including a mod-added tier when present.
for name in (
    "assembling-machine-3", "accumulator", "splitter", "gun-turret", "character",
    "spidertron", "spidertron-leg-1", "defender", "captive-biter-spawner",
):
    equal(mod["health"][name]["normal"], base["health"][name]["best"], f"{name} bonus")
    assert mod["health"][name]["normal"] > base["health"][name]["normal"]

for name, values in base["inventories"].items():
    if name.startswith("crash-site-"):
        equal(mod["inventories"][name]["normal"], values["normal"], f"{name} inventory")
equal(mod["inventories"]["steel-chest"]["normal"], base["inventories"]["steel-chest"]["best"], "steel chest bonus")
for key, value in base["attractors"]["fulgoran-ruin-attractor"].items():
    equal(mod["attractors"]["fulgoran-ruin-attractor"][key], value, f"natural lightning attractor {key}")

for name, values in base["stickers"].items():
    enemy_effect = (
        name.startswith("acid-sticker-") or name.endswith("acid-sticker-stomper")
        or name in {"demolisher-ash-sticker", "strafer-sticker"}
    )
    expected = values["normal"] if enemy_effect else values["best"]
    equal(mod["stickers"][name]["normal"], expected, f"{name} duration")

for name, before in base["combat"].items():
    after = mod["combat"][name]
    if name == "worm-range-28":
        assert not before["samples"] and not after["samples"], "Worm range was increased"
        continue
    assert before["samples"] and after["samples"], f"No attacks observed for {name}"
    # Compare the first hits, including the first lingering acid damage pulses.
    # Attack scheduling is not assumed to be identical across engine versions.
    count = min(8, len(before["samples"]), len(after["samples"]))
    for index in range(count):
        original, actual = before["samples"][index], after["samples"][index]
        assert actual["cause"] == original["cause"], f"{name}: different attack source"
        assert actual["type"] == original["type"], f"{name}: different damage type"
        equal(actual["damage"], original["damage"], f"{name} hit {index + 1}")

assert len(base["combat"]["small-spitter"]["samples"]) >= 8, "Acid puddle damage was not exercised"
for name, amount in base["healing"].items():
    assert amount > 0, f"No healing observed for {name}"
    equal(mod["healing"][name], amount, f"{name} regeneration")
assert len(base["healing"]) == 3
print(f"  checked {checked} world entities ({asteroids} asteroids), "
      f"{len(base['combat'])} combat/range cases, regeneration, and player bonuses")
