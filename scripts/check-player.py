"""Compare real player actions with the unmodified game's best quality."""

import json
import math
import sys


def compare(expected, actual, path="player"):
    if isinstance(expected, dict):
        assert isinstance(actual, dict) and expected.keys() == actual.keys(), (
            f"{path}: different observations"
        )
        for key in expected:
            compare(expected[key], actual[key], f"{path}/{key}")
    elif isinstance(expected, list):
        assert isinstance(actual, list) and len(expected) == len(actual), (
            f"{path}: incomplete trace"
        )
        for index, (before, after) in enumerate(zip(expected, actual)):
            compare(before, after, f"{path}/{index}")
    elif type(expected) in (int, float):
        assert type(actual) in (int, float) and math.isfinite(actual), (
            f"{path}: not a finite number"
        )
        assert math.isclose(expected, actual, rel_tol=1e-6, abs_tol=1e-5), (
            f"{path}: got {actual}, expected {expected}"
        )
    else:
        assert type(expected) is type(actual) and expected == actual, (
            f"{path}: got {actual}, expected {expected}"
        )


def check(base, mod):
    assert base["complete"] is True and mod["complete"] is True, (
        "Player scenario did not finish"
    )
    assert base["quality"] != "normal" and mod["quality"] == "normal", (
        "Wrong quality reference"
    )
    for name in (
        "small-electric-pole",
        "medium-electric-pole",
        "big-electric-pole",
        "substation",
    ):
        lamps = base["poles"][name]["lamps"]
        assert (
            len(lamps) == 24
            and any(x["powered"] for x in lamps)
            and not all(x["powered"] for x in lamps)
        ), name
    for name in ("burner-mining-drill", "electric-mining-drill", "pumpjack"):
        assert base["mining"][name]["remaining"] < 100000, f"{name} never mined"
    assert base["research"]["packs"] < 10, "Lab never consumed science"
    assert base["research"]["progress"] > 0 or base["research"]["researched"], (
        "Lab never researched"
    )
    for name, result in base["combat"].items():
        if name == "slowdown-capsule":
            assert result["stickers"], "Slowdown capsule never affected target"
        else:
            assert result["hits"] > 0 and result["damage"], f"No damage from {name}"
        if name in {"defender-capsule", "distractor-capsule", "destroyer-capsule"}:
            assert result["robots"], f"No robots spawned by {name}"
    compare(
        {k: v for k, v in base.items() if k != "quality"},
        {k: v for k, v in mod.items() if k != "quality"},
    )
    print(
        f"  checked {len(base['poles'])} powered pole grids, {len(base['inserters'])} inserters, "
        f"{len(base['mining'])} working drills, science consumption and {len(base['combat'])} capsule attacks"
    )


if __name__ == "__main__":
    with open(sys.argv[1]) as stream:
        baseline = json.load(stream)
    with open(sys.argv[2]) as stream:
        actual = json.load(stream)
    check(baseline, actual)
