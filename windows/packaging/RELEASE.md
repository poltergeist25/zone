# Windows distribution from source

`../build.ps1` builds a portable unsigned development application. `-Qualify` runs explicit synthetic-video tests. `-Installer` additionally requires an official Inno Setup installation and `-OfficialRuntimeDirectory` pointing to compatible runtime files the builder is authorized to redistribute. `-CertificateThumbprint` selects the builder's own existing signing identity.

Keep the final installer, exact dependency notices, matching source companion and SHA-256 checksums together. Collect notices and manifests from the actual build rather than reusing another developer's environment receipt. Signed release preparation is separate from source publication. This repository grants no Apple/Microsoft signing account or redistribution entitlement.

The installer is per-user, does not auto-launch tracking on an ordinary install, and preserves local settings/progress on uninstall. A running update uses the application's one-use lifecycle handoff; see `../zone/update.py`, `../zone/lifecycle.py`, and `Zone.iss`.

Application camera frames stay local and are not recorded by Zone. Settings, calibration and daily progress are saved locally. Build/qualification scripts can fetch public dependencies and write synthetic test artifacts. Real Windows camera compatibility and performance must be checked on the intended device; synthetic tests do not establish those outcomes.

See `licensing.md`, `source-manifest.json`, `runtime-notices/README.md`, and `../THIRD-PARTY.md`.
