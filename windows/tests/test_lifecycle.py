"""Synthetic lifetime notifications and actual local Qt IPC, never a camera."""
import ctypes
import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from pathlib import Path
import tempfile
import subprocess
import sys
import time
import unittest
from unittest.mock import patch, Mock

from PySide6.QtWidgets import QApplication
from PySide6.QtCore import QTimer
from zone.lifecycle import (InstanceGuard, WindowsSessionEvents, instance_name,
                            interruption_reason, _Message, WM_POWERBROADCAST,
                            WM_WTSSESSION_CHANGE, WM_ENDSESSION)


class LifetimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def test_notifications_stop_only_for_suspend_lock_and_end(self):
        self.assertEqual(interruption_reason(WM_POWERBROADCAST, 4), "Sleep")
        self.assertEqual(interruption_reason(WM_WTSSESSION_CHANGE, 7), "Session locked")
        self.assertEqual(interruption_reason(WM_WTSSESSION_CHANGE, 6), "Signing out")
        self.assertEqual(interruption_reason(WM_ENDSESSION, 1), "Signing out")
        for message, value in [(WM_POWERBROADCAST, 18), (WM_POWERBROADCAST, 7),
                               (WM_WTSSESSION_CHANGE, 8), (WM_ENDSESSION, 0), (99, 4)]:
            self.assertIsNone(interruption_reason(message, value))

    def test_native_event_only_targets_bound_window_and_never_consumes(self):
        calls = []
        with patch("zone.lifecycle.platform.system", return_value="test"):
            events = WindowsSessionEvents(self.app, 123, calls.append)
        message = _Message(123, WM_POWERBROADCAST, 4, 0)
        self.assertEqual(events.nativeEventFilter(b"windows_generic_MSG", ctypes.addressof(message)), (False, 0))
        self.assertEqual(calls, ["Sleep"])
        message.hwnd = 456
        events.nativeEventFilter(b"windows_generic_MSG", ctypes.addressof(message))
        self.assertEqual(calls, ["Sleep"])
        self.assertEqual(events.nativeEventFilter(b"unrelated", 0), (False, 0))
        events.close()
        events.close()

    def test_profile_key_is_stable_and_distinct(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(instance_name(tmp), instance_name(Path(tmp)/"."))
            self.assertNotEqual(instance_name(tmp), instance_name(Path(tmp)/"other"))

    def test_registration_and_filter_cleanup_are_once_only(self):
        wts = Mock()
        wts.WTSRegisterSessionNotification.return_value = 1
        app = Mock()
        with patch("zone.lifecycle.platform.system", return_value="Windows"), \
             patch("zone.lifecycle.ctypes.WinDLL", return_value=wts, create=True):
            events = WindowsSessionEvents(app, 123, lambda reason: None)
        wts.WTSRegisterSessionNotification.assert_called_once_with(123, 0)
        app.installNativeEventFilter.assert_called_once_with(events)
        events.close()
        events.close()
        app.removeNativeEventFilter.assert_called_once_with(events)
        wts.WTSUnRegisterSessionNotification.assert_called_once_with(123)

    def test_second_instance_activates_owner_and_cannot_listen(self):
        with tempfile.TemporaryDirectory() as tmp:
            calls = []
            owner = InstanceGuard(tmp, lambda: calls.append("opened"))
            # Use the actual arrangement: the incumbent's event loop keeps
            # servicing its Windows named pipe while another process waits.
            # A blocking second client in this same GUI thread starves the
            # incumbent and is not a valid Windows IPC integration test.
            code = ("from PySide6.QtCore import QCoreApplication; import sys; "
                    "from zone.lifecycle import InstanceGuard; app=QCoreApplication([]); "
                    "client=InstanceGuard(sys.argv[1],lambda:None); "
                    "print(client.start_or_activate(),client.server.isListening()); client.close()")
            process = None
            try:
                self.assertTrue(owner.start_or_activate())
                process = subprocess.Popen([sys.executable, "-c", code, tmp],
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                deadline = time.monotonic()+5
                while process.poll() is None and time.monotonic() < deadline:
                    self.app.processEvents()
                    time.sleep(.001)
                stdout, stderr = process.communicate(timeout=1)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertEqual(stdout.strip(), "False False")
                self.assertEqual(calls, ["opened"])
                self.assertTrue(owner.server.isListening())
            finally:
                if process is not None and process.poll() is None:
                    process.kill()
                    process.communicate()
                owner.close()

    def test_write_completion_uses_remaining_bytes_not_wait_return(self):
        socket = Mock()
        socket.write.return_value = 9
        socket.bytesToWrite.side_effect = [9, 0]
        socket.waitForBytesWritten.return_value = False
        self.assertTrue(InstanceGuard._write_request(socket, b"activate\n"))
        socket.bytesToWrite.side_effect = [9, 9]
        self.assertFalse(InstanceGuard._write_request(socket, b"activate\n"))

    def test_failed_listen_does_not_remove_existing_server(self):
        with tempfile.TemporaryDirectory() as tmp:
            guard = InstanceGuard(tmp, lambda: None)
            with patch.object(guard, "_send_activation", return_value=False), \
                 patch.object(guard.server, "listen", return_value=False), \
                 patch("zone.lifecycle.QLocalServer.removeServer") as remove:
                with self.assertRaises(RuntimeError):
                    guard.start_or_activate()
                remove.assert_not_called()
            guard.close()

    def test_update_no_owner_is_proven_and_invalid_digest_never_connects(self):
        with tempfile.TemporaryDirectory() as tmp:
            guard = InstanceGuard(tmp, lambda: None)
            try:
                self.assertFalse(guard.request_update("a"*64))
                self.assertFalse(guard.server.isListening())
                for invalid in ["", "A"*64, "a"*63, "a"*64+"\n", "../../anything"]:
                    with self.assertRaises(ValueError):
                        guard.request_update(invalid)
            finally:
                guard.close()

    def test_update_ack_requires_callback_and_binds_exact_target_digest(self):
        with tempfile.TemporaryDirectory() as tmp:
            requests = []
            def prepare(digest, ack):
                requests.append(digest)
                QTimer.singleShot(10, lambda: ack(True))
            owner = InstanceGuard(tmp, lambda: None, prepare_update=prepare)
            self.assertTrue(owner.start_or_activate())
            code = ("from PySide6.QtCore import QCoreApplication; import sys; "
                    "from zone.lifecycle import InstanceGuard; app=QCoreApplication([]); "
                    "client=InstanceGuard(sys.argv[1],lambda:None); "
                    "print(client.request_update('b'*64,timeout_ms=3000)); client.close()")
            process = subprocess.Popen([sys.executable, "-c", code, tmp],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic()+5
                while process.poll() is None and time.monotonic() < deadline:
                    self.app.processEvents()
                    time.sleep(.001)
                stdout, stderr = process.communicate(timeout=1)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertEqual(requests, ["b"*64])
                self.assertEqual(stdout.strip(), "True")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
                owner.close()


if __name__ == "__main__":
    unittest.main()
