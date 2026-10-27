"""One-use, short-lived update intent. Ordinary launches never start a camera.

The per-user installer negotiates with the existing owner over its local pipe.
It may resume only the exact saved profile into the exact new executable hash.
This does not download updates or grant a publisher trust/signing identity.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import re
import tempfile
import time
from uuid import uuid4


def file_hash(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024*1024), b""):
            result.update(chunk)
    return result.hexdigest()


def settings_hash(profile):
    path = Path(profile)/"settings.json"
    return file_hash(path) if path.exists() else None


def write_handoff(profile, target_hash, *, camera, mode, page, visible, old_pid=None, now=None):
    if not isinstance(target_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", target_hash):
        raise ValueError("Invalid update target")
    if mode not in ("active", "paused", "off") or page not in (0, 1, 2):
        raise ValueError("Invalid update state")
    profile = Path(profile).resolve()
    profile.mkdir(parents=True, exist_ok=True)
    stamp = time.time() if now is None else now
    value = {"schema": 1, "operation": str(uuid4()), "target_sha256": target_hash,
             "profile": str(profile), "settings_sha256": settings_hash(profile),
             "old_pid": os.getpid() if old_pid is None else old_pid,
             "created": stamp, "expires": stamp+120, "camera": camera,
             "mode": mode, "page": page, "visible": bool(visible)}
    fd, name = tempfile.mkstemp(prefix=".update-", dir=profile)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, allow_nan=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, profile/"update-handoff.json")
    finally:
        if os.path.exists(name):
            os.unlink(name)


def process_alive(pid):
    if os.name == "nt":
        import ctypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
        kernel.OpenProcess.restype = ctypes.c_void_p
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            # Access denied is ambiguous and must not authorize resumption.
            return ctypes.get_last_error() != 87
        try:
            code = ctypes.c_uint32()
            kernel.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
            return not kernel.GetExitCodeProcess(handle, ctypes.byref(code)) or code.value == 259
        finally:
            kernel.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def consume_handoff(profile, executable, *, now=None, alive=process_alive):
    profile = Path(profile).resolve()
    path = profile/"update-handoff.json"
    consumed = profile/(".consumed-update-"+str(uuid4()))
    try:
        os.replace(path, consumed)
    except FileNotFoundError:
        return None
    try:
        if consumed.stat().st_size > 8192:
            raise ValueError("Update handoff is too large")
        value = json.loads(consumed.read_text(encoding="utf-8"))
        stamp = time.time() if now is None else now
        created, expires = value.get("created"), value.get("expires")
        if (value.get("schema") != 1 or value.get("profile") != str(profile)
                or not all(isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) for x in (created, expires))
                or not created <= stamp <= expires <= created+120
                or value.get("target_sha256") != file_hash(executable)
                or value.get("settings_sha256") != settings_hash(profile)
                or type(value.get("old_pid")) is not int or value["old_pid"] <= 0 or alive(value["old_pid"])
                or value.get("mode") not in ("active", "paused", "off")
                or type(value.get("page")) is not int or value["page"] not in (0, 1, 2)
                or type(value.get("visible")) is not bool or not isinstance(value.get("camera"), str)):
            raise ValueError("Update intent could not be verified. Camera remains off.")
        return value
    finally:
        consumed.unlink(missing_ok=True)
