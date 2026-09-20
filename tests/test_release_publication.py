"""Exercise release checkpoints against a local git remote, never public services."""

import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "release_tools", ROOT / "scripts/factorio-releases.py"
)
release_tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_tools)


class Publication(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "source"
        self.repo.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        (self.repo / "scripts").mkdir()
        for name in ("factorio-releases.py", "release-tested.sh"):
            shutil.copy2(ROOT / "scripts" / name, self.repo / "scripts" / name)
        mod = self.repo / "no-quality-no-problem"
        mod.mkdir()
        (mod / "info.json").write_text(
            json.dumps(
                {
                    "name": "no-quality-no-problem",
                    "version": "1.0.4",
                    "factorio_version": "2.1",
                    "dependencies": ["quality >= 2.1.0", "? Better-Power-Armor-Grid"],
                }
            )
            + "\n"
        )
        (mod / "changelog.txt").write_text("Version: 1.0.4\n")
        (mod / "data-final-fixes.lua").write_text("-- tested gameplay\n")
        (self.repo / ".github").mkdir()
        (self.repo / ".github/factorio-releases.json").write_text(
            json.dumps({"minimum_version": "2.1.19", "checked": {}})
        )
        # Replace only the network boundaries; real git, archive verification,
        # version preparation and checkpoint logic run unchanged.
        publish = self.repo / "publish.sh"
        publish.write_text(
            '#!/bin/sh\nprintf "portal\\n" >> "$CALL_LOG"\n[ "${FAIL_PORTAL:-0}" != 1 ]\n'
        )
        publish.chmod(0o755)
        self.git("add", ".")
        self.git("commit", "-m", "Initial tested source")
        self.remote = self.root / "remote.git"
        self.git("init", "--bare", str(self.remote))
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "origin", "main")
        tools = self.root / "bin"
        tools.mkdir()
        gh = tools / "gh"
        gh.write_text(
            '#!/bin/sh\n[ "$2" != view ] || exit 1\nprintf "github\\n" >> "$CALL_LOG"\n'
            '[ "${FAIL_GITHUB:-0}" != 1 ]\n'
        )
        gh.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": str(tools) + os.pathsep + os.environ["PATH"],
            "FACTORIO_VERSION": "2.1.20",
            "MOD_VERSION": "1.0.5",
            "RELEASE_DATE": "2026-09-20",
            "RELEASE_BRANCH": "main",
            "RUN_URL": "https://example.invalid/test-run",
            "CALL_LOG": str(self.root / "calls"),
        }
        candidate = self.root / "candidate"
        shutil.copytree(mod, candidate)
        release_tools.prepare(candidate, "2.1.20", "1.0.5", "2026-09-20")
        self.archive = self.root / "no-quality-no-problem_1.0.5.zip"
        with zipfile.ZipFile(self.archive, "w") as archive:
            for path in candidate.iterdir():
                archive.write(path, "no-quality-no-problem_1.0.5/" + path.name)

    def git(self, *args):
        return subprocess.check_output(
            ["git", *args], cwd=self.repo, stderr=subprocess.DEVNULL, text=True
        ).strip()

    def publish(self, **env):
        return subprocess.run(
            ["bash", "scripts/release-tested.sh", str(self.archive)],
            cwd=self.repo,
            env={**self.env, **env},
            capture_output=True,
            text=True,
            check=False,
        )

    def check_partial_upload(self, failure, expected_calls):
        failed = self.publish(**{failure: "1"})
        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        state = json.loads((self.repo / ".github/factorio-releases.json").read_text())
        self.assertEqual(state["checked"]["2.1.20"]["release_status"], "pending")
        checkpoint = self.git("rev-parse", "v1.0.5")
        self.assertIn(checkpoint, self.git("ls-remote", "origin", "refs/tags/v1.0.5"))
        self.git("checkout", "--detach", "v1.0.5")
        passed = self.publish()
        self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
        self.assertEqual(self.git("tag", "--list"), "v1.0.5")
        self.assertEqual(self.git("rev-parse", "v1.0.5"), checkpoint)
        self.assertEqual(
            (self.root / "calls").read_text().splitlines(),
            expected_calls,
        )

    def test_partial_portal_upload_resumes_same_patch_and_tag(self):
        self.check_partial_upload("FAIL_PORTAL", ["portal", "portal", "github"])

    def test_publishes_with_optional_compatibility_dependency(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        info = json.loads((self.repo / "no-quality-no-problem/info.json").read_text())
        self.assertEqual(info["dependencies"], ["quality >= 2.1.0", "? Better-Power-Armor-Grid"])
        self.assertEqual((self.root / "calls").read_text().splitlines(), ["portal", "github"])

    def test_partial_github_upload_resumes_same_patch_and_tag(self):
        self.check_partial_upload(
            "FAIL_GITHUB", ["portal", "github", "portal", "github"]
        )

    def test_mismatching_archive_never_creates_a_tag_or_uploads(self):
        with zipfile.ZipFile(self.archive, "a") as archive:
            archive.writestr(
                "no-quality-no-problem_1.0.5/untested.lua", "-- not tested"
            )
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)
        self.assertEqual(self.git("tag", "--list"), "")
        self.assertFalse((self.root / "calls").exists())

    def test_code_pushed_during_tests_is_not_released(self):
        original = self.git("rev-parse", "HEAD")
        (self.repo / "no-quality-no-problem/data-final-fixes.lua").write_text(
            "-- new untested code\n"
        )
        self.git("add", ".")
        self.git("commit", "-m", "Concurrent code change")
        self.git("push", "origin", "main")
        self.git("checkout", "--detach", original)
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("tag", "--list"), "")
        self.assertFalse((self.root / "calls").exists())


if __name__ == "__main__":
    unittest.main()
