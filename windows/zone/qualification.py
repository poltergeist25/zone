"""Explicit camera-free qualification, shared by Python and frozen EXE checks.

Does not enumerate cameras, open a capture device, access a real profile, or
perform networking. The video file and manifest must be explicitly supplied.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import sys
import tempfile
import time

from .core import Session, Settings, Store
from .sensor import make_landmarker, observe_frame


def replay(model, video, manifest_path, output):
    import cv2
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
    if manifest.get("schema") != 1 or manifest.get("fps") != 6:
        raise ValueError("Unsupported qualification manifest")
    if hashlib.sha256(Path(video).read_bytes()).hexdigest() != manifest["video_sha256"]:
        raise ValueError("Video checksum mismatch")
    # Explicit file backend. This path must never accept a camera index or URL.
    video = Path(video).resolve(strict=True)
    capture = cv2.VideoCapture(str(video), cv2.CAP_OPENCV_MJPEG)
    if not capture.isOpened():
        raise RuntimeError("Video decoder could not open fixture")
    cv2.setNumThreads(1)
    session = Session(Settings())
    session.start()
    session.calibrate()
    rows = []
    try:
        with make_landmarker(model) as detector:
            for index, phase in enumerate(manifest["phases"]):
                ok, frame = capture.read()
                if not ok:
                    raise RuntimeError(f"Video ended at frame {index}")
                timestamp = 1+index/manifest["fps"]
                started = time.perf_counter()
                faces = observe_frame(detector, frame, round(timestamp*1000))
                result = session.tick(faces, timestamp)
                rows.append({"frame": index, "phase": phase, "state": result.state,
                             "score": result.score, "alert": result.alert,
                             "face_count": len(faces),
                             "processing_ms": round((time.perf_counter()-started)*1000, 3)})
            if capture.read()[0]:
                raise RuntimeError("Video has unmanifested frames")
    finally:
        capture.release()
    def tail(phase):
        return [r for r in rows if r["phase"] == phase][-3:]
    checks = {
        "stable_calibration_auto_starts": session.settings.calibration is not None and all(r["state"] == "Green" for r in tail("green")),
        "yellow_without_card": all(r["state"] == "Yellow" and not r["alert"] for r in tail("yellow")),
        "red_card_after_delay": all(r["state"] == "Red" and r["alert"] for r in tail("red")),
        "green_clears_card": all(r["state"] == "Green" and not r["alert"] for r in tail("recovery")),
        "missing_is_unscored": all(r["score"] is None and not r["alert"] for phase in ["side_exit", "occluded"] for r in tail(phase)),
        "both_returns_resume": all(r["state"] == "Green" for phase in ["return", "second_return"] for r in tail(phase)),
    }
    report = {"kind": "simulated public-video inference, not physical webcam acceptance",
              "decoder": "OpenCV built-in MJPEG AVI; no FFmpeg plugin",
              "platform": platform.platform(), "frozen": bool(getattr(sys, "frozen", False)),
              "checks": checks, "rows": rows,
              "privacy": {"camera_device_opened": False, "real_profile_used": False, "network_in_replay": False}}
    (output/"video-report.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    if not all(checks.values()):
        raise AssertionError(f"Video qualification failed: {checks}")
    return report


def check_widgets(output):
    """Actual bundled Qt startup and retained control state, without a camera."""
    from PySide6.QtWidgets import QApplication
    from PySide6.QtGui import QFontMetrics
    from .ui import MainWindow
    app = QApplication.instance() or QApplication([])
    with tempfile.TemporaryDirectory(prefix="zone-self-test-") as tmp:
        window = MainWindow(Store(Path(tmp)/"settings.json"), Path(tmp)/"unused.task", preview=True)
        window.show()
        app.processEvents()
        if not QFontMetrics(window.font()).inFontUcs4(ord("A")):
            raise RuntimeError("Qt renderer has no readable Latin font; UI qualification cannot pass")
        assert window.session.enabled is False
        assert window.status.text() == "Camera off"
        window.grab().save(str(Path(output)/"packaged-camera-off.png"))
        window.nav_buttons[2].click()
        app.processEvents()
        assert window.pages.currentIndex() == 2
        window.grab().save(str(Path(output)/"packaged-settings.png"))
        # Stable Eastern noon keeps the UI fixture inside one day, even if
        # the runner happens to execute just after local midnight.
        from datetime import datetime
        from .progress import EASTERN
        clock = datetime(2026, 10, 26, 12, tzinfo=EASTERN).timestamp()
        window.progress_store.now = lambda: clock
        stamp = clock-3600
        for index in range(3601):
            window.progress_store.record("Green" if index<2800 else "Yellow" if index<3300 else "Red", stamp+index)
        window.nav_buttons[1].click()
        app.processEvents()
        assert window.pages.currentIndex() == 1 and window.progress_page.score.text() == "85 / 100"
        window.grab().save(str(Path(output)/"packaged-progress.png"))
        window.navigate(0)
        from .core import Calibration, Result
        window.session.settings.calibration = Calibration(.3, .4, .6)
        window.session.enabled = True
        window.session.result = Result("Yellow", score=82, deviation=.54, severity=1.3)
        import math
        end = time.monotonic()
        for index in range(301):
            value = 87+9*math.sin(index/18)
            point = Result("Finding you") if 110 < index < 150 else Result("Green" if value>=85 else "Yellow", score=value)
            window.chart.add(point, end-300+index)
        window.chart.add(window.session.result, end+.01)
        window.update_result()
        app.processEvents()
        window.grab().save(str(Path(output)/"packaged-posture.png"))
        window.progress_store.flush()
        from .progress import ProgressStore
        assert ProgressStore(window.progress_store.path, now=lambda: clock).day().tracked_seconds > 3599
        window.save_timer.stop()
        window.timer.stop()
        window.card.hide()
        window.hide()
        window.deleteLater()
        app.processEvents()


def main(argv=None):
    parser = argparse.ArgumentParser(description="Zone camera-free video and packaged-app qualification")
    parser.add_argument("--model", type=Path)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--widgets", action="store_true")
    args = parser.parse_args(argv)
    base = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent.parent))
    report = replay(args.model or base/"assets"/"face_landmarker.task", args.video, args.manifest, args.output)
    if args.widgets:
        check_widgets(args.output)
    print(json.dumps({"platform": report["platform"], "frozen": report["frozen"], "checks": report["checks"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
