"""Build-time model fetch. The installed application has no download path."""
import hashlib
from pathlib import Path
import urllib.request
from zone.sensor import MODEL_URL, MODEL_SHA256


def fetch(destination):
    destination = Path(destination)
    if destination.exists() and hashlib.sha256(destination.read_bytes()).hexdigest() == MODEL_SHA256:
        return destination
    data = urllib.request.urlopen(MODEL_URL, timeout=45).read(8_000_000)
    if hashlib.sha256(data).hexdigest() != MODEL_SHA256:
        raise RuntimeError("Model checksum mismatch; no file installed")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".download")
    temporary.write_bytes(data)
    temporary.replace(destination)
    return destination


if __name__ == "__main__":
    print(fetch(Path(__file__).parent/"assets"/"face_landmarker.task"))
