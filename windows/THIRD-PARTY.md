# Third-party components

The build preserves verbatim license/notice texts from its installed Python
distributions in `licenses/`, with an inventory and source hashes. The companion
`Zone-1.0.0-Dependency-Sources.zip` supplies corresponding Qt/PySide/Shiboken
source releases and replacement instructions. It must accompany the binary
download. Packaging source alone does not establish that every notice or source
artifact was built; inspect the actual build’s inventory.

- Qt for Python / PySide6 Essentials / Shiboken 6.10.2: LGPLv3 option, unmodified dynamic libraries in an onedir layout. https://doc.qt.io/qtforpython-6.10/licenses.html
- MediaPipe 0.10.32: Apache-2.0. https://github.com/google-ai-edge/mediapipe/blob/master/LICENSE
- Face Landmarker task bundle version 1: its official BlazeFace short-range, FaceMesh V2 and Blendshape V2 model cards explicitly specify Apache-2.0. Geometry metadata source also carries an Apache-2.0 header. Exact component hashes, authorship, notices and primary evidence are in `packaging/modelnotices/`. Bundle remains unmodified. https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker#models
- OpenCV contrib Python: Apache-2.0, with bundled third-party notices. https://github.com/opencv/opencv-python/blob/4.x/LICENSE.txt
- cv2-enumerate-cameras: MIT. https://github.com/lukehugh/cv2_enumerate_cameras
- PyInstaller: GPL with bootloader exception. https://pyinstaller.org/en/stable/license.html
- PortAudio: MIT, ordinary x64 loader library only, used by a transitive MediaPipe import. Zone does not record audio. Upstream copyright/license text is retained in `packaging/modelnotices/PortAudio-LICENSE.txt`. ASIO and other-platform binaries are excluded.

The optional FFmpeg codec plugin and Mesa software-OpenGL DLL are not included
in the current #6 package. Production camera access uses DirectShow; explicit
qualification uses OpenCV’s built-in MJPEG AVI reader. Unmodified upstream wheel
notices still mention components that the final file manifest shows are absent.
Prior artifacts containing FFmpeg remain prior engineering candidates; their
exact source recipe evidence is preserved in `packaging/ffmpeg-source-manifest.json`.

Transitive versions are captured in the actual Windows dependency freeze and
notice inventory. No medical claims or third-party face imagery ship in the app.
The source companion manifest and rebuild/replacement directions are in
`packaging/source-manifest.json` and `packaging/licensing.md`. Before public
release, verify the final bundled notices, source companion and durable source
availability alongside the binary. Source scripts or an unsigned engineering
build do not establish complete public-release approval.
