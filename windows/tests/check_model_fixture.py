"""Exercise actual MediaPipe inference on a public still, never a camera.

Usage: PYTHONPATH=. python tests/check_model_fixture.py MODEL PUBLIC_STILL
The image is an external test input and is not bundled or copied into source.
"""
import argparse
import json
import cv2
import mediapipe as mp
import numpy as np
from zone.sensor import verify_model, decode_faces
from zone.core import Session, Settings, Calibration


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model")
    parser.add_argument("image")
    args = parser.parse_args()
    verify_model(args.model)
    source = cv2.imread(args.image)
    assert source is not None, "Public fixture could not be decoded"
    source = cv2.resize(source, (384, 216))
    options = mp.tasks.vision.FaceLandmarkerOptions(
        base_options=mp.tasks.BaseOptions(model_asset_path=args.model),
        running_mode=mp.tasks.vision.RunningMode.VIDEO, num_faces=3,
        output_face_blendshapes=False, output_facial_transformation_matrixes=False)
    rows = []
    session = None
    with mp.tasks.vision.FaceLandmarker.create_from_options(options) as detector:
        for i, kind in enumerate(["present"]*5+["absent"]*5+["return"]*5):
            rgb = cv2.cvtColor(source if kind != "absent" else np.zeros_like(source), cv2.COLOR_BGR2RGB)
            result = detector.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb), 1000+i*167)
            faces = decode_faces(result)
            if session is None and faces:
                f = faces[0]
                session = Session(Settings(calibration=Calibration(f.eyes, f.nose, f.chin)))
                session.start()
            assert session is not None, "No valid facial anchors in the public fixture"
            state = session.tick(faces, 1+i*.167)
            rows.append({"step": kind, "face_count": len(faces), "state": state.state})
    assert rows[4]["state"] == "Green", rows
    assert rows[9]["face_count"] == 0 and rows[9]["state"] == "Finding you", rows
    assert rows[-1]["state"] == "Green", rows
    print(json.dumps({"kind": "public still model inference, not live Windows camera acceptance", "rows": rows}, indent=2))


if __name__ == "__main__":
    main()
