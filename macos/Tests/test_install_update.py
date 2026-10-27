"""Synthetic installer checks. No real app, camera, profile or process is used."""
import hashlib
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import tempfile
import types
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "install-update.py"
spec = importlib.util.spec_from_file_location("zone_install_update", MODULE_PATH)
update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update)


class Fixture:
    def __init__(self, root, *, capability=1, mode="tracking", running=True):
        self.root = Path(root)
        self.source = self.root / "new/Zone.app"
        self.installed = self.root / "home/Applications/Zone.app"
        self.profile = self.root / "profile"
        self.private = self.root / "host"
        self.profile.mkdir()
        self.bundle(self.source, "51", 1)
        self.bundle(self.installed, "50", capability)
        self.mode = mode
        self.running = running
        self.commands = []
        self.now = 1000.0
        self.clock = 0.0
        self.fail_registration = False
        self.fail_launch = False
        self.bad_receipt = False
        self.omit_receipt = False
        self.legacy_emits = True
        self.stopped = False
        self.pid = 4321
        self.preferences = {"selectedCameraID": "synthetic-camera", "calibrations": {
            "synthetic-camera": {"cameraID": "synthetic-camera", "featureSchema": "seated-height-v2",
                                 "baseline": [0, 0.4, 0, 0.3, 0.6, 0.5]}}}
        update.atomic_json(self.profile / "preferences.json", self.preferences)

    @staticmethod
    def bundle(path, build, capability):
        (path / "Contents/MacOS").mkdir(parents=True)
        with (path / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": update.BUNDLE_ID, "CFBundleExecutable": update.EXECUTABLE,
                          "CFBundleVersion": build, "ZoneUpdateResumeVersion": capability}, stream)
        (path / "Contents/MacOS/PostureZone").write_bytes(b"synthetic executable")

    def sleep(self, seconds):
        self.clock += seconds
        if self.legacy_emits and (self.profile / "performance-request.json").exists():
            row = {"uptime": 2000 + self.clock, "active": self.mode != "off",
                   "paused": self.mode == "paused",
                   "capture": {"stage": "review" if self.mode == "setup" else "monitoring"}}
            update.atomic_json(self.profile / "performance-samples.json", [row])

    def run(self, arguments, **kwargs):
        args = [str(item) for item in arguments]
        self.commands.append(args)
        if args[0] == "xcrun":
            Path(args[args.index("-o") + 1]).write_bytes(b"synthetic helper")
        elif "UpdateHost-" in Path(args[0]).name:
            if args[1] == "status":
                return types.SimpleNamespace(returncode=0, stderr="", stdout=json.dumps({
                    "running": self.running, "path": str(self.installed), "build": update.bundle_info(self.installed)["CFBundleVersion"],
                    "updateResumeVersion": update.bundle_info(self.installed).get("ZoneUpdateResumeVersion", 0),
                    "pid": self.pid}))
            if args[1] == "terminate":
                self.assert_request = update.json_read(self.profile / "update-request.json")
                self.stopped = True
                self.running = False
                if update.bundle_info(self.installed)["ZoneUpdateResumeVersion"] == 1 and not self.omit_receipt:
                    state = {"mode": self.mode, "cameraID": "synthetic-camera", "page": "Progress",
                             "controlsVisible": False, "pauseUntilUnix": 1100.0 if self.mode == "paused" else None,
                             "preferencesDigest": update.preferences_digest(self.profile)}
                    if self.bad_receipt:
                        state["preferencesDigest"] = "wrong"
                    update.atomic_json(self.profile / "update-resume.json",
                                       {"schema": 1, "request": self.assert_request, "state": state})
                return types.SimpleNamespace(returncode=0, stderr="", stdout=json.dumps({"terminated": True}))
        elif args[0] == update.LSREGISTER and self.fail_registration:
            return types.SimpleNamespace(returncode=1, stderr="synthetic registration failure", stdout="")
        elif args[0] == "open" and self.fail_launch:
            return types.SimpleNamespace(returncode=1, stderr="synthetic uncertain launch", stdout="")
        elif args[0] == "open":
            self.running = True
            self.pid = 5432
            # The production app atomically claims and consumes its handoff.
            for name in ("update-request.json", "update-resume.json"):
                (self.profile / name).unlink(missing_ok=True)
        return types.SimpleNamespace(returncode=0, stderr="", stdout="")

    def installer(self, **kwargs):
        return update.Installer(self.source, self.installed, self.profile, self.private,
                                run=self.run, now=lambda: self.now, sleep=self.sleep, monotonic=lambda: self.clock,
                                **kwargs)


class InstallerChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def fixture(self, **kwargs):
        return Fixture(self.directory.name, **kwargs)

    def test_tracking_handoff_and_staged_signature_before_quit(self):
        fixture = self.fixture()
        before = (fixture.profile / "preferences.json").read_bytes()
        receipt = fixture.installer().install()
        self.assertTrue(receipt["ok"])
        self.assertTrue(receipt["launchObserved"])
        self.assertEqual(receipt["preservedState"]["mode"], "tracking")
        self.assertFalse(receipt["preservedState"]["controlsVisible"])
        self.assertEqual(update.bundle_info(fixture.installed)["CFBundleVersion"], "51")
        self.assertTrue(Path(receipt["previousBundle"]).exists())
        self.assertEqual((fixture.profile / "preferences.json").read_bytes(), before)
        self.assertFalse((fixture.profile / "update-install.lock").exists())
        stop = next(i for i, args in enumerate(fixture.commands) if "terminate" in args)
        staged_verify = next(i for i, args in enumerate(fixture.commands)
                             if args[0] == "codesign" and ".zone-update-" in args[-1])
        self.assertLess(staged_verify, stop)

    def test_publication_recheck_runs_after_staging_and_stop_before_bundle_move(self):
        fixture = self.fixture()
        observed = []
        installer = fixture.installer(before_replace=lambda: observed.append({
            "running": fixture.running,
            "installed_build": update.bundle_info(fixture.installed)["CFBundleVersion"],
            "staged_build": update.bundle_info(installer.stage)["CFBundleVersion"],
            "handoff": (fixture.profile / "update-resume.json").exists(),
            "lock": (fixture.profile / "update-install.lock").exists()}))
        result = installer.install()
        self.assertEqual(observed, [{"running": False, "installed_build": "50", "staged_build": "51",
                                    "handoff": True, "lock": True}])
        self.assertTrue(result["launchObserved"])

    def test_publication_recheck_denial_preserves_bundle_and_owned_cleanup(self):
        fixture = self.fixture()
        preferences = (fixture.profile / "preferences.json").read_bytes()
        calls = []
        def deny():
            calls.append(True)
            raise update.UpdateError("Publication revision changed")
        installer = fixture.installer(before_replace=deny)
        with self.assertRaisesRegex(update.UpdateError, "Publication revision changed"):
            installer.install()
        self.assertEqual(calls, [True])
        self.assertEqual(update.bundle_info(fixture.installed)["CFBundleVersion"], "50")
        self.assertFalse(installer.old.exists())
        self.assertFalse(installer.stage.exists())
        self.assertEqual((fixture.profile / "preferences.json").read_bytes(), preferences)
        for name in ("update-request.json", "update-resume.json", "update-install.lock"):
            self.assertFalse((fixture.profile / name).exists())
        self.assertTrue(fixture.running)
        self.assertEqual(sum(command[0] == "open" for command in fixture.commands), 1)

    def test_cli_delegates_to_publication_and_preserves_receipt(self):
        fixture = self.fixture()
        receipt = fixture.root / "publication-receipt.json"
        result = {"ok": True, "installed": str(fixture.installed), "launchObserved": True}
        with patch.object(update, "_publish_zone", return_value=result) as publish, \
                patch.object(update.sys, "argv", ["install-update.py", "--source", str(fixture.source),
                    "--publication-owner", "Managing runtimes", "--receipt", str(receipt)]), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(update.main(), 0)
        publish.assert_called_once_with(fixture.source.resolve(), "Managing runtimes")
        self.assertEqual(update.json_read(receipt), result)
        self.assertEqual(update.bundle_info(fixture.installed)["CFBundleVersion"], "50")
        self.assertEqual(fixture.commands, [])

    def test_cli_missing_owner_cannot_start_update(self):
        with patch.object(update, "_publish_zone") as publish, \
                patch.object(update.sys, "argv", ["install-update.py"]), \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as failure:
            update.main()
        self.assertEqual(failure.exception.code, 2)
        publish.assert_not_called()

    def test_paused_and_off_preserved_without_inventing_tracking(self):
        for mode in ("paused", "off"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                fixture = Fixture(directory, mode=mode)
                receipt = fixture.installer().install()
                self.assertEqual(receipt["preservedState"]["mode"], mode)
                if mode == "paused":
                    self.assertEqual(receipt["preservedState"]["pauseUntilUnix"], 1100.0)

    def test_not_running_has_no_resume_intent(self):
        fixture = self.fixture(running=False)
        receipt = fixture.installer().install()
        self.assertIsNone(receipt["preservedState"])
        self.assertFalse((fixture.profile / "update-request.json").exists())
        self.assertFalse(any("terminate" in args for args in fixture.commands))

    def test_legacy_bootstrap_requires_fresh_state_and_cleans_only_owned_diagnostic(self):
        fixture = self.fixture(capability=0)
        receipt = fixture.installer().install()
        self.assertEqual(receipt["preservedState"]["mode"], "tracking")
        self.assertEqual(receipt["preservedState"]["page"], "Posture")
        self.assertTrue(receipt["limitations"])
        self.assertFalse((fixture.profile / "performance-request.json").exists())

    def test_legacy_timeout_never_terminates_or_replaces(self):
        fixture = self.fixture(capability=0)
        fixture.legacy_emits = False
        with self.assertRaises(update.UpdateError):
            fixture.installer().install()
        self.assertFalse(fixture.stopped)
        self.assertEqual(update.bundle_info(fixture.installed)["CFBundleVersion"], "50")
        self.assertFalse((fixture.profile / "performance-request.json").exists())

    def test_foreign_diagnostic_remains_untouched(self):
        fixture = self.fixture(capability=0, mode="off")
        foreign = {"expires": 1100.0, "visual_mode": "no-smoke", "owner": "other-owner"}
        update.atomic_json(fixture.profile / "performance-request.json", foreign)
        receipt = fixture.installer().install()
        self.assertEqual(receipt["preservedState"]["mode"], "off")
        self.assertEqual(update.json_read(fixture.profile / "performance-request.json"), foreign)

    def test_invalid_or_missing_handoff_does_not_replace(self):
        for condition in ("bad_receipt", "omit_receipt"):
            with self.subTest(condition=condition), tempfile.TemporaryDirectory() as directory:
                fixture = Fixture(directory)
                setattr(fixture, condition, True)
                with self.assertRaises(update.UpdateError):
                    fixture.installer().install()
                self.assertEqual(update.bundle_info(fixture.installed)["CFBundleVersion"], "50")
                self.assertFalse((fixture.profile / "update-request.json").exists())
                self.assertFalse((fixture.profile / "update-resume.json").exists())

    def test_registration_failure_rolls_back_before_launch(self):
        fixture = self.fixture()
        fixture.fail_registration = True
        with self.assertRaises(update.UpdateError):
            fixture.installer().install()
        self.assertEqual(update.bundle_info(fixture.installed)["CFBundleVersion"], "50")
        self.assertFalse((fixture.profile / "update-request.json").exists())

    def test_uncertain_launch_does_not_rollback_or_replay(self):
        fixture = self.fixture()
        fixture.fail_launch = True
        with self.assertRaises(update.UpdateError) as raised:
            fixture.installer().install()
        self.assertTrue(json.loads(str(raised.exception))["launchUncertain"])
        self.assertEqual(update.bundle_info(fixture.installed)["CFBundleVersion"], "51")
        self.assertEqual(sum(args[0] == "open" for args in fixture.commands), 1)
        self.assertTrue((fixture.profile / "update-resume.json").exists())
        self.assertTrue((fixture.profile / "update-install.lock").exists())

    def test_existing_handoff_and_lock_refuse_competing_owners(self):
        fixture = self.fixture()
        update.atomic_json(fixture.profile / "update-request.json", {"operationID": "other"})
        with self.assertRaises(update.UpdateError):
            fixture.installer().install()
        self.assertEqual(update.json_read(fixture.profile / "update-request.json"), {"operationID": "other"})
        self.assertFalse(fixture.stopped)
        (fixture.profile / "update-request.json").unlink()
        update.atomic_json(fixture.profile / "update-install.lock", {"operationID": "other-lock"})
        with self.assertRaises(FileExistsError):
            fixture.installer().install()
        self.assertEqual(update.json_read(fixture.profile / "update-install.lock"), {"operationID": "other-lock"})
        self.assertFalse(fixture.stopped)

    def test_same_build_and_wrong_source_capability_fail_before_termination(self):
        for mutation in ("same", "capability"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                fixture = Fixture(directory)
                info_path = fixture.source / "Contents/Info.plist"
                with info_path.open("rb") as stream:
                    info = plistlib.load(stream)
                info["CFBundleVersion" if mutation == "same" else "ZoneUpdateResumeVersion"] = "50" if mutation == "same" else 0
                with info_path.open("wb") as stream:
                    plistlib.dump(info, stream)
                with self.assertRaises(update.UpdateError):
                    fixture.installer().install()
                self.assertFalse(fixture.stopped)

    def test_receipt_validation_rejects_replay_expiry_and_profile_change(self):
        fixture = self.fixture()
        request = {"schema": 1, "operationID": "00000000-0000-4000-8000-000000000001",
                   "fromBuild": "50", "toBuild": "51", "sourcePID": 4321,
                   "createdAt": 1000.0, "expiresAt": 1300.0}
        state = {"mode": "off", "cameraID": "", "page": "Posture", "controlsVisible": True,
                 "pauseUntilUnix": None, "preferencesDigest": update.preferences_digest(fixture.profile)}
        receipt = {"schema": 1, "request": request, "state": state}
        self.assertTrue(update.valid_receipt(receipt, request, fixture.profile, 1001.0))
        self.assertFalse(update.valid_receipt(receipt, request, fixture.profile, 1300.0))
        other = dict(request, operationID="00000000-0000-4000-8000-000000000002")
        self.assertFalse(update.valid_receipt(receipt, other, fixture.profile, 1001.0))
        (fixture.profile / "preferences.json").write_text("changed")
        self.assertFalse(update.valid_receipt(receipt, request, fixture.profile, 1001.0))
        (fixture.profile / "preferences.json").unlink()
        state["preferencesDigest"] = "absent"
        self.assertTrue(update.valid_receipt(receipt, request, fixture.profile, 1001.0))

    def test_atomic_create_never_overwrites_an_owner(self):
        path = Path(self.directory.name) / "owned.json"
        update.atomic_json(path, {"owner": "first"}, create=True)
        with self.assertRaises(FileExistsError):
            update.atomic_json(path, {"owner": "second"}, create=True)
        self.assertEqual(update.json_read(path), {"owner": "first"})
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
