# Third-party components

The root MIT license covers original Zone application source. It does not relicense third-party libraries, models, notices or proprietary operating-system SDKs.

## Mac

Zone uses Swift and Apple's macOS frameworks, including SwiftUI, AppKit, AVFoundation, Vision and VideoToolbox. Build with an appropriately licensed Apple SDK. This repository does not redistribute the SDK, framework binaries, signing identities or certificates.

## Windows

See [windows/THIRD-PARTY.md](windows/THIRD-PARTY.md) and [packaging/licensing.md](windows/packaging/licensing.md) for component terms and replacement/source instructions. In particular, Qt/PySide/Shiboken use their LGPL terms, MediaPipe and the face-model components have their upstream Apache notices, and other dependencies retain their original notices. The model is not vendored; bootstrap fetches the official pinned version and verifies its SHA-256.

Packaging scripts collect notices from the actual build environment. A source-only checkout does not bundle Microsoft runtime DLLs or satisfy a new builder's separate Microsoft tool/runtime license requirements. Official installers must retain their exact dependency notices and any required source companion. Published upstream URLs and hashes are in the packaging manifests.

Source publication does not change the terms of third-party code or the permission requirements for signing/distributing a new binary.
