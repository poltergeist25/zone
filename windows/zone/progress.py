"""Local, time-weighted posture history. No face or image data is retained.

Only intervals between two eligible observations count. Calendar buckets follow
America/New_York, matching Zone for Mac; repeated fall-back hours share a bucket.
"""
from copy import deepcopy
from dataclasses import asdict, dataclass, field
from datetime import date, datetime, timedelta
import json
import math
import os
from pathlib import Path
import tempfile
import time
from uuid import uuid4
from zoneinfo import ZoneInfo


TIME_ZONE = "America/New_York"
EASTERN = ZoneInfo(TIME_ZONE)
BANDS = {"Green": "green_seconds", "Yellow": "yellow_seconds", "Red": "red_seconds"}


def date_id(timestamp):
    return datetime.fromtimestamp(timestamp, EASTERN).date().isoformat()


def week_dates(timestamp, offset=0):
    today = datetime.fromtimestamp(timestamp, EASTERN).date()
    monday = today - timedelta(days=today.weekday()) + timedelta(weeks=offset)
    return [(monday + timedelta(days=i)).isoformat() for i in range(7)]


def _valid_date(value):
    try:
        return isinstance(value, str) and date.fromisoformat(value).isoformat() == value
    except (ValueError, TypeError):
        return False


def _number(value):
    return not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value)


@dataclass
class HourProgress:
    green_seconds: float = 0
    yellow_seconds: float = 0
    red_seconds: float = 0

    @property
    def tracked_seconds(self):
        return self.green_seconds + self.yellow_seconds + self.red_seconds

    @property
    def score(self):
        return 100 * (self.green_seconds + .5*self.yellow_seconds) / self.tracked_seconds if self.tracked_seconds else None

    @property
    def valid(self):
        return all(_number(v) and 0 <= v <= 7200 for v in asdict(self).values()) and self.tracked_seconds <= 7200


@dataclass
class DayProgress(HourProgress):
    date_id: str = ""
    hours: list[HourProgress] = field(default_factory=lambda: [HourProgress() for _ in range(24)])

    @property
    def green_fraction(self):
        return self.green_seconds/self.tracked_seconds if self.tracked_seconds else None

    @property
    def yellow_fraction(self):
        return self.yellow_seconds/self.tracked_seconds if self.tracked_seconds else None

    @property
    def red_fraction(self):
        return self.red_seconds/self.tracked_seconds if self.tracked_seconds else None

    @property
    def valid(self):
        values = [self.green_seconds, self.yellow_seconds, self.red_seconds]
        return (_valid_date(self.date_id) and len(self.hours) == 24
                and all(isinstance(h, HourProgress) and h.valid for h in self.hours)
                and all(_number(v) and v >= 0 for v in values)
                and self.tracked_seconds <= 25*3600
                and all(abs(sum(getattr(h, key) for h in self.hours)-getattr(self, key)) < .01
                        for key in BANDS.values()))

    def add(self, seconds, band, hour):
        key = BANDS[band]
        setattr(self, key, getattr(self, key)+seconds)
        bucket = self.hours[hour]
        setattr(bucket, key, getattr(bucket, key)+seconds)


class ProgressStore:
    def __init__(self, path, now=time.time, max_sample_gap=1.5, save_interval=30):
        self.path = Path(path)
        self.now = now
        self.max_sample_gap = max_sample_gap
        self.save_interval = save_interval
        self.error_message = None
        self.rejected_samples = 0
        self._days = {}
        self._anchor = None
        self._dirty = False
        self._last_save = None
        self._write_blocked = False
        self._load()

    @property
    def days(self):
        return [deepcopy(self._days[key]) for key in sorted(self._days)]

    def day(self, date_id=None):
        key = date_id if date_id is not None else datetime.fromtimestamp(self.now(), EASTERN).date().isoformat()
        if not _valid_date(key):
            raise ValueError("Invalid history date")
        return deepcopy(self._days.get(key, DayProgress(date_id=key)))

    def record(self, state, at, eligible=True):
        if not _number(at):
            self.rejected_samples += 1
            self._anchor = None
            return
        band = state if eligible and state in BANDS else None
        if self._anchor is not None:
            previous, prior_band = self._anchor
            if at < previous:
                self.rejected_samples += 1
                self._anchor = None
                return
            if at == previous:
                if band is None:
                    self._anchor = None
                return
            if band is not None and at-previous <= self.max_sample_gap:
                self._integrate(previous, at, prior_band)
        self._anchor = (at, band) if band is not None else None
        if self._dirty:
            if self._last_save is None:
                self._last_save = at
            elif at-self._last_save >= self.save_interval:
                self._save()
                self._last_save = at

    def _integrate(self, start, end, band):
        cursor = start
        while cursor < end:
            local = datetime.fromtimestamp(cursor, EASTERN)
            # Advancing an absolute hour handles the repeated/skipped Eastern
            # hour without integrating a non-existent or duplicated wall period.
            hour_start = local.replace(minute=0, second=0, microsecond=0).timestamp()
            stop = min(end, hour_start+3600)
            key = local.date().isoformat()
            day = self._days.get(key)
            if day is None:
                day = DayProgress(date_id=key)
                self._days[key] = day
            day.add(stop-cursor, band, local.hour)
            cursor = stop
        self._dirty = True

    def flush(self):
        if self._dirty:
            return self._save()
        return not self._write_blocked

    def _save(self):
        if self._write_blocked:
            return False
        temporary = None
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            fd, temporary = tempfile.mkstemp(prefix=".zone-progress-", dir=self.path.parent)
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                json.dump({"version": 1, "time_zone": TIME_ZONE,
                           "days": [asdict(self._days[key]) for key in sorted(self._days)]},
                          output, allow_nan=False, sort_keys=True)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.path)
            self._dirty = False
            self.error_message = None
            return True
        except (OSError, ValueError, TypeError) as error:
            self.error_message = f"Could not save daily progress: {error}"
            return False
        finally:
            if temporary is not None and os.path.exists(temporary):
                os.unlink(temporary)

    def _load(self):
        if not self.path.exists():
            return
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            if (not isinstance(data, dict) or type(data.get("version")) is not int or data.get("version") != 1
                    or data.get("time_zone") != TIME_ZONE or not isinstance(data.get("days"), list)):
                raise ValueError("Unsupported or unreadable history")
            loaded = {}
            for item in data["days"]:
                item = dict(item)
                item["hours"] = [HourProgress(**h) for h in item["hours"]]
                day = DayProgress(**item)
                if not day.valid or day.date_id in loaded:
                    raise ValueError("Invalid daily totals")
                loaded[day.date_id] = day
            self._days = loaded
        except (OSError, ValueError, TypeError, KeyError, OverflowError) as error:
            # Never replace an unreadable/newer-format file in place. Preserve
            # exact bytes under a unique name before allowing a fresh history.
            aside = self.path.with_name(f"{self.path.stem}.unreadable-{uuid4().hex}.json")
            try:
                self.path.rename(aside)
                self.error_message = f"Unreadable daily progress was preserved as {aside.name}. Starting a new history."
            except OSError:
                self._write_blocked = True
                self.error_message = f"Daily progress could not be read and will not be overwritten: {error}"
