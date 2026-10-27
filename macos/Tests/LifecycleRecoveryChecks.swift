import Foundation
import AppKit
import AVFoundation

/// Exercises the installed notification handlers. It never opens a camera,
/// sends a real sleep event, or reads/writes the normal application profile.
@main struct LifecycleRecoveryChecks {
    static func main() throws {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("zone-lifecycle-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=PreferencesStore(url:directory.appendingPathComponent("preferences.json"))
        let baseline=PoseFeatures([0,0.4,0,0.3,0.6,0.5])
        let cameraID="synthetic-lifecycle-camera"
        var preferences=PosturePreferences()
        preferences.selectedCameraID=cameraID;preferences.yellow=0.8;preferences.red=1.8
        preferences.calibrations[cameraID]=SavedCalibration(cameraID:cameraID,baseline:baseline.values,yellow:0.8,red:1.8)
        try store.save(preferences)
        let originalBytes=try Data(contentsOf:store.url)
        // Actual observers are enabled; discovery can list devices but no start()
        // or authorization request is invoked anywhere in this test.
        let model=CameraModel(store:store,observesLifecycle:true,presentsVisuals:false)
        defer {model.stop()}
        precondition(!model.active && !model.loading && !model.session.isRunning)
        func syntheticMonitoring() {
            precondition(model.engine.restoreValidated(baseline:baseline,yellow:0.8,red:1.8,delay:2))
            model.active=true;model.loading=false;model.stage="monitoring"
            model.receive(baseline,at:ProcessInfo.processInfo.systemUptime)
            precondition(model.monitoring && model.hasPose && model.score != nil)
        }
        func assertStopped(_ reason:String) throws {
            precondition(!model.active && !model.loading && !model.session.isRunning,reason)
            precondition(model.stage=="idle" && model.state=="idle" && !model.capturing && !model.paused && model.pauseUntil==nil)
            precondition(model.score==nil && !model.hasPose && model.landmarks.isEmpty && model.warningProgress==0 && !model.engine.alert)
            let appearance=ZoneAppearance.resolve(ZoneResult(state:model.state,score:model.score,alert:model.engine.alert),monitoring:model.monitoring,paused:model.paused,tracking:model.hasPose)
            precondition(appearance == .hidden,"Stopped state cannot request live visual feedback")
            precondition(model.hasSavedCalibration && model.yellow==0.8 && model.red==1.8)
            let currentBytes=try Data(contentsOf:store.url)
            precondition(currentBytes==originalBytes,"Lifecycle interruption must not rewrite confirmed preferences")
        }
        syntheticMonitoring()
        let unrelatedSession=AVCaptureSession()
        NotificationCenter.default.post(name:AVCaptureSession.runtimeErrorNotification,object:unrelatedSession)
        precondition(model.active && model.monitoring,"Another session's error must not stop Zone")
        NotificationCenter.default.post(name:AVCaptureSession.runtimeErrorNotification,object:model.session)
        try assertStopped("This session's runtime error must stop tracking")
        precondition(model.message.hasPrefix("Camera interrupted"))

        syntheticMonitoring();model.pauseFor(minutes:5)
        NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.willSleepNotification,object:nil)
        try assertStopped("Sleep handler must stop monitoring and cancel pause deadlines")
        precondition(model.message.hasPrefix("Camera stopped before sleep"))

        // A failed replacement and a canceled opening must retain the old setup.
        syntheticMonitoring();model.restartSetup()
        var replacement=baseline;replacement.centerY=0.6
        model.engine.restoreValidated(baseline:replacement,yellow:0.6,red:1.4,delay:2)
        model.yellow=0.6;model.red=1.4;model.stage="review";model.capturing=true
        NotificationCenter.default.post(name:AVCaptureSession.runtimeErrorNotification,object:model.session)
        try assertStopped("Interrupted unconfirmed setup must retain the confirmed baseline")
        model.loading=true;model.state="ready"
        NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.willSleepNotification,object:nil)
        try assertStopped("Sleep while opening must cancel loading")
        model.confirm()
        try assertStopped("A stale confirm after stopping cannot persist an incomplete setup")

        let fresh=CameraModel(store:store,observesLifecycle:true,presentsVisuals:false)
        defer {fresh.stop()}
        precondition(!fresh.active && !fresh.loading && !fresh.session.isRunning && fresh.stage=="idle" && fresh.hasSavedCalibration)
        let recovered=try store.load()!.calibration(for:cameraID)!
        precondition(recovered.baseline==baseline.values && recovered.yellow==0.8 && recovered.red==1.8)
        print("PASS: exact-session runtime-error handler, unrelated-session isolation, sleep handler, paused/opening/setup cancellation, hidden stopped state, unchanged confirmed profile, camera-off recreation; notification simulation only, no real camera/sleep/Zoom")
    }
}
