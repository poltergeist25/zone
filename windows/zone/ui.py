"""Native Qt controls. The camera is deliberately never rendered."""
from collections import deque
import math
import time

from PySide6.QtCore import Qt, QTimer, QRectF, QPointF, QPropertyAnimation, QEasingCurve, Signal
from PySide6.QtGui import QColor, QPainter, QPen, QPainterPath, QPixmap, QIcon, QLinearGradient, QAction
from PySide6.QtWidgets import (QMainWindow, QWidget, QLabel, QPushButton, QVBoxLayout,
    QHBoxLayout, QStackedWidget, QSlider, QCheckBox, QComboBox, QSystemTrayIcon,
    QMenu, QFrame, QApplication)

from .core import Session, Result
from .sensor import CameraWorker, cameras
from .progress import ProgressStore
from .progress_view import ProgressPage

FOREST = "#203f32"
CREAM = "#f6f4eb"
COLORS = {"Green": "#408d66", "Yellow": "#c9851b", "Red": "#c8493d"}
MUTED = "#5b7062"


def ring_icon(color, tile=False):
    pix = QPixmap(128, 128)
    pix.fill(Qt.GlobalColor.transparent)
    p = QPainter(pix)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    if tile:
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QColor(FOREST))
        p.drawRoundedRect(QRectF(12, 12, 104, 104), 24, 24)
    p.setPen(QPen(QColor(color), 8 if tile else 11, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
    for i in range(12):
        angle = i*math.tau/12 - math.pi/2
        p.drawLine(QPointF(64+33*math.cos(angle), 64+33*math.sin(angle)),
                   QPointF(64+45*math.cos(angle), 64+45*math.sin(angle)))
    p.end()
    return QIcon(pix)


class Chart(QWidget):
    def __init__(self):
        super().__init__()
        self.points = deque()
        self.setMinimumHeight(330)
        self.setAccessibleName("Live score over the last five minutes")
        self.setAccessibleDescription("Colored readings are measured. Neutral dotted links span untracked time between readings.")

    def add(self, result, now):
        self.points.append((now, result.score, result.state))
        while self.points and self.points[0][0] < now-300:
            self.points.popleft()
        # The visible-window timer paints at 3Hz. Sensing keeps its own cadence;
        # a hidden chart neither paints nor runs an animation timer.

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        box = self.rect().adjusted(24, 24, -24, -38)
        p.setPen(QPen(QColor("#e2e7df"), 1, Qt.PenStyle.DashLine))
        for fraction in [0, .5, 1]:
            y = box.bottom()-fraction*box.height()
            p.drawLine(QPointF(box.left(), y), QPointF(box.right(), y))
        now = time.monotonic()
        while self.points and self.points[0][0] < now-300:
            self.points.popleft()
        previous = None
        interrupted = False
        for timestamp, score, zone in self.points:
            if score is None:
                interrupted = True
                continue
            point = QPointF(box.right()-(now-timestamp)/300*box.width(),
                            box.bottom()-score/100*box.height())
            if previous:
                gap = interrupted or timestamp-previous[0] > 1.5
                color = QColor(MUTED if gap else COLORS.get(zone, MUTED))
                color.setAlphaF(.4 if gap else .55+.45*min(1, max(0, 1-(now-timestamp)/300)))
                p.setPen(QPen(color, 1.2 if gap else 2.4,
                             Qt.PenStyle.DotLine if gap else Qt.PenStyle.SolidLine,
                             Qt.PenCapStyle.RoundCap))
                p.drawLine(previous[1], point)
            previous = (timestamp, point)
            interrupted = False
        if previous and self.points[-1][1] is not None:
            p.setPen(QPen(QColor("white"), 3))
            p.setBrush(QColor(COLORS.get(self.points[-1][2], MUTED)))
            p.drawEllipse(previous[1], 5, 5)
        p.setPen(QColor(MUTED))
        p.drawText(24, self.height()-12, "Last 5 minutes")
        p.drawText(self.width()-54, self.height()-12, "Now")


class BoundaryButton(QPushButton):
    adjusted = Signal(float)
    committed = Signal()

    def __init__(self, text, parent):
        super().__init__(text, parent)
        self.dragging = False
        self.setAccessibleName(text + " level. Use arrow keys or drag.")
        self.setCursor(Qt.CursorShape.SizeVerCursor)
        self.setStyleSheet("QPushButton { padding: 3px 6px; font-size: 11px; background: #fdfcf8; } QPushButton:focus { border: 1px solid #203f32; }")

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self.dragging = True
            self.setFocus()
            event.accept()

    def mouseMoveEvent(self, event):
        if self.dragging:
            self.adjusted.emit(self.mapToParent(event.position().toPoint()).y())

    def mouseReleaseEvent(self, event):
        if self.dragging:
            self.dragging = False
            self.committed.emit()
        super().mouseReleaseEvent(event)

    def focusOutEvent(self, event):
        if self.dragging:
            self.dragging = False
            self.committed.emit()
        super().focusOutEvent(event)

    def keyPressEvent(self, event):
        if event.key() in (Qt.Key.Key_Up, Qt.Key.Key_Left, Qt.Key.Key_Down, Qt.Key.Key_Right):
            step = -1 if event.key() in (Qt.Key.Key_Up, Qt.Key.Key_Left) else 1
            self.adjusted.emit(self.geometry().center().y()+step*max(1, (self.parent().height()-48)*.05))
            self.committed.emit()
        else:
            super().keyPressEvent(event)


class Meter(QWidget):
    level_changed = Signal(float, bool)
    committed = Signal()

    def __init__(self, session):
        super().__init__()
        self.session = session
        self.setMinimumHeight(280)
        self.setAccessibleName("Chosen height and yellow and red levels")
        self.boundaries = []
        for is_red, text in [(False, "Yellow starts here"), (True, "Red starts here")]:
            button = BoundaryButton(text, self)
            button.adjusted.connect(lambda y, red=is_red: self.level_changed.emit((y-24)/max(1, self.height()-48)*3, red))
            button.committed.connect(self.committed)
            self.boundaries.append(button)

    def refresh(self):
        settings = self.session.settings
        for button, value in zip(self.boundaries, [settings.yellow_threshold, settings.red_threshold]):
            button.setGeometry(54, round(24+(self.height()-48)*value/3)-13, max(1, self.width()-54), 26)
            button.setVisible(settings.calibration is not None)
            button.setEnabled(settings.calibration is not None and not self.session.calibrating)
            button.setAccessibleDescription(f"Level {value:.2f} on a scale from 0 to 3")
        self.update()

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.refresh()

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        x, top, height = 28, 24, self.height()-48
        p.setPen(Qt.PenStyle.NoPen)
        settings = self.session.settings
        for start, end, color in [(0, settings.yellow_threshold/3, "#b5d2bd"), (settings.yellow_threshold/3, settings.red_threshold/3, "#ead2a1"), (settings.red_threshold/3, 1, "#e6b3ab")]:
            p.setBrush(QColor(color))
            p.drawRect(QRectF(x, top+height*start, 18, height*(end-start)))
        p.setPen(QPen(QColor(FOREST), 1, Qt.PenStyle.DashLine))
        p.drawLine(QPointF(x-6, top), QPointF(x+26, top))
        p.setPen(QColor(FOREST))
        p.drawText(x+34, top+5, "Chosen height")
        p.setPen(QColor(FOREST))
        value = self.session.result.deviation
        if value is not None:
            p.setPen(QPen(QColor("white"), 4))
            p.setBrush(QColor(COLORS.get(self.session.result.state, MUTED)))
            p.drawEllipse(QPointF(x+9, top+height*min(.98, value/3)), 12, 12)


class Effect(QWidget):
    def __init__(self, screen):
        super().__init__(None, Qt.WindowType.Tool | Qt.WindowType.FramelessWindowHint
                         | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.WindowTransparentForInput
                         | Qt.WindowType.WindowDoesNotAcceptFocus)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setGeometry(screen.geometry())
        self.screen = screen
        screen.geometryChanged.connect(self.setGeometry)
        self.color = QColor(COLORS["Yellow"])
        self.depth = 0
        self.last_requested_depth = 0
        self.animation = QPropertyAnimation(self, b"windowOpacity", self)
        self.animation.setDuration(280)
        self.animation.setEasingCurve(QEasingCurve.Type.OutCubic)

    def display(self, result, strength):
        if result.state not in ("Yellow", "Red") or strength == 0:
            self.animation.stop()
            self.hide()
            return
        color = QColor(COLORS[result.state])
        depth = min(self.width()*.28, 8*strength*result.severity)
        changed = color != self.color or abs(depth-self.last_requested_depth) >= 2
        self.color, self.depth = color, depth
        if changed:
            self.last_requested_depth = depth
            self.update()
        if not self.isVisible():
            self.setWindowOpacity(0)
            self.show()
            self.animation.setStartValue(0)
            self.animation.setEndValue(1)
            self.animation.start()

    def paintEvent(self, event):
        p = QPainter(self)
        for left in [True, False]:
            edge = 0 if left else self.width()
            inner = self.depth if left else self.width()-self.depth
            gradient = QLinearGradient(edge, 0, inner, 0)
            for stop, alpha in [(0, 155), (.16, 95), (.5, 32), (1, 0)]:
                color = QColor(self.color)
                color.setAlpha(alpha)
                gradient.setColorAt(stop, color)
            p.fillRect(QRectF(0 if left else inner, 0, self.depth, self.height()), gradient)


class RedCard(QWidget):
    def __init__(self):
        super().__init__(None, Qt.WindowType.Tool | Qt.WindowType.FramelessWindowHint
                         | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.WindowDoesNotAcceptFocus
                         | Qt.WindowType.WindowTransparentForInput)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setObjectName("redCard")
        self.setFixedSize(520, 240)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(36, 32, 36, 32)
        title = QLabel("Come back to your zone.")
        title.setObjectName("cardTitle")
        title.setWordWrap(True)
        layout.addWidget(title)
        detail = QLabel("Lift back to your chosen height.")
        detail.setWordWrap(True)
        layout.addWidget(detail)
        self.animation = QPropertyAnimation(self, b"windowOpacity", self)
        self.animation.setDuration(220)

    def display(self, visible):
        if not visible:
            self.animation.stop()
            self.hide()
        elif not self.isVisible():
            available = QApplication.primaryScreen().availableGeometry()
            self.move(available.center()-self.rect().center())
            self.setWindowOpacity(0)
            self.show()
            self.animation.setStartValue(0)
            self.animation.setEndValue(1)
            self.animation.start()


STYLE = f"""
QWidget {{ color: {FOREST}; font-family: 'Segoe UI'; font-size: 14px; }}
QMainWindow, QWidget#root {{ background: {CREAM}; }}
QFrame#chartPanel {{ background: #fdfcf8; border-radius: 16px; }}
QFrame#heightPanel {{ background: #e1ecd9; border-radius: 16px; }}
QFrame#settingsPanel {{ background: #e1ecd9; border-radius: 16px; }}
QLabel#score {{ font-size: 56px; font-weight: 500; }}
QLabel#heading {{ font-size: 23px; font-weight: 600; }}
QLabel#status {{ font-size: 17px; font-weight: 600; }}
QLabel#footer {{ font-size: 11px; color: {MUTED}; }}
QPushButton {{ padding: 11px 16px; border: 1px solid #aab9aa; border-radius: 7px; background: #fdfcf8; }}
QPushButton:hover {{ background: #edf1e7; }}
QPushButton:focus {{ border: 2px solid {FOREST}; padding: 10px 15px; }}
QPushButton:disabled {{ color: #748276; border-color: #d2d9cd; background: #edf0e7; }}
QPushButton#primary {{ color: white; background: {FOREST}; border-color: {FOREST}; font-weight: 600; }}
QPushButton#primary:hover {{ background: #315743; }}
QPushButton#primary:disabled {{ background: #6c8270; }}
QPushButton#nav {{ background: transparent; border: none; border-radius: 0; padding: 8px 12px; }}
QPushButton#nav:checked {{ border-bottom: 2px solid {FOREST}; font-weight: 600; }}
QPushButton#nav:focus {{ outline: none; background: #e7ecdf; }}
QPushButton#day:checked {{ background: #e1ecd9; border-color: #203f32; }}
QComboBox {{ background: #fdfcf8; border: 1px solid #aab9aa; border-radius: 6px; padding: 8px; }}
QSlider {{ border: none; background: transparent; min-height: 24px; }}
QSlider::groove:horizontal {{ height: 5px; border: none; background: #c7d5c0; border-radius: 2px; }}
QSlider::sub-page:horizontal {{ border: none; background: {FOREST}; border-radius: 2px; }}
QSlider::add-page:horizontal {{ border: none; background: #c7d5c0; border-radius: 2px; }}
QSlider::handle:horizontal {{ width: 18px; margin: -7px 0; background: #fdfcf8; border: 1px solid #aab9aa; border-radius: 9px; }}
QSlider::handle:horizontal:focus {{ border: 2px solid {FOREST}; }}
QWidget#redCard {{ background: #f3d9d1; border: 1px solid #d09c91; border-radius: 16px; }}
QLabel#cardTitle {{ font-family: Georgia; font-size: 37px; }}
"""


class MainWindow(QMainWindow):
    def __init__(self, store, model_path, *, preview=False):
        super().__init__()
        self.store, self.model_path, self.preview = store, model_path, preview
        self.worker = None
        self.camera_items = []
        self.quitting = False
        self.error_text = ""
        self.tray_state = None
        self.update_pending = None
        self.setWindowTitle("Zone" + (" · Windows preview" if preview else ""))
        self.setWindowIcon(ring_icon(CREAM, True))
        self.resize(960, 690)
        self.setMinimumSize(900, 650)
        try:
            settings = store.load()
        except (OSError, ValueError, TypeError):
            from .core import Settings
            settings = Settings()
            store.preserve_unreadable()
            self.error_text = "Saved settings couldn’t be read. Camera remains off."
        self.session = Session(settings, store.save)
        self.progress_store = ProgressStore(store.path.with_name("daily-progress.json"))
        self.setStyleSheet(STYLE)
        self.root = QWidget()
        self.root.setObjectName("root")
        self.setCentralWidget(self.root)
        outer = QVBoxLayout(self.root)
        outer.setContentsMargins(28, 18, 28, 16)
        outer.setSpacing(20)
        nav = QHBoxLayout()
        nav.addStretch()
        self.nav_buttons = []
        for index, text in enumerate(["Posture", "Progress", "Settings"]):
            button = QPushButton(text)
            button.setObjectName("nav")
            button.setCheckable(True)
            button.clicked.connect(lambda checked=False, i=index: self.navigate(i))
            self.nav_buttons.append(button)
            nav.addWidget(button)
        nav.addStretch()
        self.camera_button = QPushButton("Camera off")
        self.camera_button.setAccessibleName("Camera on or off")
        self.camera_button.clicked.connect(self.toggle_camera)
        nav.addWidget(self.camera_button)
        outer.addLayout(nav)
        self.pages = QStackedWidget()
        outer.addWidget(self.pages, 1)
        self.make_posture()
        self.progress_page = ProgressPage(self.progress_store)
        self.pages.addWidget(self.progress_page)
        self.make_settings()
        self.notice = QLabel(self.error_text)
        self.notice.setWordWrap(True)
        outer.addWidget(self.notice)
        footer = QHBoxLayout()
        copyright = QLabel("© 2026 Gramercy Systems Inc")
        copyright.setObjectName("footer")
        footer.addWidget(copyright)
        footer.addStretch()
        privacy = QLabel("On this PC. Always private.")
        privacy.setObjectName("footer")
        footer.addWidget(privacy)
        outer.addLayout(footer)
        self.effects = [Effect(screen) for screen in QApplication.screens()] if not preview else []
        if not preview:
            QApplication.instance().screenAdded.connect(self.screen_added)
            QApplication.instance().screenRemoved.connect(self.screen_removed)
        self.card = RedCard()
        self.card.setStyleSheet(STYLE)
        self.tray = None
        if not preview and QSystemTrayIcon.isSystemTrayAvailable():
            self.tray = QSystemTrayIcon(ring_icon(MUTED), self)
            menu = QMenu()
            open_action = QAction("Open Zone", self)
            open_action.triggered.connect(self.open_controls)
            menu.addAction(open_action)
            menu.addSeparator()
            quit_action = QAction("Quit app", self)
            quit_action.triggered.connect(self.quit_app)
            menu.addAction(quit_action)
            self.tray.setContextMenu(menu)
            self.tray.activated.connect(lambda why: self.open_controls() if why == QSystemTrayIcon.ActivationReason.Trigger else None)
            self.tray.show()
        self.timer = QTimer(self)
        self.timer.setInterval(250)
        self.timer.timeout.connect(self.check_stale)
        self.visible_timer = QTimer(self)
        self.visible_timer.setInterval(333)
        self.visible_timer.timeout.connect(self.refresh_visible)
        self.last_progress_refresh = 0
        self.navigate(0)
        self.update_result()

    def make_posture(self):
        page = QWidget()
        layout = QHBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(20)
        panel = QFrame()
        panel.setObjectName("chartPanel")
        left = QVBoxLayout(panel)
        left.setContentsMargins(24, 24, 24, 18)
        header = QHBoxLayout()
        heading = QLabel("Live score")
        heading.setObjectName("heading")
        header.addWidget(heading)
        header.addStretch()
        self.score = QLabel("—")
        self.score.setObjectName("score")
        header.addWidget(self.score)
        left.addLayout(header)
        self.chart = Chart()
        left.addWidget(self.chart, 1)
        layout.addWidget(panel, 3)
        panel = QFrame()
        panel.setObjectName("heightPanel")
        panel.setMaximumWidth(250)
        right = QVBoxLayout(panel)
        right.setContentsMargins(20, 24, 20, 20)
        right.setSpacing(14)
        self.status = QLabel("Camera off")
        self.status.setObjectName("status")
        self.status.setWordWrap(True)
        right.addWidget(self.status)
        self.meter = Meter(self.session)
        self.meter.level_changed.connect(self.boundary_changed)
        self.meter.committed.connect(self.commit_settings)
        right.addWidget(self.meter, 1)
        self.pause = QPushButton("Pause")
        self.pause.setObjectName("primary")
        self.pause.clicked.connect(self.toggle_pause)
        self.height = QPushButton("Set my height")
        self.height.clicked.connect(self.set_height)
        right.addWidget(self.pause)
        right.addWidget(self.height)
        self.camera_choice = QComboBox()
        self.camera_choice.setAccessibleName("Camera")
        self.camera_choice.addItem("Choose camera")
        self.camera_choice.activated.connect(self.choose_camera)
        right.addWidget(self.camera_choice)
        self.refresh = QPushButton("Find cameras")
        self.refresh.clicked.connect(self.refresh_cameras)
        right.addWidget(self.refresh)
        layout.addWidget(panel, 1)
        self.pages.addWidget(page)

    def make_settings(self):
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(40, 12, 40, 0)
        heading = QLabel("Settings")
        heading.setObjectName("heading")
        layout.addWidget(heading)
        panel = QFrame()
        panel.setObjectName("settingsPanel")
        inner = QVBoxLayout(panel)
        inner.setContentsMargins(28, 28, 28, 28)
        inner.setSpacing(24)
        self.sliders = {}
        self.slider_labels = {}
        for key, title, low, high, value, labels in [
            ("forgiveness", "Forgiveness", 0, 100, round(50+50*math.log2(self.session.settings.yellow_threshold/.45)), ("Strict", "Default", "Forgiving")),
            ("delay", "Red alert delay", 10, 50, round(self.session.settings.delay*10), ("1 second", "Default · 2 seconds", "5 seconds")),
            ("strength", "Effect strength", 0, 100, round(self.session.settings.strength*10), ("0×", "Default · 8×", "10×"))]:
            row = QHBoxLayout()
            row.addWidget(QLabel(title))
            row.addStretch()
            value_label = QLabel("")
            self.slider_labels[key] = value_label
            row.addWidget(value_label)
            if key == "delay":
                self.red_enabled = QCheckBox("On")
                self.red_enabled.setAccessibleName("Red alert enabled")
                self.red_enabled.setChecked(self.session.settings.red_alert)
                self.red_enabled.toggled.connect(self.alert_changed)
                row.addWidget(self.red_enabled)
            inner.addLayout(row)
            slider = QSlider(Qt.Orientation.Horizontal)
            slider.setAccessibleName(title)
            slider.setRange(low, high)
            slider.setValue(value)
            slider.valueChanged.connect(lambda v, k=key: self.setting_changed(k, v, False))
            slider.sliderReleased.connect(lambda k=key: self.finish_slider(k))
            # Keyboard changes are also committed after a short quiet period.
            self.sliders[key] = slider
            inner.addWidget(slider)
            captions = QHBoxLayout()
            for i, text in enumerate(labels):
                if i:
                    captions.addStretch()
                captions.addWidget(QLabel(text))
            inner.addLayout(captions)
        self.save_timer = QTimer(self)
        self.save_timer.setSingleShot(True)
        self.save_timer.setInterval(350)
        self.save_timer.timeout.connect(self.commit_settings)
        layout.addWidget(panel)
        layout.addStretch()
        quit_button = QPushButton("Quit app")
        quit_button.setObjectName("primary")
        quit_button.clicked.connect(self.quit_app)
        layout.addWidget(quit_button)
        self.pages.addWidget(page)
        self.refresh_setting_labels()

    def navigate(self, index):
        self.pages.setCurrentIndex(index)
        for i, button in enumerate(self.nav_buttons):
            button.setChecked(i == index)
        if index == 1:
            self.progress_page.refresh()

    def refresh_setting_labels(self):
        s = self.session.settings
        # Capture restores anatomical defaults. Keep the actual slider in sync
        # without firing valueChanged or making a second persistence write.
        values = {"forgiveness": round(50+50*math.log2(s.yellow_threshold/.45)),
                  "delay": round(s.delay*10), "strength": round(s.strength*10)}
        for key, value in values.items():
            slider = self.sliders[key]
            if not slider.isSliderDown() and slider.value() != value:
                blocked = slider.blockSignals(True)
                slider.setValue(value)
                slider.blockSignals(blocked)
        default = abs(s.yellow_threshold-.45)<.001 and abs(s.red_threshold-.85)<.001
        self.slider_labels["forgiveness"].setText("Default" if default else "Custom" if s.yellow is not None else f"{s.forgiveness:.2f}×")
        self.slider_labels["delay"].setText(f"{s.delay:.1f} seconds")
        self.slider_labels["strength"].setText(f"{s.strength:.1f}×")

    def setting_changed(self, key, value, save=True):
        if key == "forgiveness":
            # Middle is exactly the anatomical defaults.
            mapped = 2**((value-50)/50)
            self.session.settings.set_forgiveness(mapped)
            self.session.levels_changed()
            self.progress_store.record("Untracked", time.time(), eligible=False)
        else:
            mapped = value/10
            setattr(self.session.settings, key, mapped)
            if key == "delay":
                self.session.levels_changed()
        self.refresh_setting_labels()
        self.save_timer.start()
        self.update_result()

    def boundary_changed(self, value, is_red):
        self.session.settings.set_boundary(value, is_red)
        self.session.levels_changed()
        self.progress_store.record("Untracked", time.time(), eligible=False)
        self.save_timer.start()
        self.refresh_setting_labels()
        self.update_result()

    def finish_slider(self, key):
        # Releasing at the middle also restores defaults when only the red
        # boundary was dragged and the slider already displayed its midpoint.
        if key == "forgiveness":
            self.setting_changed(key, self.sliders[key].value())
        self.commit_settings()

    def alert_changed(self, enabled):
        self.session.settings.red_alert = enabled
        self.commit_settings()
        self.update_result()

    def commit_settings(self):
        self.save_timer.stop()
        self.refresh_setting_labels()
        try:
            self.session.settings.remember_camera()
            self.store.save(self.session.settings)
            return True
        except (OSError, ValueError) as exc:
            self.notice.setText(f"Couldn’t save settings: {exc}")
            return False

    def refresh_cameras(self):
        if self.worker is not None or self.preview:
            return
        try:
            self.camera_items = cameras()
            self.camera_choice.clear()
            self.camera_choice.addItem("Choose camera")
            for info in self.camera_items:
                self.camera_choice.addItem(info.name)
                if info.path == self.session.settings.camera:
                    self.camera_choice.setCurrentIndex(self.camera_choice.count()-1)
            self.notice.setText("Choose a camera." if self.camera_items else "No camera found. Check Windows camera permissions.")
        except Exception as exc:
            self.notice.setText(str(exc))

    def choose_camera(self, index):
        if index > 0 and self.worker is None:
            path = self.camera_items[index-1].path
            if path != self.session.settings.camera:
                candidate = self.session.settings.for_camera(path)
                try:
                    self.store.save(candidate)
                except (OSError, ValueError) as exc:
                    self.notice.setText(f"Couldn’t switch camera: {exc}")
                    return
                self.session.settings = candidate
                self.session.stop()
                self.update_result()

    def toggle_camera(self):
        if self.worker is not None:
            self.stop_camera()
        else:
            self.start_camera()

    def start_camera(self):
        if self.worker is not None or self.preview:
            return
        index = self.camera_choice.currentIndex()-1
        if index < 0 or index >= len(self.camera_items):
            self.refresh_cameras()
            self.notice.setText("Choose your camera, then turn Camera on.")
            return
        info = self.camera_items[index]
        if info.path != self.session.settings.camera:
            self.choose_camera(index+1)
            if info.path != self.session.settings.camera:
                return
        self.session.start()
        self.worker = CameraWorker(info.path, self.model_path)
        worker = self.worker
        worker.observed.connect(lambda faces, now: self.receive(worker, faces, now))
        worker.failed.connect(lambda error: self.camera_failed(worker, error))
        worker.finished.connect(lambda: self.worker_finished(worker))
        worker.start()
        self.timer.start()
        self.notice.clear()
        self.camera_choice.setEnabled(False)
        self.refresh.setEnabled(False)
        self.update_result()

    def stop_camera(self, paused=False):
        self.session.stop(paused)
        self.interrupt_history()
        if self.worker:
            self.worker.requestInterruption()
        self.timer.stop()
        self.update_result()

    def interrupt_history(self):
        self.progress_store.record("Untracked", time.time(), eligible=False)
        self.progress_store.flush()
        self.chart.add(self.session.result, time.monotonic())

    def worker_finished(self, worker):
        if self.worker is not worker:
            return
        self.worker = None
        worker.deleteLater()
        if self.session.enabled:
            self.session.stop()
            self.interrupt_history()
        self.timer.stop()
        self.camera_choice.setEnabled(True)
        self.refresh.setEnabled(True)
        self.update_result()
        if self.quitting:
            if self.update_pending:
                self.finish_update()
            else:
                QApplication.quit()

    def camera_failed(self, worker, error):
        if self.worker is worker:
            self.session.stop()
            self.interrupt_history()
            self.notice.setText(error)
            self.update_result()

    def toggle_pause(self):
        if self.session.paused:
            self.start_camera()
        elif self.session.enabled:
            self.stop_camera(True)

    def set_height(self):
        self.progress_store.record("Untracked", time.time(), eligible=False)
        if self.session.calibrating:
            self.session.cancel_calibration()
        else:
            self.session.calibrate()
        self.update_result()

    def receive(self, worker, faces, now):
        if self.worker is worker and self.session.enabled:
            if time.monotonic()-now > .75:
                self.session.watchdog(time.monotonic())
                self.interrupt_history()
                self.update_result()
                return
            result = self.session.tick(faces, now)
            self.progress_store.record(result.state, time.time()-(time.monotonic()-now), eligible=result.score is not None and not self.session.calibrating)
            self.chart.add(result, now)
            self.update_result()

    def check_stale(self):
        before = self.session.result
        result = self.session.watchdog(time.monotonic())
        if result != before:
            self.progress_store.record("Untracked", time.time(), eligible=False)
            self.chart.add(result, time.monotonic())
            self.update_result()

    def update_result(self):
        r = self.session.result
        if self.isVisible() or self.preview:
            self.refresh_controls()
        for effect in self.effects:
            effect.display(r, self.session.settings.strength)
        self.card.display(r.alert and self.session.settings.red_alert)
        if self.tray and self.tray_state != r.state:
            self.tray_state = r.state
            self.tray.setIcon(ring_icon(COLORS.get(r.state, MUTED)))
            self.tray.setToolTip(f"Zone · {r.state}")

    def refresh_controls(self):
        r = self.session.result
        self.status.setText(f"Hold still · {r.progress:.0%}" if self.session.calibrating else r.state)
        self.score.setText("—" if r.score is None else str(round(r.score)))
        self.chart.setAccessibleDescription(f"{r.state}. " + (f"Current score {round(r.score)} out of 100. " if r.score is not None else "No current measured score. ") + "Neutral dotted links span untracked time between readings.")
        self.height.setText("Try again" if self.session.capture_error else "Go back" if self.session.calibrating else "Reset height" if self.session.settings.calibration else "Set my height")
        self.height.setEnabled(self.session.enabled)
        self.pause.setText("Resume" if self.session.paused else "Pause")
        self.pause.setEnabled(self.session.enabled or self.session.paused and self.worker is None)
        self.camera_button.setText("Camera on" if self.session.enabled else "Camera off")
        self.camera_button.setEnabled(self.worker is None or self.session.enabled)
        self.meter.refresh()
        self.refresh_setting_labels()
        if self.preview:
            self.chart.update()

    def screen_added(self, screen):
        self.effects.append(Effect(screen))
        self.update_result()

    def screen_removed(self, screen):
        for effect in list(self.effects):
            if effect.screen is screen:
                effect.hide()
                effect.deleteLater()
                self.effects.remove(effect)

    def refresh_visible(self):
        self.chart.update()
        if self.pages.currentIndex() == 1 and time.monotonic()-self.last_progress_refresh >= 1:
            self.progress_page.refresh()
            self.last_progress_refresh = time.monotonic()

    def showEvent(self, event):
        super().showEvent(event)
        self.visible_timer.start()
        self.refresh_controls()

    def hideEvent(self, event):
        self.visible_timer.stop()
        self.progress_store.flush()
        super().hideEvent(event)

    def open_controls(self):
        self.showNormal()
        self.raise_()
        self.activateWindow()
        self.update_result()

    def system_interrupted(self, reason):
        self.stop_camera()
        self.notice.setText(f"{reason}. Camera off; turn Camera on when you’re ready.")

    def prepare_update(self, target_hash, acknowledge):
        if self.quitting or not self.commit_settings():
            acknowledge(False)
            return
        self.update_pending = (target_hash, acknowledge, {
            "camera": self.session.settings.camera,
            "mode": "active" if self.session.enabled and self.session.settings.calibration else "paused" if self.session.paused else "off",
            "page": self.pages.currentIndex(), "visible": self.isVisible()})
        self.quitting = True
        self.stop_camera()
        if self.worker is None:
            self.finish_update()

    def finish_update(self):
        from .update import write_handoff
        target, acknowledge, state = self.update_pending
        self.update_pending = None
        try:
            if not self.progress_store.flush():
                raise OSError(self.progress_store.error_message or "Couldn’t save progress")
            write_handoff(self.store.path.parent, target, **state)
        except (OSError, ValueError) as exc:
            self.quitting = False
            self.notice.setText(f"Update stopped: {exc}")
            acknowledge(False)
            return
        acknowledge(True)
        # Let the local pipe deliver its acknowledgement before releasing the owner.
        QTimer.singleShot(300, QApplication.quit)

    def resume_update(self, state):
        self.navigate(state["page"])
        self.refresh_cameras()
        same_camera = state["camera"] == self.session.settings.camera
        if state["mode"] == "active" and same_camera and self.session.settings.calibration:
            self.start_camera()
        elif state["mode"] == "paused" and same_camera:
            self.session.stop(paused=True)
            self.update_result()
        if state["visible"] or not self.tray:
            self.open_controls()
        else:
            self.hide()

    def closeEvent(self, event):
        if self.tray and not self.quitting:
            self.hide()
            event.ignore()
        else:
            self.quit_app()
            event.ignore()

    def quit_app(self):
        self.quitting = True
        self.commit_settings()
        self.progress_store.flush()
        self.stop_camera()
        self.hide()
        if self.tray:
            self.tray.hide()
        if self.worker is None:
            QApplication.quit()
