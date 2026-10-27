# Zone

**Stand tall.** A quiet cue when you slouch at your desk.

Zone is a camera-relative posture reminder for macOS and Windows. Set a comfortable height with a fixed camera; Zone notices when your face sits lower and shows a visual cue. Processing happens on your computer. Camera footage is not recorded or uploaded by the application.

[Website and downloads](https://zoneatwork.com/) · [How privacy works](PRIVACY.md) · [Third-party licenses](THIRD_PARTY.md)

## Source

| Platform | Implementation | Build instructions |
| --- | --- | --- |
| macOS | SwiftUI, AppKit, AVFoundation and Apple Vision | [macos/README.md](macos/README.md) |
| Windows | Python, Qt for Python and MediaPipe | [windows/README.md](windows/README.md) |

The app implementations, synthetic tests and build/packaging sources are included. No account, cloud inference service or API key is needed to run Zone. Building the Windows app downloads dependencies and a checksum-pinned model; ordinary application use reads the model locally. The Windows single-instance/update connection is local IPC, not a camera upload service.

The source snapshot corresponds to the Mac build 83 / Windows 1.0.0 development tree. Public-build adjustments make signing configurable and Microsoft tool installation explicitly opt-in; application source files are unchanged. Published installers and development source builds have different signing and packaging conditions. This repository does not claim reproducible binary equivalence, a completed independent audit, or physical-device qualification on every camera.

Zone measures face height relative to a personal reference. It does not measure the spine or diagnose posture or medical conditions. Keep the camera fixed and recalibrate when your setup changes.

## Development

Use the platform instructions above. Tests use synthetic settings and fixtures. Optional inference/qualification tools require explicit inputs; they do not establish real webcam accuracy. Building does not install over or launch an existing app automatically.

Original application source is available under the [MIT License](LICENSE). Third-party libraries, models, SDKs and their notices retain their own terms; see [THIRD_PARTY.md](THIRD_PARTY.md). The source repository contains no Apple/Microsoft signing keys, proprietary SDKs, model binaries, installed profiles or recordings.

Support: [help@zoneatwork.com](mailto:help@zoneatwork.com). For suspected vulnerabilities, see [SECURITY.md](SECURITY.md).
