import copy
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "releases", Path(__file__).parents[1] / "scripts/factorio-releases.py"
)
releases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(releases)


class ReleaseDetection(unittest.TestCase):
    def setUp(self):
        self.state = {
            "minimum_version": "2.1.9",
            "checked": {"2.1.9": {"status": "passed", "release_status": "published"}},
        }
        self.latest = {
            "stable": {"headless": "2.0.77"},
            "experimental": {"headless": "2.1.12"},
        }
        self.history = {
            "core-linux_headless64": [
                {"from": "2.1.8", "to": "2.1.9"},
                {"from": "2.1.9", "to": "2.1.10"},
                {"from": "2.1.10", "to": "2.1.11"},
                {"from": "2.1.11", "to": "2.1.12"},
            ]
        }

    def plan(self, force=None):
        return releases.plan(self.latest, self.history, self.state, "2.1", force)

    def test_catches_up_missed_releases_in_numeric_order(self):
        self.assertEqual(self.plan(), ["2.1.10", "2.1.11", "2.1.12"])

    def test_duplicate_stable_and_experimental_is_built_once(self):
        self.latest["stable"]["headless"] = "2.1.12"
        self.assertEqual(self.plan().count("2.1.12"), 1)

    def test_stable_release_does_not_advance_experimental_queue(self):
        self.latest["stable"]["headless"] = "2.1.99"
        self.assertNotIn("2.1.99", self.plan())

    def test_partial_publication_is_resumed_first(self):
        self.state["checked"]["2.1.12"] = {
            "status": "passed",
            "release_status": "pending",
        }
        self.assertEqual(self.plan()[0], "2.1.12")

    def test_failure_retries_when_source_changes(self):
        self.state["checked"]["2.1.12"] = {
            "status": "failed",
            "source_fingerprint": "before",
        }
        unchanged = releases.plan(
            self.latest, self.history, self.state, "2.1", source="before"
        )
        changed = releases.plan(
            self.latest, self.history, self.state, "2.1", source="after"
        )
        self.assertNotIn("2.1.12", unchanged)
        self.assertIn("2.1.12", changed)

    def test_failure_is_recorded_without_repeating_expensive_jobs_hourly(self):
        for n in (10, 11, 12):
            self.state["checked"][f"2.1.{n}"] = {"status": "failed"}
        self.assertEqual(self.plan(), [])
        self.assertEqual(self.plan(force="2.1.11"), ["2.1.11"])

    def test_new_major_is_not_silently_retargeted(self):
        self.latest["experimental"]["headless"] = "2.2.0"
        self.assertNotIn("2.2.0", self.plan())
        with self.assertRaises(ValueError):
            self.plan(force="2.2.0")

    def test_malformed_response_is_not_no_update(self):
        self.latest["experimental"]["headless"] = "2.1.12; echo broken"
        with self.assertRaises(ValueError):
            self.plan()
        self.latest = {}
        with self.assertRaises(KeyError):
            self.plan()

    def test_incomplete_evidence_cannot_mark_release_tested(self):
        with self.assertRaises(ValueError):
            releases.record(self.state, ["2.1.12"], [], "run")
        self.assertNotIn("2.1.12", self.state["checked"])

    def test_only_both_successful_profiles_mean_passed(self):
        reports = [
            {
                "factorio_version": "2.1.12",
                "profile": p,
                "status": "success",
                "source_commit": "abc",
                "source_fingerprint": "same-content",
                "mod_version": "1.0.4",
            }
            for p in ("quality", "space-age")
        ]
        result = releases.record(copy.deepcopy(self.state), ["2.1.12"], reports, "run")
        self.assertEqual(result["checked"]["2.1.12"]["status"], "passed")
        # A failed baseline engine must block publication even if this new
        # experimental engine passes both profiles.
        result = releases.record(
            copy.deepcopy(self.state),
            ["2.1.12"],
            reports,
            "run",
            validation_passed=False,
        )
        self.assertEqual(result["checked"]["2.1.12"]["status"], "failed")
        with self.assertRaises(ValueError):
            releases.record(
                copy.deepcopy(self.state),
                ["2.1.12"],
                reports,
                "run",
                published=True,
                validation_passed=False,
            )
        result = releases.record(
            copy.deepcopy(self.state), ["2.1.12"], reports, "run", published=True
        )
        self.assertEqual(result["checked"]["2.1.12"]["release_status"], "published")
        reports[1]["source_fingerprint"] = "different"
        with self.assertRaises(ValueError):
            releases.record(self.state, ["2.1.12"], reports, "run")
        reports[1]["source_fingerprint"] = "same-content"
        reports[1]["status"] = "failure"
        result = releases.record(copy.deepcopy(self.state), ["2.1.12"], reports, "run")
        self.assertEqual(result["checked"]["2.1.12"]["status"], "failed")
        reports[1]["source_commit"] = "different"
        with self.assertRaises(ValueError):
            releases.record(self.state, ["2.1.12"], reports, "run")


if __name__ == "__main__":
    unittest.main()
