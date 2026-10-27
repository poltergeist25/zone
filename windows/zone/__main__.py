import os
from pathlib import Path
import platform
import sys


def main():
    # Prevent this Windows candidate from borrowing the live Mac's camera.
    if platform.system() != "Windows":
        raise SystemExit("Zone Windows runs on Windows. Use tests/render_ui.py for a camera-free UI preview.")
    from PySide6.QtWidgets import QApplication
    from PySide6.QtCore import QTimer
    from .core import Store
    from .ui import MainWindow
    from .lifecycle import InstanceGuard, WindowsSessionEvents
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    base = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent.parent))
    profile = Path(os.environ["LOCALAPPDATA"])/"Gramercy Systems"/"Zone Windows"
    if "--prepare-update" in sys.argv:
        from .update import process_alive
        import json
        import time
        position = sys.argv.index("--prepare-update")
        if position+1 >= len(sys.argv):
            return 2
        guard = InstanceGuard(profile, lambda: None)
        if not guard.request_update(sys.argv[position+1]):
            return 10  # no running owner; an ordinary install must not auto-resume
        handoff = json.loads((profile/"update-handoff.json").read_text(encoding="utf-8"))
        deadline = time.monotonic()+10
        while process_alive(handoff["old_pid"]):
            if time.monotonic() >= deadline:
                return 3
            time.sleep(.05)
        return 0
    guard = InstanceGuard(profile, lambda: window.open_controls(), app,
                          prepare_update=lambda target, ack: window.prepare_update(target, ack))
    if not guard.start_or_activate():
        return 0
    window = MainWindow(Store(profile/"settings.json"), base/"assets"/"face_landmarker.task")
    events = WindowsSessionEvents(app, int(window.winId()), window.system_interrupted)
    app.aboutToQuit.connect(events.close)
    app.aboutToQuit.connect(guard.close)
    app.aboutToQuit.connect(window.progress_store.flush)
    state = None
    if "--resume-update" in sys.argv:
        from .update import consume_handoff
        try:
            state = consume_handoff(profile, sys.executable)
        except (OSError, ValueError) as exc:
            window.notice.setText(str(exc))
    if state:
        QTimer.singleShot(0, lambda: window.resume_update(state))
    else:
        window.show()
        QTimer.singleShot(0, window.refresh_cameras)
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
