# Windows distribution preparation

The installer is per user, requires no administrator privilege, and targets
Windows 11 x64. It installs an ordinary taskbar/tray application, creates a Start
menu shortcut, and offers an unchecked desktop shortcut. It creates no service,
startup task, camera permission request or automatic camera session. Uninstall
leaves `%LOCALAPPDATA%\Gramercy Systems\Zone Windows` intact.

Build integration, from the Windows target directory:

```powershell
& $python packaging/prepare.py --prepare --notices packaging/generated-notices
# PyInstaller options, in addition to existing options:
# --icon packaging/zone.ico --version-file packaging/version_info.txt
# --add-data 'packaging/generated-notices;licenses'
& $python packaging/prepare.py --manifest dist/Zone
& 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe' packaging/Zone.iss
& packaging/test-installer.ps1 -Installer dist/Zone-1.0.0-Windows-x64-Setup.exe -Video ci-fixture/posture-motion.avi -Manifest ci-fixture/manifest.json -Output ci-evidence/installer
```

Use the existing runner's Inno Setup compiler if present; do not silently download
an unverified compiler or purchase a signing service. The generated ICO, version
resource and version include are build inputs. `version.json` is their source.
The installer intentionally has no signing configuration. A successful installer
test proves installation, the installed frozen executable's replay/widgets,
uninstall, and preservation of an isolated profile, not camera performance.

`prepare.py --notices ...` retains verbatim license/notice files from the exact
installed build environment and emits a hash inventory. It explicitly does not
approve public redistribution: reconcile that environment with the actual
bundled modules, preserve Qt/PySide/Shiboken corresponding source and replacement
instructions, and resolve the specific Face Landmarker model/component terms.
An unsigned, incompletely licensed candidate must not be labeled public ready.

Relevant primary sources, checked October 26, 2026:

- [Inno per-user privileges](https://jrsoftware.org/ishelp/topic_setup_privilegesrequired.htm)
- [Inno application close behavior](https://jrsoftware.org/ishelp/topic_setup_closeapplications.htm)
- [Qt for Python licenses](https://doc.qt.io/qtforpython-6.10/licenses.html)
- [Qt LGPL obligations](https://www.qt.io/development/open-source-lgpl-obligations)
- [Face Landmarker model provenance](https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker)

Public release still requires the selected code-signing identity, verified
signature/timestamp on the EXE and installer, an approved download/update host,
and completed notices/source obligations. None of those account or publication
actions are performed by these scripts.
