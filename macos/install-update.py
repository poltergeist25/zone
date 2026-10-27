#!/usr/bin/env python3
"""Install a signed Zone update with a fresh, one-use session handoff.

All process control uses the exact-owned-app UpdateHost helper. This has no
daemon, forced termination, UI automation, camera fallback, or retry loop for
uncertain effects. Ordinary launches do not create an update intent.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

BUNDLE_ID = "com.arungupta.posturezone"
EXECUTABLE = "PostureZone"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


class UpdateError(RuntimeError):
    pass


def json_read(path: Path):
    return json.loads(path.read_text())


def atomic_json(path: Path, value, *, create=False):
    """Publish a private file atomically; create refuses an existing owner."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=".zone-update-", dir=path.parent)
    temporary = Path(temporary)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        if create:
            os.link(temporary, path)
        else:
            os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def preferences_digest(profile: Path):
    path = profile / "preferences.json"
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else "absent"


def bundle_info(path: Path):
    with (path / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if (info.get("CFBundleIdentifier") != BUNDLE_ID or
            info.get("CFBundleExecutable") != EXECUTABLE or
            not isinstance(info.get("CFBundleVersion"), str) or
            not info["CFBundleVersion"].strip() or
            not (path / "Contents/MacOS" / EXECUTABLE).is_file()):
        raise UpdateError("Unexpected Zone bundle identity or missing executable")
    return info


def valid_request(request, now):
    try:
        uuid.UUID(request["operationID"])
        created, expires = request["createdAt"], request["expiresAt"]
        return (type(request["schema"]) is int and request["schema"] == 1 and isinstance(request["sourcePID"], int) and
                not isinstance(request["sourcePID"], bool) and request["sourcePID"] > 0 and
                all(isinstance(request[k], str) and request[k].strip() for k in ("fromBuild", "toBuild")) and
                request["fromBuild"] != request["toBuild"] and
                all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)
                    for v in (created, expires)) and
                0 < expires - created <= 300 and created - 5 <= now < expires)
    except (KeyError, TypeError, ValueError, AttributeError, OverflowError):
        return False


def valid_receipt(receipt, request, profile, now):
    if not valid_request(request, now) or not isinstance(receipt, dict):
        return False
    state = receipt.get("state")
    if type(receipt.get("schema")) is not int or receipt.get("schema") != 1 or receipt.get("request") != request or not isinstance(state, dict):
        return False
    deadline = state.get("pauseUntilUnix")
    return (state.get("mode") in ("tracking", "paused", "off", "setup") and
            isinstance(state.get("cameraID"), str) and
            state.get("page") in ("Posture", "Progress", "Settings") and
            isinstance(state.get("controlsVisible"), bool) and
            state.get("preferencesDigest") == preferences_digest(profile) and
            (deadline is None or (isinstance(deadline, (int, float)) and not isinstance(deadline, bool)
                                  and math.isfinite(deadline))))


def calibration_present(preferences, camera):
    """Bootstrap admission only; the app independently validates the full record."""
    if not isinstance(preferences, dict) or not isinstance(camera, str) or not camera:
        return False
    saved = preferences.get("calibrations", {}).get(camera, {})
    baseline = saved.get("baseline")
    return (saved.get("cameraID") == camera and saved.get("featureSchema") == "seated-height-v2" and
            isinstance(baseline, list) and len(baseline) == 6 and
            all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) for v in baseline) and
            baseline[3] > 0.08)


def legacy_state(row, preferences):
    if not isinstance(row.get("active"), bool) or not isinstance(row.get("paused"), bool):
        raise UpdateError("Legacy report has no authoritative activity state")
    capture = row.get("capture", {})
    stage = capture.get("stage")
    camera = preferences.get("selectedCameraID") or ""
    if row["active"] and stage == "monitoring":
        if not calibration_present(preferences, camera):
            raise UpdateError("Active legacy session has no valid camera-bound saved calibration")
        mode = "paused" if row["paused"] else "tracking"
    elif row["active"]:
        if stage not in ("green", "review", "yellow", "red"):
            raise UpdateError("Legacy report has an unknown active stage")
        mode = "setup"
    else:
        mode = "off"
    return {"mode": mode, "cameraID": camera, "pauseUntilUnix": None,
            "page": "Posture", "controlsVisible": True, "preferencesDigest": ""}


class Installer:
    def __init__(self, source, installed, profile, private, *, run=subprocess.run,
                 now=time.time, sleep=time.sleep, monotonic=time.monotonic,
                 before_replace=None):
        self.source, self.installed, self.profile, self.private = map(Path, (source, installed, profile, private))
        self.run, self.now, self.sleep, self.monotonic = run, now, sleep, monotonic
        # The trusted publication supervisor rechecks its pinned destination,
        # candidate and deadline here, under this installer's existing app lock.
        # Synthetic callers retain the original lifecycle through the default.
        self.before_replace = before_replace or (lambda: None)
        self.operation = str(uuid.uuid4())
        self.request = None
        self.owned_diagnostic = None
        self.stage = self.installed.parent / (".zone-update-" + self.operation + ".app")
        self.old = None
        self.phase = "checking"
        self.launch_attempted = False
        self.stopped = False
        self.was_running = False
        self.launch_observed = False
        self.helper = None
        self.limitations = []

    def command(self, args):
        result = self.run([str(x) for x in args], capture_output=True, text=True)
        if result.returncode:
            detail = (result.stderr or result.stdout or "command failed").strip()[:1500]
            raise UpdateError(detail)
        return result.stdout

    def make_helper(self):
        source = Path(__file__).parent / "tools/UpdateHost.swift"
        digest = hashlib.sha256(source.read_bytes()).hexdigest()[:20]
        self.private.mkdir(parents=True, exist_ok=True, mode=0o700)
        helper = self.private / ("UpdateHost-" + digest)
        if not helper.exists():
            temporary = self.private / (".UpdateHost-" + self.operation)
            try:
                self.command(["xcrun", "swiftc", "-O", source, "-o", temporary, "-framework", "AppKit"])
                os.chmod(temporary, 0o700)
                os.replace(temporary, helper)
            finally:
                temporary.unlink(missing_ok=True)
        self.helper = helper

    def host(self, *arguments):
        return json.loads(self.command([self.helper, *arguments]))

    def verify(self, path):
        info = bundle_info(path)
        self.command(["codesign", "--verify", "--strict", "--verbose=2", path])
        return info

    def clean_diagnostic(self):
        path = self.profile / "performance-request.json"
        if self.owned_diagnostic is not None:
            try:
                if json_read(path) == self.owned_diagnostic:
                    path.unlink()
            except (OSError, ValueError):
                pass

    def read_legacy_state(self):
        report = self.profile / "performance-samples.json"
        try:
            initial = json_read(report)
            cutoff = initial[-1]["uptime"] if initial else -1
        except (OSError, ValueError, KeyError, TypeError):
            cutoff = -1
        started = self.now()
        diagnostic = self.profile / "performance-request.json"
        if not diagnostic.exists():
            self.owned_diagnostic = {"expires": started + 120, "visual_mode": "full",
                                     "owner": "zone-update:" + self.operation}
            atomic_json(diagnostic, self.owned_diagnostic, create=True)
        else:
            existing = json_read(diagnostic)
            expiry = existing.get("expires")
            if not isinstance(expiry, (int, float)) or not math.isfinite(expiry) or not started < expiry <= started + 900:
                raise UpdateError("An existing diagnostic request needs owner reconciliation")
        try:
            deadline = self.monotonic() + 20
            while self.monotonic() < deadline:
                try:
                    rows = json_read(report)
                    row = rows[-1]
                    if report.stat().st_mtime >= started and row["uptime"] > cutoff:
                        preferences_path = self.profile / "preferences.json"
                        preferences = json_read(preferences_path) if preferences_path.exists() else {}
                        self.limitations.append("Legacy bootstrap cannot read control visibility/page or a timed pause deadline; restores Posture with controls visible and preserves paused as indefinite")
                        return legacy_state(row, preferences)
                except (OSError, ValueError, KeyError, IndexError, TypeError):
                    pass
                self.sleep(0.2)
            raise UpdateError("No fresh legacy tracking report; update was not started")
        finally:
            self.clean_diagnostic()

    def cancel_owned_handoff(self):
        for name in ("update-resume.json", "update-request.json"):
            path = self.profile / name
            try:
                data = json_read(path)
                operation = data.get("operationID") if name == "update-request.json" else data.get("request", {}).get("operationID")
                if operation == self.operation:
                    path.unlink()
            except (OSError, ValueError, TypeError, AttributeError):
                pass

    def wait_receipt(self):
        path = self.profile / "update-resume.json"
        deadline = self.monotonic() + 3
        while self.monotonic() < deadline:
            try:
                value = json_read(path)
                if valid_receipt(value, self.request, self.profile, self.now()):
                    return value
                raise UpdateError("Update handoff failed validation; installed app was not replaced")
            except FileNotFoundError:
                self.sleep(0.05)
        raise UpdateError("The app stopped without an update handoff; installed app was not replaced")

    def observe_launch(self, build):
        deadline = self.monotonic() + 10
        while self.monotonic() < deadline:
            owner = self.host("status", self.installed)
            consumed = not any((self.profile / name).exists()
                               for name in ("update-request.json", "update-resume.json"))
            if owner.get("running") and owner.get("build") == build and consumed:
                if self.request is None or owner.get("pid") != self.request["sourcePID"]:
                    self.launch_observed = True
                    return owner
            self.sleep(0.2)
        return None

    def install(self):
        self.profile.mkdir(parents=True, exist_ok=True, mode=0o700)
        lock = self.profile / "update-install.lock"
        atomic_json(lock, {"operationID": self.operation, "pid": os.getpid(), "createdAt": self.now()}, create=True)
        result = None
        try:
            for name in ("update-request.json", "update-resume.json"):
                if (self.profile / name).exists():
                    raise UpdateError("An existing update handoff needs owner reconciliation")
            incoming = self.verify(self.source)
            if incoming.get("ZoneUpdateResumeVersion") != 1:
                raise UpdateError("The new bundle does not support the update-resume handoff")
            existing = bundle_info(self.installed)
            if incoming["CFBundleVersion"] == existing["CFBundleVersion"]:
                raise UpdateError("Source and installed builds are identical")
            self.make_helper()
            owner = self.host("status", self.installed)
            if owner["build"] != existing["CFBundleVersion"]:
                raise UpdateError("Installed owner changed during validation")
            self.was_running = owner["running"]
            self.phase = "staging"
            shutil.copytree(self.source, self.stage, symlinks=True)
            self.verify(self.stage)
            preserved = None
            if self.was_running:
                state = None
                if existing.get("ZoneUpdateResumeVersion", 0) != 1:
                    self.phase = "legacy-state"
                    state = self.read_legacy_state()
                created = self.now()
                self.request = {"schema": 1, "operationID": self.operation,
                                "fromBuild": existing["CFBundleVersion"], "toBuild": incoming["CFBundleVersion"],
                                "sourcePID": owner["pid"], "createdAt": created, "expiresAt": created + 300}
                atomic_json(self.profile / "update-request.json", self.request, create=True)
                self.phase = "terminating"
                self.host("terminate", self.installed, str(owner["pid"]))
                self.stopped = True
                if state is not None:
                    state["preferencesDigest"] = preferences_digest(self.profile)
                    atomic_json(self.profile / "update-resume.json",
                                {"schema": 1, "request": self.request, "state": state}, create=True)
                preserved = self.wait_receipt()["state"]
            if self.host("status", self.installed).get("running"):
                raise UpdateError("A new Zone owner appeared before replacement; no process was forced")
            self.phase = "replacing"
            trash = self.installed.parent.parent / ".Trash"
            trash.mkdir(exist_ok=True)
            self.old = trash / ("Zone-replaced-build" + existing["CFBundleVersion"] + "-" + self.operation + ".app")
            self.before_replace()
            shutil.move(str(self.installed), str(self.old))
            shutil.move(str(self.stage), str(self.installed))
            self.verify(self.installed)
            self.command([LSREGISTER, "-f", self.installed])
            self.phase = "launching"
            self.launch_attempted = True
            self.command(["open", self.installed])
            self.phase = "launch-requested"
            launched = self.observe_launch(incoming["CFBundleVersion"])
            result = {"ok": True, "operationID": self.operation, "fromBuild": existing["CFBundleVersion"],
                      "toBuild": incoming["CFBundleVersion"], "installed": str(self.installed),
                      "previousBundle": str(self.old), "wasRunning": self.was_running,
                      "preservedState": preserved, "launchRequested": True,
                      "launchObserved": self.launch_observed,
                      "newPID": launched.get("pid") if launched else None,
                      "handoffConsumed": self.launch_observed if self.was_running else None,
                      "lockRetained": not self.launch_observed,
                      "limitations": self.limitations,
                      "acceptance": "Camera/tracking recovery needs application readback; never infer it from process launch"}
            return result
        except Exception as error:
            # Before launch there is no ambiguous new process to conflict with a
            # rollback. After launch, retain files/evidence for owner readback.
            if not self.launch_attempted:
                self.cancel_owned_handoff()
                if self.old and self.old.exists():
                    if self.installed.exists():
                        failed = self.installed.parent / (".zone-failed-" + self.operation + ".app")
                        shutil.move(str(self.installed), str(failed))
                    shutil.move(str(self.old), str(self.installed))
                if self.stopped and self.installed.exists():
                    try:
                        if not self.host("status", self.installed).get("running"):
                            self.command([LSREGISTER, "-f", self.installed])
                            self.command(["open", self.installed])
                    except Exception:
                        pass
            raise UpdateError(json.dumps({"ok": False, "operationID": self.operation,
                                         "phase": self.phase, "error": str(error),
                                         "launchUncertain": self.launch_attempted,
                                         "lockRetained": self.launch_attempted and not self.launch_observed,
                                         "trackingRecovery": "not verified; no automatic retry performed"})) from error
        finally:
            self.clean_diagnostic()
            if self.stage.exists() and not self.launch_attempted:
                shutil.rmtree(self.stage)
            try:
                if (not self.launch_attempted or self.launch_observed) and json_read(lock).get("operationID") == self.operation:
                    lock.unlink()
            except (OSError, ValueError, TypeError, AttributeError):
                pass


def _publish_zone(source, owner):
    """Use the existing factory destination claim, never a global runtime gate."""
    for ancestor in Path(__file__).resolve().parents:
        factory = ancestor / "infra/software-factory"
        if (factory / "app_update.py").is_file():
            sys.path.insert(0, str(factory))
            from app_update import publish_app
            return publish_app("zone", source, owner=owner)
    raise UpdateError("App publication adapter unavailable; no Zone update started")


def main():
    home = Path.home()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=home / "Library/Application Support/Gramercy/PostureZone/build/Zone.app")
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--publication-owner", required=True,
                        help="Exact accountable chat name for this authorized update")
    args = parser.parse_args()
    if not args.publication_owner.strip():
        parser.error("--publication-owner must name the accountable chat")
    try:
        publication = _publish_zone(args.source.resolve(), args.publication_owner)
        if isinstance(publication.get("zone_installation"), dict):
            # Preserve the existing receipt's installed path and lifecycle
            # fields; attach the separate supervisor's custody evidence.
            result = dict(publication["zone_installation"])
            result["publication"] = publication
        else:
            result = publication
    except Exception as error:
        try:
            result = json.loads(str(error))
        except (ValueError, TypeError):
            result = {"ok": False, "error": str(error)}
        if args.receipt:
            atomic_json(args.receipt, result)
        print(json.dumps(result, sort_keys=True))
        return 1
    if args.receipt:
        atomic_json(args.receipt, result)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
