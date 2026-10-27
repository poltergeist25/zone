from datetime import datetime
import json
import math
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from zone.progress import ProgressStore, DayProgress, EASTERN, date_id, week_dates


def instant(text):
    return datetime.fromisoformat(text).timestamp()


class ProgressTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name)/"daily-progress.json"
        self.start = instant("2026-10-26T12:00:00-04:00")
        self.store = ProgressStore(self.path, now=lambda: self.start)

    def test_empty_day_is_unscored_and_independent(self):
        day = self.store.day()
        self.assertEqual(day.date_id, "2026-10-26")
        self.assertIsNone(day.score)
        self.assertIsNone(day.green_fraction)
        self.assertEqual(len(day.hours), 24)
        day.hours[0].green_seconds = 10
        self.assertEqual(self.store.day().hours[0].green_seconds, 0)

    def test_weighted_score_uses_elapsed_time_and_prior_band(self):
        # One second green, one second yellow, two seconds red => 37.5.
        for offset, state in [(0, "Green"), (1, "Yellow"), (2, "Red"), (3, "Red"), (4, "Green")]:
            self.store.record(state, self.start+offset)
        day = self.store.day()
        self.assertEqual((day.green_seconds, day.yellow_seconds, day.red_seconds), (1, 1, 2))
        self.assertEqual(day.tracked_seconds, 4)
        self.assertEqual(day.score, 37.5)
        self.assertEqual(day.green_fraction+day.yellow_fraction+day.red_fraction, 1)
        self.assertTrue(day.valid)
        self.assertEqual(day.hours[12].score, 37.5)

    def test_pauses_missing_and_ineligible_time_excluded(self):
        self.store.record("Green", self.start)
        self.store.record("Finding you", self.start+1)
        self.store.record("Green", self.start+2)
        self.store.record("Green", self.start+3, eligible=False)
        self.store.record("Green", self.start+4)
        self.store.record("Green", self.start+5)
        self.assertEqual(self.store.day().tracked_seconds, 1)

    def test_long_gap_breaks_continuity_but_new_readings_resume(self):
        self.store.record("Green", self.start)
        self.store.record("Red", self.start+2)
        self.store.record("Green", self.start+3)
        self.assertEqual(self.store.day().green_seconds, 0)
        self.assertEqual(self.store.day().red_seconds, 1)

    def test_nonmonotonic_invalid_and_duplicates_do_not_add_time(self):
        for value in [math.nan, math.inf, -math.inf, True, "invalid"]:
            self.store.record("Green", self.start)
            self.store.record("Green", value)
        self.store.record("Green", self.start)
        self.store.record("Red", self.start-1)
        self.assertEqual(self.store.rejected_samples, 6)
        self.store.record("Green", self.start)
        self.store.record("Red", self.start)
        self.store.record("Green", self.start+1)
        self.assertEqual(self.store.day().green_seconds, 1)
        self.assertEqual(self.store.day().red_seconds, 0)

    def test_duplicate_missing_observation_breaks_anchor(self):
        self.store.record("Green", self.start)
        self.store.record("Camera off", self.start)
        self.store.record("Green", self.start+1)
        self.assertEqual(self.store.day().tracked_seconds, 0)

    def test_hour_and_midnight_split_in_eastern(self):
        start = instant("2026-10-26T23:59:59.500000-04:00")
        self.store.record("Green", start)
        self.store.record("Green", start+1)
        yesterday, today = self.store.day("2026-10-26"), self.store.day("2026-10-27")
        self.assertEqual(yesterday.hours[23].green_seconds, .5)
        self.assertEqual(today.hours[0].green_seconds, .5)
        self.assertTrue(yesterday.valid and today.valid)

    def test_spring_forward_skips_nonexistent_hour(self):
        start = instant("2026-03-08T01:59:59.500000-05:00")
        self.store.record("Yellow", start)
        self.store.record("Yellow", start+1)
        day = self.store.day("2026-03-08")
        self.assertEqual(day.hours[1].yellow_seconds, .5)
        self.assertEqual(day.hours[2].yellow_seconds, 0)
        self.assertEqual(day.hours[3].yellow_seconds, .5)

    def test_fall_back_both_repeated_hours_share_bucket(self):
        start = instant("2026-11-01T01:59:59.500000-04:00")
        self.store.record("Red", start)
        self.store.record("Red", start+1)
        day = self.store.day("2026-11-01")
        self.assertEqual(day.hours[1].red_seconds, 1)
        self.assertEqual(day.hours[2].red_seconds, 0)
        self.assertTrue(day.valid)

    def test_atomic_persistence_roundtrip_without_live_anchor(self):
        self.store.record("Green", self.start)
        self.store.record("Green", self.start+1)
        self.assertFalse(self.path.exists())
        self.assertTrue(self.store.flush())
        loaded = ProgressStore(self.path, now=lambda: self.start)
        self.assertEqual(loaded.day().score, 100)
        loaded.record("Red", self.start+2)
        self.assertEqual(loaded.day().tracked_seconds, 1)
        self.assertEqual(list(self.path.parent.glob(".zone-progress-*")), [])

    def test_save_throttled_to_thirty_seconds(self):
        with patch.object(self.store, "_save", wraps=self.store._save) as save:
            for offset in range(31):
                self.store.record("Green", self.start+offset)
            self.assertEqual(save.call_count, 0)
            self.store.record("Green", self.start+31)
            self.assertEqual(save.call_count, 1)
            self.assertEqual(json.loads(self.path.read_text())["days"][0]["green_seconds"], 31)

    def test_corrupt_or_newer_file_preserved_exactly(self):
        for payload in ["not-json", '{"version": 8, "private": "retain"}',
                        '{"version": true, "days": [], "time_zone": "America/New_York"}']:
            self.path.write_text(payload)
            loaded = ProgressStore(self.path)
            self.assertIsNotNone(loaded.error_message)
            retained = list(self.path.parent.glob("daily-progress.unreadable-*.json"))
            self.assertTrue(any(p.read_text() == payload for p in retained))
            self.assertFalse(self.path.exists())
            loaded.record("Green", self.start)
            loaded.record("Green", self.start+1)
            self.assertTrue(loaded.flush())
            self.assertEqual(json.loads(self.path.read_text())["version"], 1)

    def test_failed_preservation_blocks_writes(self):
        payload = "keep these bytes"
        self.path.write_text(payload)
        with patch.object(Path, "rename", side_effect=OSError("denied")):
            loaded = ProgressStore(self.path)
        loaded.record("Green", self.start)
        loaded.record("Green", self.start+1)
        self.assertFalse(loaded.flush())
        self.assertEqual(self.path.read_text(), payload)
        self.assertIn("will not be overwritten", loaded.error_message)

    def test_failed_atomic_replace_preserves_previous_and_can_retry(self):
        self.store.record("Green", self.start)
        self.store.record("Green", self.start+1)
        self.store.flush()
        previous = self.path.read_bytes()
        self.store.record("Green", self.start+2)
        with patch("zone.progress.os.replace", side_effect=OSError("denied")):
            self.assertFalse(self.store.flush())
        self.assertEqual(self.path.read_bytes(), previous)
        self.assertIn("Could not save", self.store.error_message)
        self.assertTrue(self.store.flush())
        self.assertIsNone(self.store.error_message)
        self.assertEqual(ProgressStore(self.path, now=lambda: self.start).day().green_seconds, 2)

    def test_invalid_totals_and_duplicate_days_preserved(self):
        day = DayProgress(date_id="2026-10-26")
        from dataclasses import asdict
        for days in [[{**asdict(day), "green_seconds": 30}], [asdict(day), asdict(day)]]:
            self.path.write_text(json.dumps({"version": 1, "time_zone": "America/New_York", "days": days}))
            loaded = ProgressStore(self.path)
            self.assertEqual(loaded.days, [])
            self.assertIsNotNone(loaded.error_message)

    def test_calendar_helpers_and_validation(self):
        self.assertEqual(date_id(instant("2026-10-27T01:00:00+00:00")), "2026-10-26")
        self.assertEqual(week_dates(self.start), [f"2026-10-{n:02}" for n in range(26, 32)]+["2026-11-01"])
        self.assertEqual(week_dates(self.start, -1)[0], "2026-10-19")
        with self.assertRaises(ValueError):
            self.store.day("2026-02-30")


if __name__ == "__main__":
    unittest.main()
