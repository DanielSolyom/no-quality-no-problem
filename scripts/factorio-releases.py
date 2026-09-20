"""Plan cheap release checks and record the outcome of real engine tests.

Network I/O is done by curl in the workflow. A failed API request or malformed
response must fail the detector, never masquerade as 'no new release'.
"""

import argparse
import hashlib
import json
import re
import subprocess
from datetime import date
from pathlib import Path


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError(f"Invalid Factorio version: {value!r}")
    return tuple(map(int, value.split(".")))


def fingerprint():
    """Ignore release bookkeeping, but retry failures after code/test changes."""
    paths = (
        subprocess.check_output(
            [
                "git",
                "ls-files",
                "-z",
                "--",
                "no-quality-no-problem",
                "scripts",
                "tests",
                ".github/workflows",
                "build.sh",
                "publish.sh",
                ".luacheckrc",
            ]
        )
        .decode()
        .split("\0")
    )
    digest = hashlib.sha256()
    for name in sorted(p for p in paths if p and not p.endswith("changelog.txt")):
        content = Path(name).read_bytes()
        if name == "no-quality-no-problem/info.json":
            info = json.loads(content)
            info.pop("version")
            content = json.dumps(info, sort_keys=True).encode()
        digest.update(name.encode() + b"\0" + content + b"\0")
    return digest.hexdigest()


def plan(latest, history, state, line, force=None, source=None):
    minimum = version(state["minimum_version"])
    if force:
        version(force)
        if not force.startswith(line + "."):
            raise ValueError(f"{force} is outside the supported {line} release line")
        return [force]
    experimental = latest["experimental"]["headless"]
    version(experimental)
    available = {experimental}
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

    def needs_check(candidate):
        previous = state["checked"].get(candidate)
        if previous is None:
            return True
        if previous.get("release_status") == "published":
            return False
        if previous["status"] == "failed":
            return source is not None and previous.get("source_fingerprint") != source
        return True  # Tests passed, but publication has not finished.

    return sorted(
        (
            candidate
            for candidate in available
            if candidate.startswith(line + ".")
            and version(candidate) >= minimum
            and version(candidate) <= version(experimental)
            and needs_check(candidate)
        ),
        key=lambda candidate: (
            state["checked"].get(candidate, {}).get("release_status") != "pending",
            version(candidate),
        ),
    )


def record(state, versions, reports, run_url, published=False, validation_passed=True):
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
        if len({r["source_fingerprint"] for r in results}) != 1:
            raise ValueError(f"Different source files tested for Factorio {engine}")
        if any(r["status"] not in {"success", "failure", "cancelled"} for r in results):
            raise ValueError(f"Invalid test status for Factorio {engine}")
        previous = state["checked"].get(engine, {})
        state["checked"][engine] = {
            "status": "passed"
            if validation_passed and all(r["status"] == "success" for r in results)
            else "failed",
            "source_commit": results[0]["source_commit"],
            "mod_version": results[0]["mod_version"],
            "run_url": run_url,
            "source_fingerprint": results[0]["source_fingerprint"],
        }
        if previous.get("mod_version") == results[0]["mod_version"]:
            for field in ("release_status", "release_ref"):
                if field in previous:
                    state["checked"][engine][field] = previous[field]
        if published:
            if state["checked"][engine]["status"] != "passed":
                raise ValueError("Cannot publish a failed validation")
            state["checked"][engine]["release_status"] = "published"
            state["checked"][engine]["release_ref"] = "v" + results[0]["mod_version"]
    return state


def prepare(mod, engine, target, released_on):
    """Stage the version bump before testing; identical input yields identical files."""
    version(engine)
    target_version = version(target)
    date.fromisoformat(released_on)
    path = mod / "info.json"
    info = json.loads(path.read_text())
    if not engine.startswith(info["factorio_version"] + "."):
        raise ValueError(
            "Cannot silently retarget the mod to a new Factorio release line"
        )
    if info["version"] == target:
        return  # Resuming a frozen release tag after partial publication.
    major, minor, patch = version(info["version"])
    if target_version != (major, minor, patch + 1):
        raise ValueError("Automatic releases must increment exactly one mod patch")
    info["version"] = target
    path.write_text(json.dumps(info, indent=2) + "\n")
    changelog = mod / "changelog.txt"
    changelog.write_text(
        "-" * 99 + f"\nVersion: {target}\nDate: {released_on}\n  Changes:\n"
        f"    - Compatibility release for Factorio {engine} experimental.\n"
        "    - Validated against an unmodified game with and without Space Age, including enemy, asteroid, acid and player gameplay regressions.\n"
        + changelog.read_text()
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command", choices=("plan", "record", "ci", "fingerprint", "prepare")
    )
    parser.add_argument("--state", default=".github/factorio-releases.json")
    parser.add_argument("--latest")
    parser.add_argument("--history")
    parser.add_argument("--force")
    parser.add_argument("--reports")
    parser.add_argument("--versions")
    parser.add_argument("--run-url")
    parser.add_argument("--published", action="store_true")
    parser.add_argument("--validation-status", default="success")
    parser.add_argument("--engine")
    parser.add_argument("--mod-version")
    parser.add_argument("--date")
    args = parser.parse_args()
    path = Path(args.state)
    state = json.loads(path.read_text())
    if args.command == "fingerprint":
        print(fingerprint())
    elif args.command == "prepare":
        prepare(Path("no-quality-no-problem"), args.engine, args.mod_version, args.date)
    elif args.command == "ci":
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
            fingerprint(),
        )
        print(json.dumps(versions))
    else:
        reports = [
            json.loads(p.read_text()) for p in Path(args.reports).rglob("*.json")
        ]
        record(
            state,
            json.loads(args.versions),
            reports,
            args.run_url,
            args.published,
            args.validation_status == "success",
        )
        path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
