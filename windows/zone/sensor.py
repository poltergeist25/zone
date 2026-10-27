"""One camera and one inference owner; no frame recording or networking."""
import hashlib
import os
import platform
from pathlib import Path
import time

from PySide6.QtCore import QThread, Signal
from .core import Face

# Official, versioned MediaPipe task bundle. Bootstrap downloads it; runtime
# only reads a local, verified copy. No camera permission on module import.
MODEL_URL = "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task"
MODEL_SHA256 = "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff"


def verify_model(path):
    if hashlib.sha256(Path(path).read_bytes()).hexdigest() != MODEL_SHA256:
        raise ValueError("Face model is missing or changed. Run bootstrap again.")


def make_landmarker(model_path):
    """Shared by camera capture and explicit, camera-free qualification."""
    # No Zone feature records audio. Its transitive sounddevice import must
    # not select the optional ASIO loader from an inherited environment flag.
    os.environ.pop("SD_ENABLE_ASIO", None)
    import mediapipe as mp
    verify_model(model_path)
    return mp.tasks.vision.FaceLandmarker.create_from_options(
        mp.tasks.vision.FaceLandmarkerOptions(
            base_options=mp.tasks.BaseOptions(model_asset_path=str(model_path)),
            running_mode=mp.tasks.vision.RunningMode.VIDEO, num_faces=3,
            min_face_detection_confidence=.5, min_face_presence_confidence=.5,
            min_tracking_confidence=.5, output_face_blendshapes=False,
            output_facial_transformation_matrixes=False))


def observe_frame(detector, frame, timestamp_ms):
    import cv2
    import mediapipe as mp
    frame = cv2.resize(frame, (384, 216))
    image = mp.Image(image_format=mp.ImageFormat.SRGB,
                     data=cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
    return decode_faces(detector.detect_for_video(image, timestamp_ms))


def decode_faces(result):
    faces = []
    for points in result.face_landmarks:
        if len(points) <= 362:
            continue
        xs, ys = [p.x for p in points], [p.y for p in points]
        # Midpoints of inner/outer eye corners suppress blinking movement.
        eyes = sum(points[i].y for i in [33, 133, 263, 362])/4
        face = Face((min(xs)+max(xs))/2, (min(ys)+max(ys))/2,
                    max(xs)-min(xs), max(ys)-min(ys), eyes, points[1].y, points[152].y)
        if face.valid:
            faces.append(face)
    return faces


def cameras():
    if platform.system() != "Windows":
        raise RuntimeError("Camera access for this target is Windows-only.")
    import cv2
    from cv2_enumerate_cameras import enumerate_cameras
    return list(enumerate_cameras(cv2.CAP_DSHOW))


class CameraWorker(QThread):
    observed = Signal(object, float)
    failed = Signal(str)

    def __init__(self, camera_path, model_path):
        super().__init__()
        self.camera_path = camera_path
        self.model_path = model_path

    def run(self):
        capture = None
        detector = None
        try:
            if platform.system() != "Windows":
                raise RuntimeError("This camera target runs on Windows only.")
            import cv2
            cv2.setNumThreads(1)
            detector = make_landmarker(self.model_path)
            if self.isInterruptionRequested():
                return
            matches = [item for item in cameras() if item.path == self.camera_path]
            if len(matches) != 1:
                raise RuntimeError("Your selected camera is unavailable. Choose it again; no other camera was opened.")
            camera_index = matches[0].index
            capture = cv2.VideoCapture(camera_index, cv2.CAP_DSHOW)
            if not capture.isOpened():
                raise RuntimeError("Couldn’t open this camera. Check Windows camera privacy settings and try again.")
            current = [item for item in cameras() if item.path == self.camera_path]
            if len(current) != 1 or current[0].index != camera_index:
                raise RuntimeError("Camera devices changed while opening. Camera off; select your camera again.")
            capture.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
            capture.set(cv2.CAP_PROP_FRAME_HEIGHT, 360)
            capture.set(cv2.CAP_PROP_FPS, 6)
            capture.set(cv2.CAP_PROP_BUFFERSIZE, 1)
            last_ms = -1
            while not self.isInterruptionRequested():
                started = time.monotonic()
                ok, frame = capture.read()
                if self.isInterruptionRequested():
                    break
                if not ok:
                    raise RuntimeError("Camera disconnected. Turn Camera on to retry.")
                observed_at = time.monotonic()
                timestamp = max(last_ms+1, int(observed_at*1000))
                last_ms = timestamp
                faces = observe_frame(detector, frame, timestamp)
                # No image or full face mesh crosses into the UI queue.
                if not self.isInterruptionRequested():
                    self.observed.emit(faces, observed_at)
                remaining = 1/6 - (time.monotonic()-started)
                if remaining > 0:
                    self.msleep(int(remaining*1000))
        except Exception as exc:
            if not self.isInterruptionRequested():
                self.failed.emit(str(exc))
        finally:
            if capture is not None:
                capture.release()
            if detector is not None:
                detector.close()
