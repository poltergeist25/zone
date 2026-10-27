import AppKit

@main struct CameraSwitchChecks {
    static func main() throws {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("zone-switch-\(UUID().uuidString)")
        defer{try? FileManager.default.removeItem(at:directory)}
        let store=PreferencesStore(url:directory.appendingPathComponent("preferences.json"))
        let baseline=PoseFeatures([0,0.4,0,0.3,0.6,0.5])
        var saved=PosturePreferences();saved.selectedCameraID="synthetic-camera";saved.edgeEffectStyle = .tide
        saved.calibrations["synthetic-camera"]=SavedCalibration(cameraID:"synthetic-camera",baseline:baseline.values,yellow:0.6,red:1)
        try store.save(saved)
        let original=try Data(contentsOf:store.url)
        let model=CameraModel(store:store,observesLifecycle:false,presentsVisuals:false)
        precondition(!model.cameraEnabled && model.hasSavedCalibration,"Camera stays off on launch with saved zones")
        model.loading=true;precondition(model.cameraEnabled,"Opening camera switch reflects requested on state")
        model.setCameraEnabled(false)
        precondition(!model.active && !model.loading && !model.cameraEnabled,"Off cancels pending opening")
        model.active=true;model.stage="monitoring";model.paused=true
        precondition(!model.cameraEnabled,"Pause visibly switches camera off")
        model.setCameraEnabled(true) // No capture output in this synthetic model.
        precondition(model.active && !model.paused && model.cameraEnabled,"On resumes a paused session")
        precondition(model.engine.restoreValidated(baseline:baseline,yellow:0.6,red:1,delay:2))
        model.setCameraEnabled(false)
        precondition(!model.cameraEnabled && !model.active && model.hasSavedCalibration,"Off stops capture without removing saved setup")
        let after=try Data(contentsOf:store.url)
        precondition(after==original,"Camera switch preserves exact saved settings and calibration")
        print("PASS: camera switch opening cancellation, paused resume, off state, saved setup preservation; synthetic only")
    }
}
