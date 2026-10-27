"""Render synthetic states without a camera, model inference, tray or live profile."""
import argparse
from pathlib import Path
import tempfile
import time

from PySide6.QtWidgets import QApplication
from zone.core import Store, Calibration, Result
from zone.ui import MainWindow


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    app = QApplication([])
    with tempfile.TemporaryDirectory() as tmp:
        window = MainWindow(Store(Path(tmp)/"settings.json"), Path(tmp)/"unused.task", preview=True)
        window.show()
        app.processEvents()
        window.grab().save(str(args.output/"camera-off.png"))
        window.session.settings.calibration = Calibration(.3, .4, .6)
        now = time.monotonic()
        for i in range(301):
            score = 85+10*__import__('math').sin(i/15)
            if 110 < i < 150:
                result = Result("Finding you")
            else:
                result = Result("Green" if score > 85 else "Yellow", score=score)
            window.chart.add(result, now-300+i)
        window.session.enabled = True
        window.session.result = Result("Yellow", score=82, deviation=.54, severity=1.3)
        window.chart.add(window.session.result, now+.2)
        window.update_result()
        app.processEvents()
        window.grab().save(str(args.output/"posture-yellow.png"))
        window.navigate(2)
        app.processEvents()
        window.grab().save(str(args.output/"settings.png"))
        stamp = time.time()-3600
        for i in range(3601):
            window.progress_store.record("Green" if i<2800 else "Yellow" if i<3300 else "Red", stamp+i)
        window.navigate(1)
        app.processEvents()
        window.grab().save(str(args.output/"progress.png"))
        # Camera-free render of the actual focus card widget.
        window.card.setWindowOpacity(1)
        window.card.show()
        app.processEvents()
        window.card.grab().save(str(args.output/"red-card.png"))
        window.card.hide()
        window.navigate(0)
        window.session.capture_error = True
        window.session.result = Result("Couldn’t save height. Try again.")
        window.update_result()
        app.processEvents()
        window.grab().save(str(args.output/"save-error.png"))
        window.hide()
        print("Five synthetic native Qt renders; host platform is not Windows.")


if __name__ == "__main__":
    main()
