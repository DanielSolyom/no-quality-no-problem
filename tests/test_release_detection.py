import copy
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "releases", Path(__file__).parents[1] / "scripts/factorio-releases.py"
)
releases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(releases)


def events(*versions, channel="experimental"):
    return [{"version": engine, "channel": channel} for engine in versions]


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
        self.assertEqual(self.plan(), events("2.1.10", "2.1.11", "2.1.12"))

    def test_version_first_seen_in_both_channels_is_released_as_stable(self):
        self.latest["stable"]["headless"] = "2.1.12"
        self.assertEqual(self.plan(), events("2.1.10", "2.1.11")
                         + events("2.1.12", channel="stable"))

    def test_stable_release_ahead_of_experimental_is_released(self):
        self.latest["stable"]["headless"] = "2.1.99"
        self.assertEqual(self.plan(), events("2.1.10", "2.1.11", "2.1.12")
                         + events("2.1.99", channel="stable"))

    def test_stable_releases_work_without_an_experimental_build(self):
        self.latest["stable"]["headless"] = "2.1.13"
        for experimental in (None, {}):
            with self.subTest(experimental=experimental):
                self.latest.pop("experimental", None)
                if experimental is not None:
                    self.latest["experimental"] = experimental
                self.assertEqual(self.plan(), events("2.1.10", "2.1.11", "2.1.12")
                                 + events("2.1.13", channel="stable"))

    def test_history_can_advance_before_latest_release_metadata(self):
        self.history["core-linux_headless64"].append({"from": "2.1.12", "to": "2.1.13"})
        self.assertEqual(self.plan(), events("2.1.10", "2.1.11", "2.1.12", "2.1.13"))

    def test_stable_promotion_can_appear_in_history_first(self):
        self.state["checked"]["2.1.12"] = {"status": "passed", "release_status": "published"}
        self.history["core-linux_headless64"].append({"stable": "2.1.12"})
        self.assertEqual(self.plan(), events("2.1.10", "2.1.11")
                         + events("2.1.12", channel="stable"))

    def test_passed_checks_still_need_publication_without_code_changes(self):
        for engine in ("2.1.10", "2.1.11", "2.1.12"):
            self.state["checked"][engine] = {
                "status": "passed", "source_fingerprint": "unchanged",
            }
        self.assertEqual(releases.plan(
            self.latest, self.history, self.state, "2.1", source="unchanged"
        ), events("2.1.10", "2.1.11", "2.1.12"))

    def test_published_versions_are_not_released_again_each_hour(self):
        for engine in ("2.1.10", "2.1.11", "2.1.12"):
            self.state["checked"][engine] = {
                "status": "passed", "release_status": "published",
                "source_fingerprint": "unchanged",
            }
        self.assertEqual(releases.plan(
            self.latest, self.history, self.state, "2.1", source="unchanged"
        ), [])
        self.latest["stable"]["headless"] = "2.1.13"
        self.assertEqual(releases.plan(
            self.latest, self.history, self.state, "2.1", source="unchanged"
        ), events("2.1.13", channel="stable"))

    def test_stable_promotion_gets_another_release_with_the_same_source(self):
        self.state["checked"]["2.1.12"] = {
            "status": "passed", "release_status": "published",
            "mod_version": "1.0.4", "source_fingerprint": "unchanged",
        }
        self.latest["stable"]["headless"] = "2.1.12"
        result = releases.plan(self.latest, self.history, self.state, "2.1", source="unchanged")
        self.assertEqual(result, events("2.1.10", "2.1.11")
                         + events("2.1.12", channel="stable"))
        self.state["stable_checked"] = {"2.1.12": {
            "status": "passed", "release_status": "published", "mod_version": "1.0.5",
        }}
        self.assertEqual(self.plan(), events("2.1.10", "2.1.11"))

    def test_stable_first_version_is_not_released_as_experimental_later(self):
        self.state["stable_checked"] = {"2.1.12": {
            "status": "passed", "release_status": "published",
        }}
        self.latest["stable"]["headless"] = "2.1.13"
        self.latest["experimental"]["headless"] = "2.1.14"
        self.assertEqual(self.plan(), events("2.1.10", "2.1.11")
                         + events("2.1.13", channel="stable") + events("2.1.14"))

    def test_failed_stable_promotion_can_be_forced_independently(self):
        self.latest["stable"]["headless"] = "2.1.12"
        self.state["stable_checked"] = {"2.1.12": {
            "status": "failed", "source_fingerprint": "unchanged",
        }}
        result = releases.plan(self.latest, self.history, self.state, "2.1", source="unchanged")
        self.assertEqual(result, events("2.1.10", "2.1.11"))
        result = releases.plan(self.latest, self.history, self.state, "2.1", source="fixed")
        self.assertEqual(result, events("2.1.10", "2.1.11") + events("2.1.12", channel="stable"))
        result = releases.plan(self.latest, self.history, self.state, "2.1",
                               force="2.1.12", channel="stable")
        self.assertEqual(result, events("2.1.12", channel="stable"))

    def test_partial_publication_is_resumed_first(self):
        self.state["checked"]["2.1.12"] = {
            "status": "passed",
            "release_status": "pending",
        }
        self.assertEqual(self.plan()[0], events("2.1.12")[0])

    def test_pending_experimental_upload_finishes_before_stable_promotion(self):
        self.state["checked"]["2.1.12"] = {"status": "passed", "release_status": "pending"}
        self.latest["stable"]["headless"] = "2.1.12"
        self.assertEqual(self.plan(), events("2.1.12", "2.1.10", "2.1.11")
                         + events("2.1.12", channel="stable"))

    def test_pending_publication_is_retained_after_leaving_the_indexes(self):
        self.state["checked"]["2.1.13"] = {
            "status": "passed", "release_status": "pending",
        }
        self.assertEqual(self.plan(), events("2.1.13", "2.1.10", "2.1.11", "2.1.12"))

    def test_pending_stable_upload_survives_a_newer_stable_release(self):
        self.state["stable_checked"] = {"2.1.13": {
            "status": "passed", "release_status": "pending",
        }}
        self.latest["stable"]["headless"] = "2.1.14"
        self.assertEqual(self.plan(), events("2.1.13", channel="stable")
                         + events("2.1.10", "2.1.11", "2.1.12")
                         + events("2.1.14", channel="stable"))

    def test_failed_stable_release_can_retry_after_the_stable_head_moves_on(self):
        self.state["stable_checked"] = {"2.1.13": {
            "status": "failed", "source_fingerprint": "before",
        }}
        self.latest["stable"]["headless"] = "2.1.14"
        result = releases.plan(self.latest, self.history, self.state, "2.1", source="fixed")
        self.assertEqual(result, events("2.1.10", "2.1.11", "2.1.12")
                         + events("2.1.13", "2.1.14", channel="stable"))

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
        self.assertNotIn(events("2.1.12")[0], unchanged)
        self.assertIn(events("2.1.12")[0], changed)

    def test_failure_is_recorded_without_repeating_expensive_jobs_hourly(self):
        for n in (10, 11, 12):
            self.state["checked"][f"2.1.{n}"] = {"status": "failed"}
        self.assertEqual(self.plan(), [])
        self.assertEqual(self.plan(force="2.1.11"), events("2.1.11"))

    def test_new_major_is_not_silently_retargeted(self):
        self.latest["experimental"]["headless"] = "2.2.0"
        self.assertEqual(self.plan(), events("2.1.10", "2.1.11", "2.1.12"))
        with self.assertRaises(ValueError):
            self.plan(force="2.2.0")

    def test_supported_stable_line_continues_when_experimental_moves_on(self):
        self.latest["stable"]["headless"] = "2.1.13"
        self.latest["experimental"]["headless"] = "2.2.0"
        self.assertEqual(self.plan(), events("2.1.10", "2.1.11", "2.1.12")
                         + events("2.1.13", channel="stable"))

    def test_malformed_stable_version_fails_detection(self):
        self.latest["stable"]["headless"] = "invalid"
        with self.assertRaises(ValueError):
            self.plan()

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
        # Failed validation jobs (e.g. an evidence upload failure after testing)
        # must block publication even if both profiles reported success.
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
        pending = copy.deepcopy(self.state)
        pending["checked"]["2.1.12"] = {
            "status": "passed", "mod_version": "1.0.4",
            "release_status": "pending", "release_ref": "v1.0.4",
            "release_date": "2026-09-20",
        }
        result = releases.record(pending, ["2.1.12"], reports, "retry")
        self.assertEqual(result["checked"]["2.1.12"]["release_date"], "2026-09-20")
        self.assertEqual(result["checked"]["2.1.12"]["release_ref"], "v1.0.4")
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

    def test_stable_evidence_is_recorded_without_overwriting_experimental_release(self):
        original = copy.deepcopy(self.state["checked"])
        reports = [{
            "factorio_version": "2.1.9", "profile": profile, "status": "success",
            "source_commit": "abc", "source_fingerprint": "unchanged",
            "mod_version": "1.0.5", "release_channel": "stable",
        } for profile in ("quality", "space-age")]
        with self.assertRaises(ValueError):
            releases.record(self.state, ["2.1.9"], reports, "wrong-channel", published=True)
        releases.record(self.state, ["2.1.9"], reports, "stable-run", published=True, channel="stable")
        self.assertEqual(self.state["checked"], original)
        self.assertEqual(self.state["stable_checked"]["2.1.9"]["release_ref"], "v1.0.5")
        self.assertEqual(self.state["stable_checked"]["2.1.9"]["release_status"], "published")

    def test_ci_tests_only_the_newest_engine_without_a_legacy_pin(self):
        self.state["baseline_version"] = "2.1.7"  # Older state files remain readable.
        self.assertEqual(releases.ci_versions(self.state), ["2.1.9"])
        self.state["checked"]["2.1.11"] = {"status": "failed"}
        self.assertEqual(releases.ci_versions(self.state), ["2.1.11"])
        self.state["stable_checked"] = {"2.1.12": {"status": "passed"}}
        self.assertEqual(releases.ci_versions(self.state), ["2.1.12"])


if __name__ == "__main__":
    unittest.main()
