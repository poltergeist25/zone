import Foundation
import AppKit

/// Successful stable capture commits automatically; no real camera or user profile.
@main struct AutoCaptureChecks {
    static func main() throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("zone-auto-capture-\(UUID().uuidString)")
        defer{try? FileManager.default.removeItem(at:root)}
        let neutral=PoseFeatures([0,0.4,0,0.3,0.6,0.5])
        let store=PreferencesStore(url:root.appendingPathComponent("normal/preferences.json"))
        let model=CameraModel(store:store,observesLifecycle:false,presentsVisuals:false)
        model.select("synthetic-auto");model.active=true;model.stage="green"
        model.receive(neutral,at:0);model.capture()
        for i in 1...20 {model.receive(neutral,at:Double(i)/10)}
        precondition(!model.monitoring && !model.hasSavedCalibration,"Incomplete capture cannot commit")
        for i in 21...32 {model.receive(neutral,at:Double(i)/10)}
        precondition(model.monitoring && model.hasSavedCalibration && !model.capturing && model.persistenceMessage==nil,"Successful3s capture saves and starts without confirm")
        let saved=try store.load()!.calibration(for:"synthetic-auto")!
        precondition(saved.baseline==model.engine.baseline!.values)
        let reloaded=CameraModel(store:store,observesLifecycle:false,presentsVisuals:false)
        precondition(reloaded.hasSavedCalibration && !reloaded.active,"Automatic save survives an ordinary camera-off launch")
        model.stop();reloaded.stop()

        let folder=root.appendingPathComponent("retry"),backup=root.appendingPathComponent("retained")
        let retryStore=PreferencesStore(url:folder.appendingPathComponent("preferences.json"))
        var preferences=PosturePreferences();preferences.selectedCameraID="synthetic-retry"
        preferences.calibrations["synthetic-retry"]=SavedCalibration(cameraID:"synthetic-retry",baseline:neutral.values,yellow:0.8,red:1.8)
        try retryStore.save(preferences)
        let original=try Data(contentsOf:retryStore.url)
        let retry=CameraModel(store:retryStore,observesLifecycle:false,presentsVisuals:false)
        retry.active=true;retry.stage="monitoring";retry.restartSetup()
        var replacement=neutral;replacement.centerY=0.6
        retry.receive(replacement,at:10);retry.capture()
        // Deterministically block only this synthetic store, retaining its exact old bytes.
        try FileManager.default.moveItem(at:folder,to:backup)
        try Data("blocked".utf8).write(to:folder)
        for i in 1...32 {retry.receive(replacement,at:10+Double(i)/10)}
        precondition(!retry.monitoring && retry.stage=="review" && retry.persistenceMessage != nil,"Write failure cannot claim successful automatic start")
        precondition(retry.canUndoHeightReset,"Failed automatic commit keeps Go back available")
        let retained=try Data(contentsOf:backup.appendingPathComponent("preferences.json"))
        precondition(retained==original,"Failed save cannot destroy the prior height")
        try FileManager.default.removeItem(at:folder)
        try FileManager.default.moveItem(at:backup,to:folder)
        retry.confirm()
        precondition(retry.monitoring && retry.persistenceMessage==nil && !retry.canUndoHeightReset,"Retrying after storage repair completes the same captured height")
        let retried=try retryStore.load()!.calibration(for:"synthetic-retry")!
        precondition(retried.baseline==retry.engine.baseline!.values)
        retry.stop()
        print("PASS: incomplete capture isolation, automatic save/start, camera-off reload, failed-write retention/Go back and same-capture retry; synthetic only")
    }
}
