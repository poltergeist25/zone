"""Daily balance and week navigation; no polling while controls are hidden."""
from datetime import date, timedelta
import time

from PySide6.QtCore import Qt, QRectF
from PySide6.QtGui import QColor, QPainter, QPen
from PySide6.QtWidgets import QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton, QFrame

from .progress import date_id, week_dates

FOREST = "#203f32"
MUTED = "#5b7062"
COLORS = ["#408d66", "#c9851b", "#c8493d"]


def duration(seconds):
    if 0 < seconds < 1:
        return "<1s"
    seconds = int(max(0, seconds))
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        minutes, remainder = divmod(seconds, 60)
        return f"{minutes}m" + (f" {remainder}s" if remainder else "")
    hours, minutes = seconds//3600, seconds%3600//60
    return f"{hours}h" + (f" {minutes}m" if minutes else "")


class BalanceRing(QWidget):
    def __init__(self):
        super().__init__()
        self.day = None
        self.setFixedSize(170, 170)

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        box = QRectF(15, 15, 140, 140)
        p.setPen(QPen(QColor("#e2e7df"), 13))
        p.drawEllipse(box)
        day = self.day
        total = day.tracked_seconds if day else 0
        angle = 90*16
        if total:
            for seconds, color in zip([day.green_seconds, day.yellow_seconds, day.red_seconds], COLORS):
                arc = seconds/total*360*16
                p.setPen(QPen(QColor(color), 13))
                p.drawArc(box, round(angle), -round(arc))
                angle -= arc
        p.setPen(QColor(FOREST))
        font = p.font()
        font.setPointSize(24)
        p.setFont(font)
        p.drawText(QRectF(20, 55, 130, 40), Qt.AlignmentFlag.AlignCenter, duration(total) if total else "—")
        font.setPointSize(10)
        p.setFont(font)
        p.setPen(QColor(MUTED))
        p.drawText(QRectF(20, 96, 130, 24), Qt.AlignmentFlag.AlignCenter, "tracked")


class ProgressPage(QWidget):
    def __init__(self, store):
        super().__init__()
        self.store = store
        self.offset = 0
        self.selected = None
        layout = QVBoxLayout(self)
        layout.setContentsMargins(32, 12, 32, 18)
        layout.setSpacing(16)
        head = QHBoxLayout()
        titles = QVBoxLayout()
        heading = QLabel("Progress")
        heading.setObjectName("heading")
        titles.addWidget(heading)
        self.date_label = QLabel("Today")
        titles.addWidget(self.date_label)
        head.addLayout(titles)
        head.addStretch()
        numbers = QVBoxLayout()
        self.score = QLabel("— / 100")
        self.score.setObjectName("score")
        self.score.setStyleSheet("font-size: 42px; font-weight: 500;")
        numbers.addWidget(self.score, alignment=Qt.AlignmentFlag.AlignRight)
        numbers.addWidget(QLabel("Daily score"), alignment=Qt.AlignmentFlag.AlignRight)
        head.addLayout(numbers)
        layout.addLayout(head)
        panel = QFrame()
        panel.setObjectName("chartPanel")
        balance = QHBoxLayout(panel)
        balance.setContentsMargins(24, 14, 24, 14)
        balance.setSpacing(36)
        balance.addStretch()
        self.ring = BalanceRing()
        balance.addWidget(self.ring)
        rows = QVBoxLayout()
        rows.setSpacing(18)
        self.rows = []
        for label, color in zip(["Green", "Yellow", "Red"], COLORS):
            row = QHBoxLayout()
            row.setSpacing(14)
            name = QLabel(label)
            name.setStyleSheet(f"color: {color}; font-weight: 600;")
            name.setMinimumWidth(66)
            row.addWidget(name)
            minutes = QLabel("—")
            minutes.setMinimumWidth(80)
            row.addWidget(minutes)
            percent = QLabel("—")
            percent.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
            percent.setMinimumWidth(44)
            row.addWidget(percent)
            rows.addLayout(row)
            self.rows.append((minutes, percent))
        balance.addLayout(rows)
        balance.addStretch()
        layout.addWidget(panel)
        weeks = QHBoxLayout()
        previous = QPushButton("Previous week")
        previous.clicked.connect(lambda: self.move_week(-1))
        weeks.addWidget(previous)
        self.week_label = QLabel()
        weeks.addWidget(self.week_label)
        self.next = QPushButton("Next week")
        self.next.clicked.connect(lambda: self.move_week(1))
        weeks.addWidget(self.next)
        weeks.addStretch()
        self.today = QPushButton("Today")
        self.today.clicked.connect(self.select_today)
        weeks.addWidget(self.today)
        layout.addLayout(weeks)
        days = QHBoxLayout()
        days.setSpacing(10)
        self.days = []
        for i in range(7):
            button = QPushButton()
            button.setObjectName("day")
            button.setCheckable(True)
            button.clicked.connect(lambda checked=False, index=i: self.select_day(index))
            self.days.append(button)
            days.addWidget(button, 1)
        layout.addLayout(days)
        self.error = QLabel()
        self.error.setWordWrap(True)
        layout.addWidget(self.error)
        layout.addStretch()
        footer = QLabel("Score uses tracked time only. Pauses and time away are excluded.")
        footer.setObjectName("footer")
        layout.addWidget(footer)
        self.refresh()

    def refresh(self):
        now = self.store.now()
        today = date_id(now)
        selected = self.selected or today
        day = self.store.day(selected)
        self.date_label.setText("Today" if selected == today else date.fromisoformat(selected).strftime("%A, %b %d"))
        self.score.setText((str(round(day.score)) if day.score is not None else "—") + " / 100")
        self.score.setAccessibleName("Daily score " + self.score.text())
        self.ring.day = day
        self.ring.setAccessibleName(duration(day.tracked_seconds) + " total tracked time" if day.tracked_seconds else "No tracked time yet")
        self.ring.update()
        for (minutes, percent), seconds in zip(self.rows, [day.green_seconds, day.yellow_seconds, day.red_seconds]):
            minutes.setText(duration(seconds) if day.tracked_seconds else "—")
            percent.setText(f"{round(seconds/day.tracked_seconds*100)}%" if day.tracked_seconds else "—")
        week = week_dates(now, self.offset)
        first, last = date.fromisoformat(week[0]), date.fromisoformat(week[-1])
        self.week_label.setText(first.strftime("%b %d")+" – "+last.strftime("%b %d, %Y"))
        for button, day_id in zip(self.days, week):
            summary = self.store.day(day_id)
            caption = date.fromisoformat(day_id).strftime("%a")
            score = str(round(summary.score)) if summary.score is not None else "—"
            button.setText(caption+"\n"+score)
            button.setChecked(day_id == selected)
            button.setEnabled(day_id <= today)
            button.setAccessibleName(f"{day_id}, score {score}")
            button.setToolTip(duration(summary.tracked_seconds)+" tracked" if summary.tracked_seconds else "No tracked time")
        self.next.setEnabled(self.offset < 0)
        self.today.setEnabled(self.offset != 0 or self.selected is not None)
        self.error.setText(self.store.error_message or "")
        self.error.setVisible(bool(self.store.error_message))

    def select_day(self, index):
        self.selected = week_dates(self.store.now(), self.offset)[index]
        self.refresh()

    def select_today(self):
        self.offset, self.selected = 0, None
        self.refresh()

    def move_week(self, offset):
        self.offset = min(0, self.offset+offset)
        week = week_dates(self.store.now(), self.offset)
        self.selected = next((key for key in reversed(week) if self.store.day(key).tracked_seconds), week[0])
        self.refresh()
