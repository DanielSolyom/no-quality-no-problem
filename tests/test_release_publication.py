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
                    "dependencies": ["quality >= 2.1.0", "? test-compatibility-mod"],
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
            "RELEASE_KIND": "factorio",
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

    def main_candidate(self):
        self.env["RELEASE_KIND"] = "main"
        subprocess.run(
            ["python3", "scripts/factorio-releases.py", "prepare", "--kind", "main",
             "--engine", "2.1.20", "--mod-version", "1.0.5", "--date", "2026-09-20"],
            cwd=self.repo, check=True, capture_output=True, text=True,
        )
        mod = self.repo / "no-quality-no-problem"
        with zipfile.ZipFile(self.archive, "w") as archive:
            for path in mod.iterdir():
                archive.write(path, "no-quality-no-problem_1.0.5/" + path.name)
        self.git("restore", "no-quality-no-problem")

    def plan_main(self, released_on="2026-09-20"):
        return subprocess.run(
            ["python3", "scripts/factorio-releases.py", "main-release", "--date", released_on],
            cwd=self.repo, capture_output=True, text=True, check=False,
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
        self.assertEqual(info["dependencies"], ["quality >= 2.1.0", "? test-compatibility-mod"])
        self.assertEqual((self.root / "calls").read_text().splitlines(), ["portal", "github"])

    def test_partial_github_upload_resumes_same_patch_and_tag(self):
        self.check_partial_upload(
            "FAIL_GITHUB", ["portal", "github", "portal", "github"]
        )

    def test_main_plans_a_patch_without_changing_the_source(self):
        result = self.plan_main()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "mod_version": "1.0.5", "release_date": "2026-09-20",
            "source_ref": self.git("rev-parse", "HEAD"),
        })
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_main_publishes_the_tested_patch_and_preserves_engine_history(self):
        self.main_candidate()
        source = self.git("rev-parse", "HEAD")
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        state = json.loads((self.repo / ".github/factorio-releases.json").read_text())
        self.assertEqual(state["checked"], {})
        self.assertEqual(state["main_release"]["source_commit"], source)
        self.assertEqual(state["main_release"]["release_ref"], "v1.0.5")
        self.assertEqual(self.git("rev-parse", "origin/main"), self.git("rev-parse", "v1.0.5"))
        with zipfile.ZipFile(self.archive) as archive:
            for item in archive.infolist():
                relative = item.filename.split("/", 1)[1]
                self.assertEqual(archive.read(item), (self.repo / "no-quality-no-problem" / relative).read_bytes())
        self.assertIn("Initial tested source", (self.repo / "no-quality-no-problem/changelog.txt").read_text())
        self.assertEqual((self.root / "calls").read_text().splitlines(), ["portal", "github"])

    def check_main_retry(self, failure, expected_calls):
        self.main_candidate()
        source = self.git("rev-parse", "HEAD")
        result = self.publish(**{failure: "1"})
        self.assertNotEqual(result.returncode, 0)
        checkpoint = self.git("rev-parse", "v1.0.5")
        # A failed-job retry receives the original successful jobs' outputs.
        self.git("checkout", "--detach", source)
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("tag", "--list"), "v1.0.5")
        self.assertEqual(self.git("rev-parse", "v1.0.5"), checkpoint)
        self.assertEqual((self.root / "calls").read_text().splitlines(), expected_calls)

    def test_main_portal_retry_reuses_tag_from_original_ci_commit(self):
        self.check_main_retry("FAIL_PORTAL", ["portal", "portal", "github"])

    def test_main_github_retry_reuses_tag_from_original_ci_commit(self):
        self.check_main_retry("FAIL_GITHUB", ["portal", "github", "portal", "github"])

    def test_full_ci_retry_and_manual_retry_keep_the_frozen_version_and_date(self):
        self.main_candidate()
        source = self.git("rev-parse", "HEAD")
        self.assertNotEqual(self.publish(FAIL_PORTAL="1").returncode, 0)
        for ref in (source, "v1.0.5"):
            with self.subTest(ref=ref):
                self.git("checkout", "--detach", ref)
                result = self.plan_main("2026-09-21")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), {
                    "mod_version": "1.0.5", "source_ref": "v1.0.5", "release_date": "2026-09-20",
                })

    def test_new_main_change_gets_the_next_patch(self):
        self.main_candidate()
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.repo / "no-quality-no-problem/data-final-fixes.lua").write_text("-- next change\n")
        self.git("add", ".")
        self.git("commit", "-m", "Next change")
        result = self.plan_main()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["mod_version"], "1.0.6")

    def test_main_does_not_reuse_an_unrelated_release_tag(self):
        source = self.git("rev-parse", "HEAD")
        result = self.publish()  # The hourly engine release owns this version.
        self.assertEqual(result.returncode, 0, result.stderr)
        checkpoint = self.git("rev-parse", "v1.0.5")
        self.git("checkout", "--detach", source)
        self.main_candidate()
        self.assertNotEqual(self.plan_main().returncode, 0)
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different release", result.stderr)
        self.assertEqual(self.git("rev-parse", "v1.0.5"), checkpoint)
        self.assertEqual((self.root / "calls").read_text().splitlines(), ["portal", "github"])

    def test_main_allows_state_only_commits_during_validation(self):
        self.main_candidate()
        source = self.git("rev-parse", "HEAD")
        state_path = self.repo / ".github/factorio-releases.json"
        state = json.loads(state_path.read_text())
        state["checked"]["2.1.19"] = {"status": "passed"}
        state_path.write_text(json.dumps(state))
        self.git("add", ".")
        self.git("commit", "-m", "Record Factorio compatibility checks")
        self.git("push", "origin", "HEAD:main")
        self.git("checkout", "--detach", source)
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        state = json.loads(state_path.read_text())
        self.assertEqual(state["checked"]["2.1.19"], {"status": "passed"})
        self.assertEqual(state["main_release"]["source_commit"], source)

    def check_mismatching_archive(self):
        with zipfile.ZipFile(self.archive, "a") as archive:
            archive.writestr(
                "no-quality-no-problem_1.0.5/untested.lua", "-- not tested"
            )
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)
        self.assertEqual(self.git("tag", "--list"), "")
        self.assertFalse((self.root / "calls").exists())

    def test_mismatching_archive_never_creates_a_tag_or_uploads(self):
        self.check_mismatching_archive()

    def test_main_mismatching_archive_never_creates_a_tag_or_uploads(self):
        self.main_candidate()
        self.check_mismatching_archive()

    def check_concurrent_push(self):
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

    def test_code_pushed_during_tests_is_not_released(self):
        self.check_concurrent_push()

    def test_main_code_pushed_during_tests_is_not_released(self):
        self.main_candidate()
        self.check_concurrent_push()


if __name__ == "__main__":
    unittest.main()
