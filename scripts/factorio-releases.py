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


# Keep existing experimental checkpoints readable; stable promotions have their
# own ledger so the same engine can receive a second compatibility release.
CHECK_KEYS = {"experimental": "checked", "stable": "stable_checked"}


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


def plan(latest, history, state, line, force=None, source=None, channel="experimental"):
    minimum = version(state["minimum_version"])
    if force:
        version(force)
        if not force.startswith(line + "."):
            raise ValueError(f"{force} is outside the supported {line} release line")
        return [{"version": force, "channel": channel}]
    # Stable can advance independently; experimental may be absent when there
    # is no experimental build. Either index can expose a new version first.
    stable = {latest["stable"]["headless"]}
    available = set(stable)
    if "headless" in latest.get("experimental", {}):
        available.add(latest["experimental"]["headless"])
    # The update index catches releases missed during delayed hourly runs,
    # including multiple releases between checks. No game binary is downloaded.
    entries = history["core-linux_headless64"]
    if not isinstance(entries, list) or not entries:
        raise ValueError("Headless release history is empty or malformed")
    for entry in entries:
        for field in ("from", "to", "stable", "experimental"):
            if field in entry:
                available.add(entry[field])
                if field == "stable":
                    stable.add(entry[field])
    for candidate in available:
        version(candidate)
    experimental_checks = state["checked"]
    stable_checks = state.get("stable_checked", {})
    candidates = {(candidate, "stable") for candidate in stable}
    candidates.update(
        (candidate, "experimental") for candidate in available
        if (candidate not in stable and candidate not in stable_checks)
        or candidate in experimental_checks
    )
    # Keep incomplete releases after they leave the indexes, including failures
    # that become eligible for a retry after a fix. Pending uploads finish first.
    for release_channel, key in CHECK_KEYS.items():
        candidates.update(
            (candidate, release_channel) for candidate, entry in state.get(key, {}).items()
            if entry.get("release_status") != "published"
        )

    def previous_check(candidate, release_channel):
        return state.get(CHECK_KEYS[release_channel], {}).get(candidate, {})

    def needs_check(candidate, release_channel):
        previous = previous_check(candidate, release_channel)
        if not previous:
            return True
        if previous.get("release_status") == "published":
            return False
        if previous["status"] == "failed":
            return source is not None and previous.get("source_fingerprint") != source
        return True  # Tests passed, but publication has not finished.

    ordered = sorted(
        (
            (candidate, release_channel)
            for candidate, release_channel in candidates
            if candidate.startswith(line + ".")
            and version(candidate) >= minimum
            and needs_check(candidate, release_channel)
        ),
        key=lambda event: (
            previous_check(*event).get("release_status") != "pending",
            version(event[0]), event[1],
        ),
    )
    return [{"version": candidate, "channel": release_channel}
            for candidate, release_channel in ordered]


def record(state, versions, reports, run_url, published=False, validation_passed=True,
           channel="experimental"):
    checked = state.setdefault(CHECK_KEYS[channel], {})
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
        if any(r.get("release_channel", "experimental") != channel for r in results):
            raise ValueError(f"Different release channel tested for Factorio {engine}")
        if any(r["status"] not in {"success", "failure", "cancelled"} for r in results):
            raise ValueError(f"Invalid test status for Factorio {engine}")
        previous = checked.get(engine, {})
        checked[engine] = {
            "status": "passed"
            if validation_passed and all(r["status"] == "success" for r in results)
            else "failed",
            "source_commit": results[0]["source_commit"],
            "mod_version": results[0]["mod_version"],
            "run_url": run_url,
            "source_fingerprint": results[0]["source_fingerprint"],
        }
        if previous.get("mod_version") == results[0]["mod_version"]:
            for field in ("release_status", "release_ref", "release_date"):
                if field in previous:
                    checked[engine][field] = previous[field]
        if published:
            if checked[engine]["status"] != "passed":
                raise ValueError("Cannot publish a failed validation")
            checked[engine]["release_status"] = "published"
            checked[engine]["release_ref"] = "v" + results[0]["mod_version"]
    return state


def main_release(mod, state, released_on):
    """Choose a patch before CI; retries reuse the frozen tag, including its date."""
    date.fromisoformat(released_on)
    source = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    info = json.loads((mod / "info.json").read_text())
    entry = state.get("main_release", {})
    # A manual retry can start at the release commit already pushed by CI.
    current_tag = "v" + info["version"]
    current = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", current_tag + "^{commit}"],
        capture_output=True, text=True,
    )
    if entry.get("release_ref") == current_tag and current.stdout.strip() == source:
        return {
            "mod_version": info["version"],
            "source_ref": current_tag,
            "release_date": entry["release_date"],
        }
    major, minor, patch = version(info["version"])
    target = f"{major}.{minor}.{patch + 1}"
    tag = "v" + target
    existing = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", tag + "^{commit}"],
        capture_output=True, text=True,
    )
    if existing.returncode == 0:
        frozen = json.loads(subprocess.check_output(
            ["git", "show", f"{tag}:.github/factorio-releases.json"], text=True
        )).get("main_release", {})
        if frozen.get("source_commit") != source or frozen.get("mod_version") != target:
            raise ValueError(f"{tag} belongs to a different release; run CI on current main")
        return {
            "mod_version": target,
            "source_ref": tag,
            "release_date": frozen["release_date"],
        }
    return {"mod_version": target, "source_ref": source, "release_date": released_on}


def prepare(mod, engine, target, released_on, kind="factorio", channel="experimental"):
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
    if kind == "main":
        # State-only commits may land while CI runs; they must not change the
        # candidate's notes. Commit subjects are data, never shell commands.
        change = subprocess.check_output(
            ["git", "log", "-1", "--format=%s", "--", ".",
             ":!.github/factorio-releases.json"], text=True,
        ).strip()
    else:
        change = f"Compatibility release for Factorio {engine} ({channel})."
    changelog = mod / "changelog.txt"
    changelog.write_text(
        "-" * 99 + f"\nVersion: {target}\nDate: {released_on}\n  Changes:\n"
        f"    - {change}\n"
        "    - Validated against an unmodified game with and without Space Age, including enemy, asteroid, acid and player gameplay regressions.\n"
        + changelog.read_text()
    )


def ci_versions(state):
    """Validate only the newest tracked engine, including previously failed builds."""
    newest = max([state["minimum_version"], *state["checked"],
                  *state.get("stable_checked", {})], key=version)
    return [newest]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command", choices=("plan", "record", "ci", "fingerprint", "prepare", "main-release")
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
    parser.add_argument("--kind", choices=("factorio", "main"), default="factorio")
    parser.add_argument("--channel", choices=tuple(CHECK_KEYS), default="experimental")
    args = parser.parse_args()
    path = Path(args.state)
    state = json.loads(path.read_text())
    if args.command == "fingerprint":
        print(fingerprint())
    elif args.command == "main-release":
        print(json.dumps(main_release(Path("no-quality-no-problem"), state, args.date)))
    elif args.command == "prepare":
        prepare(Path("no-quality-no-problem"), args.engine, args.mod_version, args.date,
                args.kind, args.channel)
    elif args.command == "ci":
        print(json.dumps(ci_versions(state)))
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
            args.channel,
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
            args.channel,
        )
        path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
