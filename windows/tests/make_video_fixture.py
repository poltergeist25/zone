"""Build-time public still -> explicitly simulated motion video, never a camera.

This is a deterministic integration fixture, not evidence of real head turns,
physical slouch accuracy, webcam drivers or customer performance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request
import cv2
import numpy as np

SOURCE = "https://raw.githubusercontent.com/scikit-image/scikit-image/v0.25.2/skimage/data/astronaut.png"
SHA256 = "88431cd9653ccd539741b555fb0a46b61558b301d4110412b5bc28b5e3ea6cb5"


def make(output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    data = urllib.request.urlopen(SOURCE, timeout=30).read(2_000_000)
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError("Public test image checksum mismatch")
    source = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
    if source is None:
        raise ValueError("Public test image could not be decoded")
    source = cv2.resize(source, (384, 216))
    # All transforms operate on image pixels; every input frame subsequently
    # traverses actual video decoding and the production face-model adapter.
    phases = [
        ("calibrate", 24, 0, 0),
        ("green", 12, 0, 0),
        ("yellow", 24, 0, 10),
        ("red", 30, 0, 23),
        ("recovery", 12, 0, 0),
        ("side_exit", 6, 340, 0),
        ("return", 12, 0, 0),
        ("occluded", 6, None, None),
        ("second_return", 12, 0, 0),
    ]
    video = output/"posture-motion.avi"
    writer = cv2.VideoWriter(str(video), cv2.VideoWriter_fourcc(*"MJPG"), 6, (384, 216))
    if not writer.isOpened():
        raise RuntimeError("MJPG fixture encoder is unavailable")
    rows = []
    try:
        for phase, count, x, y in phases:
            for _ in range(count):
                frame = np.zeros_like(source) if x is None else cv2.warpAffine(
                    source, np.float32([[1, 0, x], [0, 1, y]]), (384, 216))
                writer.write(frame)
                rows.append(phase)
    finally:
        writer.release()
    manifest = {"schema": 1, "source_url": SOURCE, "source_sha256": SHA256,
                "source_kind": "public NASA/scikit-image still, artificially translated/occluded",
                "fps": 6, "video_sha256": hashlib.sha256(video.read_bytes()).hexdigest(),
                "phases": rows,
                "claim_limit": "No physical camera, real head turn, person-specific accuracy or CPU acceptance"}
    (output/"manifest.json").write_text(json.dumps(manifest, indent=2)+"\n", encoding="utf-8")
    print(f"Generated {len(rows)} simulated frames in {video}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    make(parser.parse_args().output)
