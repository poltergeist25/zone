# Zone Windows third-party source and replacement instructions

This source companion accompanies the Zone 1.0.0 Windows x64 application. Keep
it available beside every corresponding binary download. It contains the exact
unmodified Qt 6.10.2, PySide6 6.10.2 and Shiboken6 6.10.2 source releases with
SHA-256 values published by the Qt project. The PySide setup archive includes
both PySide and Shiboken source. All original upstream licenses and per-file
notices remain in those archives. `source-manifest.json` identifies provenance.

Zone uses the LGPLv3 options for the bundled Qt/PySide/Shiboken components. It
does not claim a commercial Qt license. Qt and its bindings remain dynamically
linked in the PyInstaller one-directory layout. The LGPL/GPL texts and relevant
third-party license texts are also copied from the actual wheel distributions
into the application’s `licenses` directory. Their build-time inventory records
the original text hashes; reconcile that inventory with the final file manifest.

## Rebuilding and replacing the libraries

1. Close Zone using Quit app. Work on a copy of the installed application folder.
2. Extract the source archives. Build Qt for Windows x64 with the supported MSVC
   toolchain, CMake and Ninja; start with qtbase’s `configure -opensource
   -confirm-license -release -prefix <prefix>`, then `cmake --build .` and
   `cmake --install .`. Build qtsvg and qtimageformats against the same Qt prefix.
   Preserve compatible architecture, compiler/runtime, version, plugin layout
   and configuration. Upstream README and configure help are authoritative.
3. Build PySide6/Shiboken6 against that Qt installation and compatible CPython
   3.12 x64 using the pyside-setup archive’s documented `setup.py bdist_wheel`
   process and `--qtpaths=<prefix>\bin\qtpaths.exe`. The archive includes the
   binding generator/source and complete upstream build documentation.
4. Replace the dynamically loaded Qt DLLs/plugins under `_internal\PySide6`,
   the PySide6 `.pyd`/binding DLLs, and `_internal\shiboken6` as appropriate with
   ABI-compatible rebuilt versions. Retain the same directory/import names.
   The application is distributed as onedir rather than an opaque onefile
   archive so these shared components can be replaced.
5. Run the copied Zone executable. A modified copy will no longer match the
   release checksum or signature; those authenticity checks are not a license
   restriction on replacing LGPL components. Do not overwrite original receipts.

Zone imposes no restriction on modification of these LGPL components or reverse
engineering for debugging those modifications. No app EULA may override those
rights. Providing these instructions and upstream source is not a claim that a
particular custom build will be ABI compatible. The exact redistributed DLL/plugin
set must be checked against the source manifest before public publication.

Primary build and license documentation:

- https://doc.qt.io/qt-6.10/windows-building.html
- https://doc.qt.io/qtforpython-6.10/building_from_source/index.html
- https://doc.qt.io/qtforpython-6.10/licenses.html
- https://www.qt.io/development/open-source-lgpl-obligations

## Face model terms

The exact versioned Face Landmarker task bundle and its four components are
hashed in `modelnotices/components.json`. The official Face Landmarker guide
links its three model cards; each explicitly identifies Apache License 2.0.
The task detector is byte-identical to Google’s separately versioned BlazeFace
short-range float16 version 1 model. The mesh and blendshape correspondence
follows the official task guide’s bundle table and model cards. Geometry data’s
source carries the MediaPipe Apache-2.0 copyright header. These are concrete
upstream licensing evidence, not an inference from the Python package license.

No model or library is modified by Zone. The model bundle is verified before
loading and no runtime model download occurs. `modelnotices/NOTICE.txt`, full
Apache license text, upstream MediaPipe LICENSE and geometry source retain
attribution. Model cards are referenced rather than reproduced.

## Remaining release checks

The source companion must actually be built, checksum-verified and distributed
alongside the binary. Check copied license texts against the installed package
and all additional bundled third-party DLLs, including Microsoft runtime and
Mesa software OpenGL notices. This file is not a legal opinion or a blanket
redistribution approval. Public signing and download hosting remain separate.
