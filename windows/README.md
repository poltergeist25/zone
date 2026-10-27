# Build Zone for Windows

Target: Windows 11 x64, Python 3.12 x64. The normal app entrypoint requires Windows. Pure synthetic tests can also be run in an appropriate development environment; they do not prove physical webcam compatibility.

From this directory in PowerShell:

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements.txt
.\.venv\Scripts\python bootstrap.py
.\.venv\Scripts\python -m zone
```

Bootstrap explicitly downloads the official pinned face-model bundle and verifies its SHA-256. Ordinary application use loads the local model and does not download it. Camera access is off on launch; use Find cameras, explicitly select a device, turn Camera on, then set your comfortable height.

## Tests and packaging

```powershell
.\.venv\Scripts\python -m unittest discover -s tests -p 'test_*.py' -v
.\build.ps1
```

The build creates an unsigned PyInstaller one-directory development app in `dist/Zone`. `-Qualify` runs explicit synthetic video checks; its fixture utility downloads a public NASA/scikit-image still and makes a simulated-motion video. These are development checks, not real camera or medical evidence. No private footage is included.

Installer/signing options in `build.ps1` need the corresponding official tools, runtime redistribution rights and your own signing identity. The Visual Studio acquisition helper requires an explicit `-AcceptLicense` argument from the person running it; no approval from the original maintainer is transferred to other builders. It does not run during ordinary app use or the default portable build.

Keep the licenses, notices and any required dependency-source companion with redistributed binaries. See [THIRD-PARTY.md](THIRD-PARTY.md), [packaging/licensing.md](packaging/licensing.md), and [source-manifest.json](packaging/source-manifest.json).

Settings and progress are local. The app has no cloud account, camera upload, microphone-capture or analytics feature. See [the privacy guide](../PRIVACY.md) and inspect `zone/` for the complete application implementation.
