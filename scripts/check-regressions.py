"""Prove that the gameplay validator rejects known failure modes.

Uses the current run's real engine observations, changing one observation at a
time. This tests the checker itself; the audit also records a separate run of
the actual defective 1.0.2 mod against the movement scenario.
"""

import copy
import json
import subprocess
import sys
import tempfile
from pathlib import Path

work = Path(sys.argv[1])
scripts = Path(__file__).resolve().parent
baseline = work / "exclusions-vanilla-baseline/data/script-output/exclusions.json"
actual = json.loads(
    (work / "exclusions-vanilla-modded/data/script-output/exclusions.json").read_text()
)


def damage_asteroid(report):
    report["health"]["small-metallic-asteroid"]["normal"] *= 2.5


def damage_enemy(report):
    report["health"]["behemoth-biter"]["normal"] *= 2.5


def damage_acid(report):
    report["combat"]["small-spitter"]["samples"][0]["damage"] *= 2.5


def stop_movement(report):
    report["movement"]["acid-sticker-small"][0]["speed"] = 0


def lose_observation(report):
    del report["combat"]["big-demolisher"]


def truncate_acid(report):
    report["combat"]["small-spitter"]["samples"] = report["combat"]["small-spitter"][
        "samples"
    ][:1]


def extend_ash(report):
    report["stickers"]["demolisher-ash-sticker"]["normal"] *= 2.5


def incomplete_run(report):
    report["complete"] = False


with tempfile.TemporaryDirectory(prefix="checker-", dir=work) as directory:
    candidate = Path(directory) / "mutated.json"
    for mutation in (
        damage_asteroid,
        damage_enemy,
        damage_acid,
        stop_movement,
        lose_observation,
        truncate_acid,
        extend_ash,
        incomplete_run,
    ):
        report = copy.deepcopy(actual)
        mutation(report)
        candidate.write_text(json.dumps(report))
        result = subprocess.run(
            [
                sys.executable,
                str(scripts / "check-exclusions.py"),
                str(baseline),
                str(candidate),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0 or "AssertionError" not in result.stderr:
            raise AssertionError(
                f"{mutation.__name__} was not rejected correctly:\n{result.stdout}\n{result.stderr}"
            )
        print(f"  rejected regression: {mutation.__name__}")
