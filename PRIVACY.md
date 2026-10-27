# Privacy and data flow

This describes the application code in this source snapshot. It is a guide to inspection, not an independent audit or proof that any particular downloaded executable was built from these files.

## Camera processing

- **Mac:** [CameraModel.swift](macos/Sources/CameraModel.swift) owns capture; [SeatedPose.swift](macos/Sources/SeatedPose.swift), [FaceContinuity.swift](macos/Sources/FaceContinuity.swift) and [LandmarkPatchTracker.swift](macos/Sources/LandmarkPatchTracker.swift) handle on-device tracking using Apple frameworks.
- **Windows:** [sensor.py](windows/zone/sensor.py) owns capture and local MediaPipe inference. [bootstrap.py](windows/bootstrap.py) downloads the pinned model during setup; the application verifies and loads a local file.
- The application has no camera-video upload, camera recording, microphone-capture or analytics feature. It uses camera frames and landmarks in memory to produce the local reminder. No cloud inference account or API key is needed.

## What is saved

Local settings include the selected camera, personal calibration and reminder preferences. Progress stores daily/hourly aggregates. Camera frames and face photographs are not stored as progress history. Inspect [Preferences.swift](macos/Sources/Preferences.swift), [DailyProgress.swift](macos/Sources/DailyProgress.swift), [core.py](windows/zone/core.py) and [progress.py](windows/zone/progress.py).

Mac data is in the user's application-support directory. Windows data is under `%LOCALAPPDATA%\Gramercy Systems\Zone Windows`. Update handoff files carry local lifecycle/settings state so an update can release and restore the app safely. See [UpdateResume.swift](macos/Sources/UpdateResume.swift), [update.py](windows/zone/update.py) and [lifecycle.py](windows/zone/lifecycle.py).

## Network and test boundaries

Dependency installation, model bootstrap and optional fixture generation fetch public build inputs. They are not background camera-upload paths. Windows uses Qt local IPC for single-instance control and update handoff; these local sockets are not an Internet service. The website and download host receive ordinary web requests separately from application camera processing.

Tests and qualification tools can write explicitly requested synthetic fixtures, reports or renderings. Those development utilities are separate from ordinary camera use. The operating system, camera driver and separately installed software have their own behavior and permissions; this document does not audit them.

Opt-in, expiring Mac development diagnostics can also save local aggregate performance counters. They do not record camera frames or create an upload path. This repository therefore does not claim that nothing is ever saved: settings, progress, lifecycle state and explicit diagnostics have distinct local storage purposes.

## Limits

Face-height tracking is not a measurement of spine geometry, health, or identity. Moving/reframing the camera can change the signal. Source transparency makes these paths inspectable; no independent security-audit certification is claimed.
