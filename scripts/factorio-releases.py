"""Plan cheap release checks and record the outcome of real engine tests.

Network I/O is done by curl in the workflow. A failed API request or malformed
response must fail the detector, never masquerade as 'no new release'.
"""

import argparse
import json
import re
from pathlib import Path


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError(f"Invalid Factorio version: {value!r}")
    return tuple(map(int, value.split(".")))


def plan(latest, history, state, line, force=None):
    minimum = version(state["minimum_version"])
    if force:
        version(force)
        if not force.startswith(line + "."):
            raise ValueError(f"{force} is outside the supported {line} release line")
        return [force]
    available = {latest[channel]["headless"] for channel in ("stable", "experimental")}
    # The update index catches releases missed during delayed hourly runs,
    # including multiple releases between checks. No game binary is downloaded.
    entries = history["core-linux_headless64"]
    if not isinstance(entries, list) or not entries:
        raise ValueError("Headless release history is empty or malformed")
    for entry in entries:
        for field in ("from", "to", "stable", "experimental"):
            if field in entry:
                available.add(entry[field])
    for candidate in available:
        version(candidate)
    return sorted(
        (
            candidate
            for candidate in available
            if candidate.startswith(line + ".")
            and version(candidate) >= minimum
            and candidate not in state["checked"]
        ),
        key=version,
    )


def record(state, versions, reports, run_url):
    for engine in versions:
        version(engine)
        results = [report for report in reports if report["factorio_version"] == engine]
        if len(results) != 2 or {r["profile"] for r in results} != {
            "quality",
            "space-age",
        }:
            raise ValueError(f"Incomplete test evidence for Factorio {engine}")
        if len({r["source_commit"] for r in results}) != 1:
            raise ValueError(f"Different source commits tested for Factorio {engine}")
        if len({r["mod_version"] for r in results}) != 1:
            raise ValueError(f"Different mod versions tested for Factorio {engine}")
        if any(r["status"] not in {"success", "failure", "cancelled"} for r in results):
            raise ValueError(f"Invalid test status for Factorio {engine}")
        state["checked"][engine] = {
            "status": "passed"
            if all(r["status"] == "success" for r in results)
            else "failed",
            "source_commit": results[0]["source_commit"],
            "mod_version": results[0]["mod_version"],
            "run_url": run_url,
        }
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "record", "ci"))
    parser.add_argument("--state", default=".github/factorio-releases.json")
    parser.add_argument("--latest")
    parser.add_argument("--history")
    parser.add_argument("--force")
    parser.add_argument("--reports")
    parser.add_argument("--versions")
    parser.add_argument("--run-url")
    args = parser.parse_args()
    path = Path(args.state)
    state = json.loads(path.read_text())
    if args.command == "ci":
        # Test fixes against the newest observed engine even when its first
        # compatibility run failed, while retaining the oldest supported pin.
        newest = max([state["minimum_version"], *state["checked"]], key=version)
        print(json.dumps(sorted({state["baseline_version"], newest}, key=version)))
    elif args.command == "plan":
        line = json.loads(Path("no-quality-no-problem/info.json").read_text())[
            "factorio_version"
        ]
        versions = plan(
            json.loads(Path(args.latest).read_text()),
            json.loads(Path(args.history).read_text()),
            state,
            line,
            args.force,
        )
        print(json.dumps(versions))
    else:
        reports = [
            json.loads(p.read_text()) for p in Path(args.reports).rglob("*.json")
        ]
        record(state, json.loads(args.versions), reports, args.run_url)
        path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
