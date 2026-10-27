"""Windows lifetime guards. No camera, settings or networking ownership.

Only activation and a digest-bound update request cross the per-user local
pipe. Sleep, lock and sign-out stop the owning session; wake/unlock never
restart a camera.
"""
import ctypes
import hashlib
import os
from pathlib import Path
import platform
import re
import time

from PySide6.QtCore import QAbstractNativeEventFilter, QTimer
from PySide6.QtNetwork import QLocalServer, QLocalSocket


def instance_name(profile):
    canonical = os.path.normcase(str(Path(profile).resolve()))
    return "Gramercy.Zone." + hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:32]


class InstanceGuard:
    """Retain this object until shutdown; False means an owner was activated.

    Never remove a possibly live pipe/socket on failed connection. Windows
    named pipes disappear with their owner, so no stale-file removal is needed.
    A hung or inaccessible incumbent fails visibly instead of opening a second
    camera owner.
    """
    def __init__(self, profile, activate, parent=None, prepare_update=None):
        self.name = instance_name(profile)
        self.activate = activate
        self.prepare_update = prepare_update
        self.server = QLocalServer(parent)
        self.server.setSocketOptions(QLocalServer.SocketOption.UserAccessOption)
        self.server.newConnection.connect(self._accept)
        self.connections = set()
        self.updating = set()

    def _send_activation(self):
        socket = QLocalSocket()
        socket.connectToServer(self.name)
        if not socket.waitForConnected(350):
            socket.abort()
            return False
        if not self._write_request(socket, b"activate\n"):
            socket.abort()
            raise RuntimeError("Zone is already running but could not receive the open request.")
        reply = self._read_reply(socket, 1500)
        socket.abort()
        if reply != b"opened\n":
            raise RuntimeError("Zone is already running but did not confirm opening its controls.")
        return True

    @staticmethod
    def _write_request(socket, request):
        if socket.write(request) != len(request):
            return False
        if socket.bytesToWrite():
            socket.waitForBytesWritten(1000)
        # In Windows Qt, the completion notification may already have drained
        # the buffer before waitForBytesWritten begins; its False return alone
        # is not failure. The remaining bytes are the actual write condition.
        return socket.bytesToWrite() == 0

    @staticmethod
    def _read_reply(socket, timeout_ms):
        deadline = time.monotonic()+max(1, min(30000, timeout_ms))/1000
        while not socket.canReadLine() and time.monotonic() < deadline:
            if socket.bytesAvailable() > 32:
                break
            if not socket.waitForReadyRead(max(1, int((deadline-time.monotonic())*1000))):
                break
        return bytes(socket.readAll())

    def start_or_activate(self):
        if self._send_activation():
            return False
        if self.server.listen(self.name):
            return True
        # Reconcile a simultaneous launch once. Never unlink another owner.
        if self._send_activation():
            return False
        raise RuntimeError("Zone could not acquire its session. Close the existing Zone process and try again.")

    def request_update(self, target_sha256, timeout_ms=10000):
        """Ask the same-user owner to prepare its fixed update handoff.

        True means it acknowledged cleanup; False means no incumbent was
        proven by acquiring and releasing the pipe name. An inaccessible or
        stalled owner is an error, never permission to force-close it.
        The caller still verifies actual process exit before replacing files.
        """
        if not isinstance(target_sha256, str) or re.fullmatch(r"[0-9a-f]{64}", target_sha256) is None:
            raise ValueError("Update target must be a lowercase SHA-256 digest")
        request = b"prepare-update " + target_sha256.encode("ascii") + b"\n"
        socket = QLocalSocket()
        socket.connectToServer(self.name)
        if not socket.waitForConnected(350):
            socket.abort()
            if self.server.listen(self.name):
                self.server.close()
                return False
            raise RuntimeError("The running Zone session could not be reached for updating.")
        if not self._write_request(socket, request):
            socket.abort()
            raise RuntimeError("Zone could not receive the update request.")
        # Read the bounded, newline-terminated response without trusting partial
        # bytes or an EOF as a successful handoff.
        reply = self._read_reply(socket, timeout_ms)
        socket.abort()
        if reply != b"ready\n":
            raise RuntimeError("Zone did not confirm update cleanup. Its files were not safe to replace.")
        return True

    def _accept(self):
        while self.server.hasPendingConnections():
            socket = self.server.nextPendingConnection()
            self.connections.add(socket)
            socket.readyRead.connect(lambda s=socket: self._read(s))
            socket.disconnected.connect(lambda s=socket: self._drop(s))
            QTimer.singleShot(1000, lambda s=socket: self._expire_initial(s))
            if socket.bytesAvailable():
                self._read(socket)

    def _read(self, socket):
        if socket not in self.connections or socket in self.updating:
            return
        if socket.bytesAvailable() > 96:
            socket.abort()
            self._drop(socket)
            return
        if socket.canReadLine():
            command = bytes(socket.readLine(97))
            if command == b"activate\n":
                try:
                    self.activate()
                except Exception:
                    self._reply(socket, b"failed\n")
                else:
                    self._reply(socket, b"opened\n")
                return
            elif re.fullmatch(rb"prepare-update [0-9a-f]{64}\n", command) and self.prepare_update is not None:
                self.updating.add(socket)
                QTimer.singleShot(10000, lambda s=socket: self._expire(s))
                try:
                    self.prepare_update(command[15:-1].decode("ascii"), lambda ready=True, s=socket: self._ack_update(s, ready))
                except Exception:
                    self._ack_update(socket, False)
                return
            socket.disconnectFromServer()
            self._drop(socket)

    def _ack_update(self, socket, ready):
        if socket in self.connections and socket in self.updating:
            self.updating.discard(socket)
            self._reply(socket, b"ready\n" if ready else b"failed\n")

    def _reply(self, socket, reply):
        socket.write(reply)
        socket.flush()
        # Keep the socket alive until Qt drains its response and emits
        # disconnected. Destroying it now can discard a Windows pipe write.
        socket.disconnectFromServer()

    def _expire_initial(self, socket):
        if socket not in self.updating:
            self._expire(socket)

    def _expire(self, socket):
        if socket in self.connections:
            socket.abort()
            self._drop(socket)

    def _drop(self, socket):
        self.updating.discard(socket)
        if socket in self.connections:
            self.connections.remove(socket)
            socket.deleteLater()

    def close(self):
        for socket in list(self.connections):
            socket.abort()
            self._drop(socket)
        self.server.close()


WM_POWERBROADCAST = 0x0218
WM_WTSSESSION_CHANGE = 0x02B1
WM_ENDSESSION = 0x0016
PBT_APMSUSPEND = 4
WTS_SESSION_LOGOFF = 6
WTS_SESSION_LOCK = 7


def interruption_reason(message, wparam):
    """Pure classifier: resume and unlock intentionally have no action."""
    if message == WM_POWERBROADCAST and wparam == PBT_APMSUSPEND:
        return "Sleep"
    if message == WM_WTSSESSION_CHANGE:
        return {WTS_SESSION_LOGOFF: "Signing out", WTS_SESSION_LOCK: "Session locked"}.get(wparam)
    if message == WM_ENDSESSION and wparam:
        return "Signing out"
    return None


class _Message(ctypes.Structure):
    # Only the leading MSG fields are read. Pointer-sized WPARAM/LPARAM retain
    # their Windows x64 sizes; message remains the Windows 32-bit UINT.
    _fields_ = [("hwnd", ctypes.c_void_p), ("message", ctypes.c_uint32),
                ("wparam", ctypes.c_size_t), ("lparam", ctypes.c_ssize_t)]


class WindowsSessionEvents(QAbstractNativeEventFilter):
    def __init__(self, app, hwnd, interrupted):
        super().__init__()
        self.app, self.hwnd, self.interrupted = app, int(hwnd), interrupted
        self.registered = False
        self.installed = False
        self.wts = None
        if platform.system() != "Windows":
            return
        self.wts = ctypes.WinDLL("Wtsapi32", use_last_error=True)
        self.wts.WTSRegisterSessionNotification.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        self.wts.WTSRegisterSessionNotification.restype = ctypes.c_int
        self.wts.WTSUnRegisterSessionNotification.argtypes = [ctypes.c_void_p]
        self.wts.WTSUnRegisterSessionNotification.restype = ctypes.c_int
        if not self.wts.WTSRegisterSessionNotification(self.hwnd, 0):
            raise OSError(ctypes.get_last_error(), "Could not observe Windows session changes")
        self.registered = True
        self.app.installNativeEventFilter(self)
        self.installed = True

    def nativeEventFilter(self, event_type, message):
        if bytes(event_type) not in (b"windows_generic_MSG", b"windows_dispatcher_MSG"):
            return False, 0
        native = ctypes.cast(int(message), ctypes.POINTER(_Message)).contents
        if native.hwnd == self.hwnd:
            reason = interruption_reason(native.message, native.wparam)
            if reason:
                self.interrupted(reason)
        # Observing a notification must not consume Windows' normal handling.
        return False, 0

    def close(self):
        if self.installed:
            self.app.removeNativeEventFilter(self)
            self.installed = False
        if self.registered:
            self.wts.WTSUnRegisterSessionNotification(self.hwnd)
            self.registered = False
