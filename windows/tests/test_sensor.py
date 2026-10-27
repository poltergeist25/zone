"""Deterministic capture ownership tests; no camera/backend is invoked."""
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from zone.sensor import CameraWorker


class CaptureOwnershipTests(unittest.TestCase):
    def exercise(self, opened):
        events = []

        class Worker(CameraWorker):
            interrupted = False

            def isInterruptionRequested(self):
                return self.interrupted

        worker = Worker("chosen-camera-path", "synthetic-model")

        class Capture:
            def isOpened(self):
                return opened

            def set(self, *args):
                pass

            def read(self):
                events.append("read")
                return True, object()

            def release(self):
                events.append("release")

        class Detector:
            def detect_for_video(self, image, timestamp):
                # Simulate stop requested while inference is in flight.
                worker.interrupted = True
                return SimpleNamespace(face_landmarks=[])

            def close(self):
                events.append("detector_close")

        fake_cv = SimpleNamespace(VideoCapture=lambda index, backend: Capture(),
            setNumThreads=lambda n: None, resize=lambda f, size: f,
            cvtColor=lambda f, mode: f, CAP_DSHOW=700, CAP_PROP_FRAME_WIDTH=3,
            CAP_PROP_FRAME_HEIGHT=4, CAP_PROP_FPS=5, CAP_PROP_BUFFERSIZE=38, COLOR_BGR2RGB=1)
        fake_mp = SimpleNamespace(Image=lambda **kwargs: object(), ImageFormat=SimpleNamespace(SRGB=1),
            tasks=SimpleNamespace(BaseOptions=lambda **kwargs: object(), vision=SimpleNamespace(
                FaceLandmarkerOptions=lambda **kwargs: object(), RunningMode=SimpleNamespace(VIDEO=1),
                FaceLandmarker=SimpleNamespace(create_from_options=lambda options: Detector()))))
        errors, frames = [], []
        worker.failed.connect(errors.append)
        worker.observed.connect(lambda faces, now: frames.append(faces))
        with patch("zone.sensor.platform.system", return_value="Windows"), patch("zone.sensor.verify_model"), \
                patch("zone.sensor.cameras", return_value=[SimpleNamespace(path="chosen-camera-path", index=7)]), \
                patch.dict("sys.modules", {"cv2": fake_cv, "mediapipe": fake_mp}):
            worker.run()
        self.assertIn("release", events)
        self.assertIn("detector_close", events)
        self.assertEqual(frames, [])
        return errors, events

    def test_interruption_releases_camera_and_suppresses_pending_frame(self):
        errors, events = self.exercise(True)
        self.assertFalse(errors)
        self.assertEqual(events.count("read"), 1)
        self.assertEqual(events.count("release"), 1)

    def test_failed_camera_releases_resources_and_reports_error(self):
        errors, events = self.exercise(False)
        self.assertEqual(len(errors), 1)
        self.assertNotIn("read", events)

    def test_reordered_camera_uses_fresh_path_and_rejects_race(self):
        worker = CameraWorker("selected-device", "synthetic-model")
        released, opened, errors = [], [], []
        capture = SimpleNamespace(isOpened=lambda: True, release=lambda: released.append(True))
        fake_cv = SimpleNamespace(setNumThreads=lambda n: None, CAP_DSHOW=700,
                                  VideoCapture=lambda index, backend: opened.append(index) or capture)
        detector = SimpleNamespace(close=lambda: None)
        worker.failed.connect(errors.append)
        with patch("zone.sensor.platform.system", return_value="Windows"), patch.dict("sys.modules", {"cv2": fake_cv}), \
                patch("zone.sensor.make_landmarker", return_value=detector), \
                patch("zone.sensor.cameras", side_effect=[
                    [SimpleNamespace(path="selected-device", index=2)],
                    [SimpleNamespace(path="selected-device", index=5)]]):
            worker.run()
        self.assertEqual(opened, [2])
        self.assertEqual(released, [True])
        self.assertIn("changed", errors[0])

    def test_missing_selected_path_never_opens_another_camera(self):
        worker = CameraWorker("absent-device", "synthetic-model")
        opened = []
        fake_cv = SimpleNamespace(setNumThreads=lambda n: None, CAP_DSHOW=700,
                                  VideoCapture=lambda *args: opened.append(args))
        with patch("zone.sensor.platform.system", return_value="Windows"), patch.dict("sys.modules", {"cv2": fake_cv}), \
                patch("zone.sensor.make_landmarker", return_value=SimpleNamespace(close=lambda: None)), \
                patch("zone.sensor.cameras", return_value=[SimpleNamespace(path="other", index=0)]):
            worker.run()
        self.assertEqual(opened, [])


if __name__ == "__main__":
    unittest.main()
