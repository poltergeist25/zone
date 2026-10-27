#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
POSTURE_BUILD_ROOT="${POSTURE_BUILD_ROOT:-$PWD/build}"
POSTURE_SIGN_IDENTITY="${POSTURE_SIGN_IDENTITY:--}"
mkdir -p "$POSTURE_BUILD_ROOT"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 Sources/Engine.swift Tests/main.swift -o "$POSTURE_BUILD_ROOT/engine-checks"
"$POSTURE_BUILD_ROOT/engine-checks"
xcrun swiftc -swift-version 5 -O -parse-as-library Sources/Engine.swift Sources/Preferences.swift Tests/LandmarkHeightChecks.swift -o "$POSTURE_BUILD_ROOT/landmark-height-checks"
"$POSTURE_BUILD_ROOT/landmark-height-checks"
xcrun swiftc -swift-version 5 -O -parse-as-library Sources/AnalysisCadence.swift Tests/AnalysisCadenceChecks.swift -o "$POSTURE_BUILD_ROOT/analysis-cadence-checks"
"$POSTURE_BUILD_ROOT/analysis-cadence-checks"
xcrun swiftc -swift-version 5 -O -parse-as-library Sources/FaceContinuity.swift Tests/FaceContinuityChecks.swift -o "$POSTURE_BUILD_ROOT/face-continuity-checks"
"$POSTURE_BUILD_ROOT/face-continuity-checks"
xcrun swiftc -swift-version 5 -O -parse-as-library Sources/FaceContinuity.swift Tests/ReturnAnchorChecks.swift -o "$POSTURE_BUILD_ROOT/return-anchor-checks"
"$POSTURE_BUILD_ROOT/return-anchor-checks"
xcrun swiftc -swift-version 5 -O -parse-as-library Sources/FaceContinuity.swift Tests/HeadTurnChecks.swift -o "$POSTURE_BUILD_ROOT/head-turn-checks"
"$POSTURE_BUILD_ROOT/head-turn-checks"
xcrun swiftc -swift-version 5 -O -parse-as-library Sources/LandmarkPatchTracker.swift Tests/LandmarkPatchTrackerChecks.swift -o "$POSTURE_BUILD_ROOT/patch-checks" -framework CoreVideo -framework CoreGraphics
for radius in 7 10 12; do "$POSTURE_BUILD_ROOT/patch-checks" "$radius"; done
xcrun swiftc -swift-version 5 -O -parse-as-library Sources/TrackingPerformance.swift Tests/TrackerAblationChecks.swift -o "$POSTURE_BUILD_ROOT/tracker-ablation-checks"
"$POSTURE_BUILD_ROOT/tracker-ablation-checks"
xcrun swiftc -swift-version 5 -O -parse-as-library Sources/Engine.swift Sources/FaceContinuity.swift Sources/LandmarkPatchTracker.swift Sources/SeatedPose.swift Tests/SeatedDetection.swift -o "$POSTURE_BUILD_ROOT/seated-checks" -framework Vision
"$POSTURE_BUILD_ROOT/seated-checks"
xcrun swiftc -swift-version 5 -O -parse-as-library Sources/Engine.swift Sources/Preferences.swift Tests/PreferencesTests.swift -o "$POSTURE_BUILD_ROOT/preferences-checks"
"$POSTURE_BUILD_ROOT/preferences-checks"
APP="$POSTURE_BUILD_ROOT/Zone.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -whole-module-optimization -parse-as-library -target arm64-apple-macos14.0 Sources/*.swift -o "$APP/Contents/MacOS/PostureZone" -framework SwiftUI -framework AppKit -framework AVFoundation -framework Vision -framework VideoToolbox
cp -X Info.plist "$APP/Contents/Info.plist"
# A distinct icon resource invalidates old AppIcon cache entries.
cp -X AppIcon.icns "$APP/Contents/Resources/ZoneIcon.icns"
rm -f "$APP/Contents/Resources/AppIcon.icns"
# Preserve a fresh bundle modification time through the canonical updater.
touch "$APP"
codesign --force --sign "$POSTURE_SIGN_IDENTITY" --timestamp=none --options runtime --entitlements PostureZone.entitlements "$APP"
codesign --verify --strict --verbose=2 "$APP"
printf '%s\n' "$APP"
