"""Camera-independent behavior. Image positions are normalized, top down.

This ports Zone's nose/eye crossing rule, not its Apple Vision implementation.
Face geometry is ephemeral association evidence, never biometric identity proof.
"""
from dataclasses import dataclass, asdict, field, replace
import json
import math
import os
from pathlib import Path
import statistics
import tempfile


@dataclass(frozen=True)
class Face:
    x: float
    y: float
    width: float
    height: float
    eyes: float
    nose: float
    chin: float

    @property
    def valid(self):
        return (all(math.isfinite(v) for v in asdict(self).values())
                and .04 < self.width < 1 and .07 < self.height < 1
                and 0 <= self.x <= 1 and 0 <= self.y <= 1
                and 0 <= self.eyes < self.nose < self.chin <= 1
                and self.nose - self.eyes > .003)

    @property
    def signature(self):
        return (self.chin - self.eyes) / self.height


@dataclass(frozen=True)
class Calibration:
    eyes: float
    nose: float
    chin: float

    @property
    def valid(self):
        return (all(math.isfinite(v) for v in asdict(self).values())
                and 0 <= self.eyes < self.nose < self.chin <= 1
                and self.nose - self.eyes > .003)

    @property
    def line(self):
        return self.nose + (self.chin - self.nose) / 3

    def deviation(self, face):
        position = (face.nose - self.line) / (face.nose - face.eyes)
        neutral = (self.nose - self.line) / (self.nose - self.eyes)
        return max(0, .45 * (position - neutral) / -neutral if position < 0
                   else .45 + position * .40)


@dataclass
class Settings:
    camera: str = ""
    calibration: Calibration | None = None
    forgiveness: float = 1
    delay: float = 2
    strength: float = 8
    red_alert: bool = True
    yellow: float | None = None
    red: float | None = None
    calibrations: dict = field(default_factory=dict)

    @property
    def yellow_threshold(self):
        return self.yellow if self.yellow is not None else .45*self.forgiveness

    @property
    def red_threshold(self):
        return self.red if self.red is not None else .85*self.forgiveness

    def set_forgiveness(self, value):
        self.forgiveness = min(2, max(.5, value))
        self.yellow = self.red = None

    def set_boundary(self, value, is_red):
        if not math.isfinite(value):
            return
        yellow, red = self.yellow_threshold, self.red_threshold
        if is_red:
            red = max(yellow*1.25, yellow+.15, min(3, value))
        else:
            yellow = max(.15, min(value, red/1.25, red-.15))
        self.yellow, self.red = yellow, red

    def remember_camera(self):
        if self.camera:
            self.calibrations = {**self.calibrations, self.camera: {
                "calibration": asdict(self.calibration) if self.calibration else None,
                "forgiveness": self.forgiveness, "yellow": self.yellow, "red": self.red}}

    def for_camera(self, camera):
        candidate = replace(self, calibrations=dict(self.calibrations))
        candidate.remember_camera()
        saved = candidate.calibrations.get(camera, {})
        candidate.camera = camera
        candidate.calibration = Calibration(**saved["calibration"]) if saved.get("calibration") else None
        candidate.forgiveness = saved.get("forgiveness", 1)
        candidate.yellow, candidate.red = saved.get("yellow"), saved.get("red")
        candidate.validate()
        return candidate

    def validate(self):
        if not isinstance(self.camera, str) or not isinstance(self.red_alert, bool):
            raise ValueError("Invalid camera or alert preference")
        for v, low, high in [(self.forgiveness, .5, 2), (self.delay, 1, 5),
                             (self.strength, 0, 10)]:
            if isinstance(v, bool) or not isinstance(v, (float, int)) or not math.isfinite(v) or not low <= v <= high:
                raise ValueError("Invalid preference range")
        if self.calibration is not None and not self.calibration.valid:
            raise ValueError("Invalid saved height")
        y, r = self.yellow_threshold, self.red_threshold
        if not all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) for v in (y, r)) or not (.15 <= y and r >= max(y*1.25, y+.15) and r <= 3):
            raise ValueError("Invalid yellow or red boundary")
        if not isinstance(self.calibrations, dict):
            raise ValueError("Invalid camera heights")
        for key, record in self.calibrations.items():
            if not isinstance(key, str) or not key or not isinstance(record, dict):
                raise ValueError("Invalid camera height")
            baseline = record.get("calibration")
            Settings(camera=key, calibration=Calibration(**baseline) if baseline else None,
                     forgiveness=record.get("forgiveness", 1), yellow=record.get("yellow"),
                     red=record.get("red")).validate()


class Store:
    def __init__(self, path):
        self.path = Path(path)
        self.write_blocked = False

    def preserve_unreadable(self):
        from uuid import uuid4
        if self.path.exists():
            try:
                self.path.rename(self.path.with_name(self.path.name+".unreadable-"+str(uuid4())))
            except OSError:
                self.write_blocked = True

    def load(self):
        if not self.path.exists():
            return Settings()
        data = json.loads(self.path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("Saved settings must contain an object")
        if data.pop("schema", None) not in (1, 2):
            raise ValueError("Unsupported settings version")
        if data.get("calibration") is not None:
            data["calibration"] = Calibration(**data["calibration"])
        result = Settings(**data)
        result.validate()
        return result

    def save(self, settings):
        if self.write_blocked:
            raise OSError("Unreadable settings were preserved and cannot be overwritten")
        settings.validate()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix=".zone-", dir=self.path.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump({"schema": 2, **asdict(settings)}, f, allow_nan=False)
                f.flush()
                os.fsync(f.fileno())
            os.replace(name, self.path)
        finally:
            if os.path.exists(name):
                os.unlink(name)


class Association:
    def __init__(self):
        self.anchor = None
        self.last = None
        self.missing = False
        self.loss = "unknown"
        self.recent = []

    def select(self, faces, now):
        faces = [f for f in faces if f.valid]
        if self.anchor is None:
            # Explicit calibration can reset this session association. An
            # ambiguous first frame must never choose whichever face is larger.
            eligible = [f for f in faces if abs(f.x - .5) <= .3 and .1 <= f.y <= .9]
            if len(eligible) != 1:
                return None, "ambiguous" if eligible else "unknown"
            selected = eligible[0]
            self.anchor = selected
        else:
            candidates = []
            for f in faces:
                signature = abs(f.signature - self.anchor.signature)
                if signature > .22:
                    continue
                references = [self.last] + ([self.anchor] if self.missing else [])
                costs = []
                for r in references:
                    if r is None:
                        continue
                    dx, dy = abs(f.x-r.x), abs(f.y-r.y)
                    if (.55 <= f.width/r.width <= 1.8 and .55 <= f.height/r.height <= 1.8
                            and dx <= min(.16, max(.065, r.width*.65))
                            and dy <= max(.12, r.height*.85)):
                        costs.append(dx + dy*.5 + signature)
                if costs:
                    candidates.append((min(costs), f))
            candidates.sort(key=lambda item: item[0])
            if len(candidates) > 1 and candidates[1][0] - candidates[0][0] < .12:
                self.missing = True
                self.loss = "ambiguous"
                return None, self.loss
            if not candidates:
                self.missing = True
                # Only a recently observed directional trajectory may initiate
                # a bottom hold. A timeout alone is not bottom-exit evidence.
                if self.loss == "unknown" and self.last is not None and self.recent:
                    old_time, old = self.recent[0]
                    fresh = 0 <= now-self.recent[-1][0] <= .65
                    side = self.last.x-self.last.width/2 < .06 or self.last.x+self.last.width/2 > .94
                    if fresh and side:
                        self.loss = "side"
                    elif (fresh and self.last.chin > .96 and self.last.y-old.y > .025
                          and now-old_time <= 1.5):
                        self.loss = "bottom"
                return None, self.loss
            selected = candidates[0][1]
        self.last = selected
        self.missing = False
        self.loss = "unknown"
        self.recent.append((now, selected))
        self.recent = [(t, f) for t, f in self.recent if now-t <= 1][-8:]
        return selected, "unknown"


@dataclass(frozen=True)
class Result:
    state: str
    score: float | None = None
    deviation: float | None = None
    alert: bool = False
    severity: float = 0
    progress: float = 0


class Session:
    def __init__(self, settings, save=lambda settings: None):
        self.settings = settings
        self.save = save
        self.enabled = False
        self.paused = False
        self.calibrating = False
        self.samples = []
        self.subject = Association()
        self.last_time = None
        self.out_since = None
        self.filtered = None
        self.result = Result("Camera off")
        self.recovery_since = None
        self.was_lost = False
        self.capture_error = False

    def clear(self, state):
        self.out_since = None
        self.filtered = None
        self.result = Result(state)
        return self.result

    def start(self):
        self.enabled = True
        self.paused = False
        self.subject = Association()
        self.last_time = None
        self.was_lost = False
        self.capture_error = False
        return self.clear("Finding you")

    def stop(self, paused=False):
        self.enabled = False
        self.paused = paused
        self.calibrating = False
        self.samples = []
        self.capture_error = False
        self.last_time = None
        self.subject = Association()
        return self.clear("Paused" if paused else "Camera off")

    def calibrate(self):
        if self.enabled:
            self.capture_error = False
            self.calibrating = True
            self.samples = []
            self.subject = Association()
            self.clear("Hold your comfortable height")

    def cancel_calibration(self):
        self.calibrating = False
        self.samples = []
        self.capture_error = False
        return self.clear("Finding you" if self.enabled else "Camera off")

    def levels_changed(self):
        self.filtered = None
        self.out_since = None
        return self.clear("Finding you" if self.enabled else "Paused" if self.paused else "Camera off")

    def tick(self, faces, now):
        if not self.enabled:
            return self.result
        if not math.isfinite(now) or self.last_time is not None and now <= self.last_time:
            self.samples = []
            return self.clear("Finding you")
        dt = now-self.last_time if self.last_time is not None else 0
        if dt > .75:
            self.samples = []
            self.clear("Finding you")
            self.was_lost = True
            self.recovery_since = None
        self.last_time = now
        if self.capture_error:
            return self.result
        face, loss = self.subject.select(faces, now)
        if face is None:
            self.samples = []
            self.was_lost = True
            self.recovery_since = None
            if loss == "bottom" and self.out_since is not None and dt <= .75:
                self.result = Result("Red", alert=self.settings.red_alert and now-self.out_since >= self.settings.delay,
                                     severity=2)
                return self.result  # no measured score or progress for unseen time
            return self.clear("One person at a time" if loss == "ambiguous" else "Finding you")
        if self.calibrating:
            self.samples.append((now, face))
            if len(self.samples) > 1:
                if any(statistics.pstdev(getattr(f, key) for _, f in self.samples) > .008
                       for key in ["eyes", "nose", "chin"]):
                    self.samples = [(now, face)]
            elapsed = now-self.samples[0][0]
            if elapsed >= 3 and len(self.samples) >= 15:
                baseline = Calibration(*(statistics.mean(getattr(f, key) for _, f in self.samples)
                                         for key in ["eyes", "nose", "chin"]))
                candidate = replace(self.settings, calibration=baseline, forgiveness=1,
                                    yellow=None, red=None, calibrations=dict(self.settings.calibrations))
                candidate.remember_camera()
                try:
                    self.save(candidate)
                except (OSError, ValueError):
                    self.calibrating = False
                    self.samples = []
                    self.capture_error = True
                    return self.clear("Couldn’t save height. Try again.")
                self.settings = candidate
                self.calibrating = False
                self.samples = []
                self.was_lost = False
                return self.clear("Height saved")
            self.result = Result("Hold your comfortable height", progress=min(1, elapsed/3))
            return self.result
        if self.settings.calibration is None:
            return self.clear("Set your height")
        raw = self.settings.calibration.deviation(face)
        yellow, red = self.settings.yellow_threshold, self.settings.red_threshold
        # Bottom-return green clears on its first valid frame. Other uncertain
        # reacquisition needs two observations separated by at least .16s.
        if self.was_lost and raw >= yellow:
            if self.recovery_since is None:
                self.recovery_since = now
            if now-self.recovery_since < .16:
                return self.clear("Finding you")
        self.was_lost = False
        self.recovery_since = None
        alpha = 1 if dt <= 0 or dt > .75 else 1-math.exp(-dt/.2)
        self.filtered = raw if self.filtered is None or raw < self.filtered else self.filtered+alpha*(raw-self.filtered)
        if raw < red:
            self.out_since = None
        elif self.filtered >= red and self.out_since is None:
            self.out_since = now
        zone = "Green" if self.filtered < yellow else "Yellow" if self.filtered < red else "Red"
        alert = self.settings.red_alert and self.out_since is not None and now-self.out_since >= self.settings.delay
        severity = 0 if zone == "Green" else min(3, 1+(self.filtered-yellow)/(red-yellow))
        # Same displayed scale as the native Mac LiveScoreStore: 100 at
        # baseline, 85 at yellow, 50 at red, then down toward zero.
        d = self.filtered
        score = (100-15*d/yellow if d < yellow else 85-35*(d-yellow)/(red-yellow) if d < red
                 else max(0, 50-50*(d-red)/red))
        self.result = Result(zone, score, self.filtered, alert, severity)
        return self.result

    def watchdog(self, now):
        if self.enabled and self.last_time is not None and now-self.last_time > .75:
            self.samples = []
            self.was_lost = True
            self.recovery_since = None
            return self.clear("Camera interrupted")
        return self.result
