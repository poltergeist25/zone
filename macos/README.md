# Build Zone for Mac

Requirements: an Apple Silicon Mac, macOS 14 or later, and Xcode Command Line Tools with the macOS SDK.

```sh
cd macos
./build.sh
```

The script runs synthetic engine checks, compiles the app and ad-hoc signs the development bundle. Output defaults to `macos/build/Zone.app`; it does not install, launch, open a camera or replace an existing app. Override `POSTURE_BUILD_ROOT` to use another build directory. Set `POSTURE_SIGN_IDENTITY` to your own valid signing identity if needed. Public Developer ID distribution additionally requires your Apple authorization, notarization and packaging; an ad-hoc build is a local development build.

For a separate, synthetic update-helper regression suite:

```sh
python3 -m unittest discover -s Tests -p 'test_*.py'
```

All application Swift sources are in `Sources/`; additional synthetic and explicit-input development checks are in `Tests/`. `tools/UpdateHost.swift` and `install-update.py` retain the local update-handoff implementation. The latter's publication CLI intentionally requires the maintainer's external ownership/admission adapter, which is not part of the application or this public checkout. It is not needed to build Zone and is not a standalone public installer.

To try a development build, first quit any existing Zone instance normally, then open your separately built app. Opening Zone starts with camera off. Explicitly select a camera, turn it on and set your comfortable height; no private profile is included in this repository.

See the repository [privacy guide](../PRIVACY.md) for source pointers and local-storage behavior.
