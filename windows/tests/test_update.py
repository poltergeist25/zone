import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from zone.update import write_handoff, consume_handoff
from zone.core import Settings, Store, Calibration


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.profile = Path(self.temp.name)/"profile"
        self.store = Store(self.profile/"settings.json")
        self.store.save(Settings(camera="exact-device", calibration=Calibration(.3, .4, .6)))
        self.exe = Path(self.temp.name)/"Zone.exe"
        self.exe.write_bytes(b"new executable fixture")
        self.digest = hashlib.sha256(self.exe.read_bytes()).hexdigest()

    def tearDown(self):
        self.temp.cleanup()

    def write(self, mode="active"):
        write_handoff(self.profile, self.digest, camera="exact-device", mode=mode,
                      page=1, visible=False, old_pid=999, now=1000)

    def test_exact_update_one_use_and_off_paused_intent(self):
        for mode in ("active", "paused", "off"):
            self.write(mode)
            state = consume_handoff(self.profile, self.exe, now=1010, alive=lambda pid: False)
            self.assertEqual(state["mode"], mode)
            self.assertFalse(state["visible"])
            self.assertIsNone(consume_handoff(self.profile, self.exe, now=1010))

    def test_changed_executable_or_settings_expiry_live_old_process_fail_closed(self):
        cases = [
            (lambda: self.exe.write_bytes(b"wrong binary"), 1010, False),
            (lambda: self.store.save(Settings(camera="another-device")), 1010, False),
            (lambda: None, 1121, False),
            (lambda: None, 1010, True),
        ]
        for change, now, alive in cases:
            self.exe.write_bytes(b"new executable fixture")
            self.store.save(Settings(camera="exact-device", calibration=Calibration(.3, .4, .6)))
            self.write()
            change()
            with self.assertRaises(ValueError):
                consume_handoff(self.profile, self.exe, now=now, alive=lambda pid: alive)
            self.assertFalse((self.profile/"update-handoff.json").exists())

    def test_invalid_target_cannot_prepare_handoff(self):
        with self.assertRaises(ValueError):
            write_handoff(self.profile, "../bad", camera="camera", mode="active", page=0, visible=True)


class CameraProfileTests(unittest.TestCase):
    def test_camera_specific_calibration_and_boundaries_survive_switches(self):
        settings = Settings(camera="one", calibration=Calibration(.3, .4, .6))
        settings.set_boundary(1.2, True)
        other = settings.for_camera("two")
        self.assertIsNone(other.calibration)
        other.calibration = Calibration(.2, .3, .5)
        other.set_forgiveness(2)
        back = other.for_camera("one")
        self.assertEqual(back.calibration, settings.calibration)
        self.assertEqual(back.red_threshold, 1.2)
        two = back.for_camera("two")
        self.assertEqual(two.calibration, other.calibration)
        self.assertEqual(two.forgiveness, 2)

    def test_v1_preferences_migrate_without_resetting_user_height(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)/"settings.json"
            original = {"schema": 1, "camera": "legacy", "calibration": {"eyes": .3, "nose": .4, "chin": .6},
                        "forgiveness": 1.4, "delay": 3, "strength": 2, "red_alert": False}
            path.write_text(json.dumps(original))
            store = Store(path)
            settings = store.load()
            self.assertEqual(settings.calibration, Calibration(.3, .4, .6))
            store.save(settings)
            self.assertEqual(json.loads(path.read_text())["schema"], 2)
            self.assertEqual(store.load().forgiveness, 1.4)
