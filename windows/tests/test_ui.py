"""Behavior tests use real Qt widgets but no camera, tray or desktop overlays."""
import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from pathlib import Path
import tempfile
import unittest
from PySide6.QtWidgets import QApplication
from zone.core import Store, Result, Calibration
from zone.ui import MainWindow


class UIControlsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.window = MainWindow(Store(Path(self.tmp.name)/"settings.json"), "unused.task", preview=True)

    def tearDown(self):
        self.window.save_timer.stop()
        self.window.timer.stop()
        self.window.card.hide()
        self.window.hide()
        self.window.deleteLater()
        self.app.processEvents()
        self.tmp.cleanup()

    def test_real_navigation_and_settings(self):
        w = self.window
        w.nav_buttons[2].click()
        self.assertEqual(w.pages.currentIndex(), 2)
        w.sliders["forgiveness"].setValue(50)
        self.assertEqual(w.session.settings.forgiveness, 1)
        w.sliders["forgiveness"].setValue(100)
        self.assertEqual(w.session.settings.forgiveness, 2)
        w.sliders["strength"].setValue(0)
        self.assertEqual(w.session.settings.strength, 0)
        w.sliders["delay"].setValue(35)
        self.assertEqual(w.session.settings.delay, 3.5)
        w.commit_settings()
        self.assertEqual(w.store.load().delay, 3.5)

    def test_progress_navigation_daily_score_and_week_selection(self):
        w = self.window
        now = w.progress_store.now()
        for i in range(10):
            w.progress_store.record("Green", now-10+i)
        w.nav_buttons[1].click()
        self.assertEqual(w.pages.currentIndex(), 1)
        self.assertEqual(w.progress_page.score.text(), "100 / 100")
        w.progress_page.move_week(-1)
        self.assertEqual(w.progress_page.score.text(), "— / 100")
        w.progress_page.today.click()
        self.assertEqual(w.progress_page.score.text(), "100 / 100")

    def test_dragged_levels_persist_and_forgiveness_middle_restores_defaults(self):
        w = self.window
        w.session.settings.camera = "device-one"
        w.session.settings.calibration = Calibration(.3, .4, .6)
        w.boundary_changed(1.2, True)
        w.boundary_changed(.6, False)
        w.commit_settings()
        restored = w.store.load()
        self.assertAlmostEqual(restored.yellow_threshold, .6)
        self.assertAlmostEqual(restored.red_threshold, 1.2)
        w.sliders["forgiveness"].setValue(50)
        self.assertAlmostEqual(w.session.settings.yellow_threshold, .45)
        self.assertAlmostEqual(w.session.settings.red_threshold, .85)

    def test_sleep_clears_alert_and_no_unlock_auto_restart(self):
        w = self.window
        w.session.start()
        w.session.result = Result("Red", score=20, alert=True, severity=2)
        w.update_result()
        w.system_interrupted("Sleep")
        self.assertFalse(w.session.enabled)
        self.assertFalse(w.card.isVisible())
        self.assertIn("Camera off", w.notice.text())

    def test_update_does_not_acknowledge_unsaved_progress(self):
        from unittest.mock import patch
        w = self.window
        acknowledged = []
        with patch.object(w.progress_store, "flush", return_value=False):
            w.prepare_update("a"*64, acknowledged.append)
        self.assertEqual(acknowledged, [False])
        self.assertFalse(w.quitting)
        self.assertFalse((w.store.path.parent/"update-handoff.json").exists())

    def test_failed_camera_breaks_history_and_chart(self):
        w = self.window
        now = w.progress_store.now()
        w.progress_store.record("Green", now-1)
        w.worker = object()
        w.session.start()
        w.camera_failed(w.worker, "Disconnected")
        w.progress_store.record("Green", now+.1)
        self.assertEqual(w.progress_store.day().tracked_seconds, 0)
        self.assertIsNone(w.chart.points[-1][1])

    def test_scalar_preferences_are_preserved_and_camera_stays_off(self):
        for scalar in ["null", '"text"', "42"]:
            self.window.store.path.write_text(scalar)
            other = MainWindow(Store(self.window.store.path), "unused", preview=True)
            self.assertFalse(other.session.enabled)
            self.assertTrue(list(self.window.store.path.parent.glob("settings.json.unreadable-*")))
            other.deleteLater()

    def test_camera_off_and_height_button_states(self):
        w = self.window
        self.assertEqual(w.status.text(), "Camera off")
        self.assertFalse(w.height.isEnabled())
        self.assertFalse(w.pause.isEnabled())
        w.session.start()
        w.update_result()
        w.height.click()
        self.assertTrue(w.session.calibrating)
        self.assertEqual(w.height.text(), "Go back")
        w.height.click()
        self.assertFalse(w.session.calibrating)

    def test_capture_resyncs_forgiveness_slider_to_default(self):
        from zone.core import Face
        w = self.window
        w.sliders["forgiveness"].setValue(100)
        w.session.start()
        w.session.calibrate()
        for i in range(20):
            w.session.tick([Face(.5, .43, .3, .4, .3, .4, .6)], 1+i/6)
        w.refresh_setting_labels()
        self.assertEqual(w.session.settings.forgiveness, 1)
        self.assertEqual(w.sliders["forgiveness"].value(), 50)
        self.assertEqual(w.slider_labels["forgiveness"].text(), "Default")

    def test_save_failure_is_visible_and_requires_explicit_retry(self):
        from zone.core import Face
        w = self.window
        calls = []
        def fail(settings):
            calls.append(1)
            raise OSError("disk full")
        w.session.save = fail
        w.session.start()
        w.session.calibrate()
        for i in range(30):
            w.session.tick([Face(.5, .43, .3, .4, .3, .4, .6)], 1+i/6)
            w.update_result()
        self.assertEqual(len(calls), 1)
        self.assertIn("save", w.status.text())
        self.assertEqual(w.height.text(), "Try again")
        w.height.click()
        self.assertTrue(w.session.calibrating)

    def test_card_off_clears_existing_card_immediately(self):
        w = self.window
        w.session.result = Result("Red", alert=True, severity=2)
        w.update_result()
        self.assertTrue(w.card.isVisible())
        w.red_enabled.setChecked(False)
        self.assertFalse(w.card.isVisible())
        self.assertFalse(w.store.load().red_alert)

    def test_green_clears_card_on_same_update(self):
        w = self.window
        w.session.result = Result("Red", alert=True, severity=2)
        w.update_result()
        w.session.result = Result("Green", score=100)
        w.update_result()
        self.assertFalse(w.card.isVisible())


if __name__ == "__main__":
    unittest.main()
