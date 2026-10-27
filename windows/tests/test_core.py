from dataclasses import replace
import json
import math
from pathlib import Path
import tempfile
import unittest

from zone.core import Face, Calibration, Settings, Session, Store, Association


FACE = Face(.5, .43, .3, .4, .30, .40, .60)
BASE = Calibration(FACE.eyes, FACE.nose, FACE.chin)


def dropped(distance, face=FACE):
    return replace(face, y=face.y+distance, eyes=face.eyes+distance,
                   nose=face.nose+distance, chin=face.chin+distance)


class GeometryTests(unittest.TestCase):
    def test_baseline_is_one_third_to_chin(self):
        self.assertAlmostEqual(BASE.line, .4+.2/3)
        self.assertAlmostEqual(BASE.deviation(FACE), 0)

    def test_exact_nose_and_eye_crossings(self):
        self.assertAlmostEqual(BASE.deviation(dropped(BASE.line-FACE.nose)), .45)
        self.assertAlmostEqual(BASE.deviation(dropped(BASE.line-FACE.eyes)), .85)

    def test_upward_movement_stays_green(self):
        self.assertEqual(BASE.deviation(dropped(-.1)), 0)

    def test_invalid_landmarks(self):
        for face in [replace(FACE, nose=math.nan), replace(FACE, chin=.2), replace(FACE, width=0)]:
            self.assertFalse(face.valid)


class LifecycleTests(unittest.TestCase):
    def session(self):
        session = Session(Settings(calibration=BASE))
        session.start()
        session.tick([FACE], 1)
        return session

    def test_launch_is_off_even_with_saved_height(self):
        s = Session(Settings(calibration=BASE))
        self.assertFalse(s.enabled)
        self.assertEqual(s.tick([FACE], 1).state, "Camera off")

    def test_delay_and_immediate_green(self):
        s = self.session()
        for i in range(1, 30):
            result = s.tick([dropped(.22)], 1+i/6)
            if i < 12:
                self.assertFalse(result.alert)
        self.assertTrue(result.alert)
        result = s.tick([FACE], 6)
        self.assertEqual(result.state, "Green")
        self.assertFalse(result.alert)
        self.assertEqual(result.severity, 0)

    def test_yellow_never_cards(self):
        s = self.session()
        for i in range(1, 100):
            result = s.tick([dropped(.10)], 1+i/6)
            self.assertFalse(result.alert)
        self.assertEqual(result.state, "Yellow")

    def test_displayed_score_matches_mac_scale(self):
        for distance, expected in [(0, 100), (BASE.line-FACE.nose, 85), (BASE.line-FACE.eyes, 50)]:
            s = self.session()
            # A fresh frame after a delivery interruption has no filter lag.
            s.tick([dropped(distance)], 3)
            result = s.tick([dropped(distance)], 3.2)
            self.assertAlmostEqual(result.score, expected)

    def test_pause_stop_and_resume_preserve_height(self):
        s = self.session()
        for paused in [True, False]:
            s.stop(paused)
            self.assertFalse(s.enabled)
            self.assertEqual(s.settings.calibration, BASE)
            self.assertEqual(s.result.state, "Paused" if paused else "Camera off")
            s.start()
            self.assertEqual(s.tick([FACE], 10).state, "Green")

    def test_stale_delivery_clears_alert(self):
        s = self.session()
        for i in range(1, 30):
            s.tick([dropped(.22)], 1+i/6)
        self.assertTrue(s.result.alert)
        self.assertEqual(s.watchdog(20).state, "Camera interrupted")
        self.assertFalse(s.result.alert)
        self.assertEqual(s.tick([FACE], 21).state, "Green")

    def test_disabled_card_keeps_red_feedback(self):
        s = self.session()
        s.settings.red_alert = False
        for i in range(1, 40):
            result = s.tick([dropped(.22)], 1+i/6)
        self.assertEqual(result.state, "Red")
        self.assertFalse(result.alert)
        self.assertGreater(result.severity, 1)

    def test_sensitivity_changes_both_boundaries(self):
        for forgiveness, expected in [(.65, "Yellow"), (1.5, "Green")]:
            s = self.session()
            s.settings.forgiveness = forgiveness
            for i in range(1, 15):
                result = s.tick([dropped(.06)], 1+i/6)
            self.assertEqual(result.state, expected)

    def test_lost_has_no_measured_score(self):
        s = self.session()
        r = s.tick([], 1.2)
        self.assertIsNone(r.score)
        self.assertFalse(r.alert)
        self.assertEqual(s.tick([FACE], 1.4).state, "Green")

    def test_regressing_and_invalid_clock_clears(self):
        s = self.session()
        for timestamp in [float("nan"), .9]:
            self.assertIsNone(s.tick([FACE], timestamp).score)


class CalibrationTests(unittest.TestCase):
    def test_stable_capture_saves_and_automatically_monitors(self):
        saved = []
        s = Session(Settings(forgiveness=1.5), saved.append)
        s.start()
        s.calibrate()
        for i in range(20):
            s.tick([FACE], 1+i/6)
        self.assertEqual(len(saved), 1)
        self.assertFalse(s.calibrating)
        self.assertTrue(s.enabled)
        self.assertEqual(s.settings.forgiveness, 1)
        self.assertEqual(s.tick([FACE], 4.5).state, "Green")

    def test_moving_face_does_not_calibrate(self):
        s = Session(Settings())
        s.start()
        s.calibrate()
        for i in range(30):
            s.tick([dropped(.05 if i%2 else 0)], 1+i/6)
        self.assertTrue(s.calibrating)
        self.assertIsNone(s.settings.calibration)

    def test_save_failure_retains_previous_height(self):
        attempts = []
        def fail(settings):
            attempts.append(settings)
            raise OSError("disk full")
        s = Session(Settings(calibration=BASE), fail)
        s.start()
        s.calibrate()
        for i in range(30):
            s.tick([dropped(.03)], 1+i/6)
        self.assertEqual(s.settings.calibration, BASE)
        self.assertFalse(s.calibrating)
        self.assertTrue(s.capture_error)
        self.assertEqual(len(attempts), 1)
        self.assertIn("save", s.result.state)
        s.calibrate()
        self.assertFalse(s.capture_error)
        self.assertTrue(s.calibrating)


class AssociationTests(unittest.TestCase):
    def test_initial_two_faces_are_ambiguous(self):
        subject = Association()
        self.assertEqual(subject.select([FACE, replace(FACE, x=.65)], 1), (None, "ambiguous"))

    def test_distant_visitor_does_not_replace_subject(self):
        subject = Association()
        subject.select([FACE], 1)
        selected, _ = subject.select([replace(FACE, x=.90)], 1.2)
        self.assertIsNone(selected)
        self.assertEqual(subject.select([FACE], 2)[0], FACE)

    def test_ordering_does_not_switch_faces(self):
        subject = Association()
        subject.select([FACE], 1)
        visitor = replace(FACE, x=.85)
        for faces in [[visitor, FACE], [FACE, visitor]]:
            self.assertEqual(subject.select(faces, 2)[0], FACE)

    def test_plausible_two_faces_clears_feedback(self):
        s = Session(Settings(calibration=BASE))
        s.start()
        s.tick([FACE], 1)
        result = s.tick([replace(FACE, x=.47), replace(FACE, x=.53)], 1.2)
        self.assertEqual(result.state, "One person at a time")
        self.assertFalse(result.alert)

    def test_side_exit_does_not_hold_red_and_return_recovers(self):
        s = Session(Settings(calibration=BASE))
        s.start()
        t = 1
        for i in range(35):
            s.tick([dropped(.22)], t)
            t += 1/6
        self.assertTrue(s.result.alert)
        face = dropped(.22)
        for x in [.6, .7, .8, .88]:
            s.tick([replace(face, x=x)], t)
            t += 1/6
        result = s.tick([], t)
        self.assertFalse(result.alert)
        self.assertEqual(s.subject.loss, "side")
        result = s.tick([dropped(.22)], t+.2)
        result = s.tick([dropped(.22)], t+.4)
        self.assertEqual(result.state, "Red")

    def test_downward_exit_holds_card_but_does_not_score_unseen_time(self):
        s = Session(Settings(calibration=BASE))
        s.start()
        t = 1
        for i in range(30):
            s.tick([dropped(.22)], t)
            t += 1/6
        for drop in [.26, .30, .34, .38]:
            s.tick([dropped(drop)], t)
            t += 1/6
        held = s.tick([], t)
        self.assertEqual(s.subject.loss, "bottom")
        self.assertTrue(held.alert)
        self.assertIsNone(held.score)
        # Return to last confirmed seated position before recovering upright.
        s.tick([dropped(.22)], t+.2)
        s.tick([dropped(.22)], t+.4)
        self.assertEqual(s.tick([FACE], t+.6).state, "Green")


class PersistenceTests(unittest.TestCase):
    def test_roundtrip_only_settings_not_video_or_subject(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = Store(Path(tmp)/"settings.json")
            settings = Settings(camera="synthetic-camera", calibration=BASE)
            store.save(settings)
            self.assertEqual(store.load(), settings)
            data = json.loads(store.path.read_text())
            self.assertEqual(set(data), {"schema", "camera", "calibration", "forgiveness", "delay", "strength", "red_alert", "yellow", "red", "calibrations"})
            self.assertEqual(list(Path(tmp).iterdir()), [store.path])

    def test_corrupt_and_future_settings_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = Store(Path(tmp)/"settings.json")
            for value in ["{", '{"schema":99}', '{"schema":1,"strength":100}', '{"schema":1,"forgiveness":NaN}']:
                store.path.write_text(value)
                with self.assertRaises((ValueError, TypeError)):
                    store.load()

    def test_invalid_write_preserves_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = Store(Path(tmp)/"settings.json")
            store.save(Settings())
            original = store.path.read_bytes()
            with self.assertRaises(ValueError):
                store.save(Settings(delay=0))
            self.assertEqual(store.path.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
