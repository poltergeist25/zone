import Foundation
import AppKit

@main struct ReliabilityChecks {
    static func main() throws {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("zone-reliability-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=PreferencesStore(url:directory.appendingPathComponent("preferences.json"))
        let baseline=PoseFeatures([0,0.4,0,0.3,0.6,0.5])
        var low=baseline;low.centerY=0.8
        let saved=SavedCalibration(cameraID:"synthetic",baseline:baseline.values,yellow:0.8,red:1.8)
        var prefs=PosturePreferences();prefs.selectedCameraID="synthetic";prefs.yellow=0.8;prefs.red=1.8;prefs.calibrations["synthetic"]=saved
        try store.save(prefs)
        let model=CameraModel(store:store,observesLifecycle:false,presentsVisuals:false)
        precondition(!model.active && !model.loading && model.hasSavedCalibration)
        model.active=true;model.stage="monitoring";model.engine.restoreValidated(baseline:baseline,yellow:0.8,red:1.8,delay:2)
        model.restartSetup();precondition(model.canUndoHeightReset)
        model.yellow=0.5;model.red=1.2;model.applyThresholds()
        let afterReset=try store.load()!
        precondition(afterReset.calibration(for:"synthetic")!.yellow==0.8)
        model.receive(baseline,at:0);model.capture()
        for i in 0...10 {model.receive(baseline,at:Double(i)/10)}
        model.receive(nil,at:1.2)
        let afterFailure=try store.load()!
        precondition(afterFailure.calibration(for:"synthetic")!.baseline==baseline.values,"Failed capture preserves confirmed height")
        model.undoHeightReset()
        precondition(model.monitoring && model.yellow==0.8 && model.red==1.8 && model.engine.baseline!.values==baseline.values && !model.canUndoHeightReset,"Undo restores exact old baseline and levels")
        model.restartSetup();model.engine.restoreValidated(baseline:baseline,yellow:0.8,red:1.8,delay:2);model.stage="review"
        model.receive(baseline,at:2);model.receive(baseline,at:2.4)
        precondition(model.setupCheckPhase=="lower","Returning before going low cannot finish")
        model.receive(low,at:2.5);model.receive(baseline,at:2.6)
        precondition(model.setupCheckPhase=="lower","Brief low jitter cannot count")
        model.receive(low,at:2.7);model.receive(low,at:3.2)
        precondition(model.setupCheckPhase=="return")
        model.receive(baseline,at:3.3);precondition(model.setupCheckComplete)
        model.setHeightBoundary(2.0,isRed:true);precondition(!model.setupCheckComplete,"Changing levels requires retesting")
        // Level practice no longer gates the explicit Save height & start action.
        model.receive(low,at:3.4);model.receive(low,at:3.9);model.receive(baseline,at:4)
        model.receive(nil,at:4.1);model.confirm();precondition(!model.monitoring,"Cannot confirm while tracking is uncertain")
        model.receive(baseline,at:4.2);model.confirm();precondition(!model.monitoring && !model.hasPose,"Reacquisition cannot enable confirm early")
        model.receive(baseline,at:4.6)
        model.confirm();precondition(model.monitoring && !model.canUndoHeightReset)
        model.pauseFor(minutes:5)
        let deadline=model.pauseUntil!
        model.pollPause(at:deadline.addingTimeInterval(-1));precondition(model.paused)
        model.pollPause(at:deadline);precondition(!model.paused && model.pauseUntil==nil)
        model.receive(low,at:5);precondition(model.score==nil,"Resume must reacquire before feedback")
        model.receive(low,at:5.4);precondition(model.score != nil && !model.engine.alert)
        model.receive(baseline,at:5.5);precondition(model.state=="inside" && model.score==0,"Improvement remains immediate")
        model.receive(nil,at:5.6);precondition(model.state=="inside" && model.score==nil && !model.engine.alert,"Loss immediately clears feedback without flickering UI")
        model.receive(nil,at:6.7);precondition(model.state=="lost" && model.message.hasPrefix("Tracking paused"))
        model.receive(low,at:6.8);model.receive(nil,at:6.9);model.receive(low,at:7)
        precondition(model.state=="lost" && model.score==nil,"Intermittent reacquisition cannot resume reminders")
        model.receive(low,at:7.4);precondition(model.state=="outside" && !model.engine.alert)
        model.receive(baseline,at:7.5);precondition(model.state=="inside")
        model.pauseFor(minutes:5);model.togglePause();precondition(!model.paused && model.pauseUntil==nil,"Manual resume cancels timer")
        model.pauseFor(minutes:5);model.stop();precondition(!model.active && !model.paused && model.pauseUntil==nil)
        let token=CameraRunToken();let old=token.advance();precondition(token.accepts(old));let new=token.advance()
        precondition(!token.accepts(old) && token.accepts(new),"Canceled opening and stale callbacks are rejected")
        print("PASS: ordered setup check, jitter rejection, threshold invalidation, exact undo, failed-capture preservation, timed/manual pause, quiet loss and stable reacquisition, immediate recovery, camera run tokens; synthetic only")
    }
}
