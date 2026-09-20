import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "player", Path(__file__).parents[1] / "scripts/check-player.py"
)
player = importlib.util.module_from_spec(spec)
spec.loader.exec_module(player)


class Measurements(unittest.TestCase):
    def test_powered_boolean_is_not_numeric_one(self):
        for before, after in ((True, 1), (False, 0), (1, True)):
            with (
                self.subTest(before=before, after=after),
                self.assertRaises(AssertionError),
            ):
                player.compare(before, after)

    def test_missing_observations_and_shorter_traces_fail(self):
        for before, after in (({"asteroid": 100}, {}), ([1, 2], [1])):
            with self.subTest(before=before), self.assertRaises(AssertionError):
                player.compare(before, after)

    def test_non_finite_damage_fails(self):
        for after in (float("inf"), float("nan")):
            with self.subTest(after=after), self.assertRaises(AssertionError):
                player.compare(1, after)

    def test_roundoff_is_tolerated_but_stat_changes_fail(self):
        player.compare(0.6, 0.60000001)
        with self.assertRaises(AssertionError):
            player.compare(0.6, 0)


if __name__ == "__main__":
    unittest.main()
