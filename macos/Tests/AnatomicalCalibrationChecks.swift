import AppKit
import Foundation

@main struct AnatomicalCalibrationChecks {
    static func main() throws {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("zone-anatomy-\(UUID().uuidString)")
        defer{try? FileManager.default.removeItem(at:directory)}
        let landmarks=FaceHeightLandmarks(eyesY:0.35,noseY:0.42,chinY:0.60)
        let personal=LandmarkHeightCalibration.capture(landmarks)!
        func shifted(_ amount:Double)->FaceHeightLandmarks {
            FaceHeightLandmarks(eyesY:landmarks.eyesY+amount,noseY:landmarks.noseY+amount,chinY:landmarks.chinY+amount)
        }
        func near(_ a:Double,_ b:Double){precondition(abs(a-b)<0.000001)}
        near(personal.deviation(landmarks)!,0)
        near(personal.deviation(shifted(personal.referenceLineY-landmarks.noseY))!,PostureEngine.defaultYellow)
        near(personal.deviation(shifted(personal.referenceLineY-landmarks.eyesY))!,PostureEngine.defaultRed)
        precondition(personal.deviation(shifted(-0.03))==0,"Moving above chosen height remains green")
        let atNose=FaceHeightLandmarks(eyesY:personal.referenceLineY-0.09,noseY:personal.referenceLineY,chinY:0.7)
        let atEyes=FaceHeightLandmarks(eyesY:personal.referenceLineY,noseY:personal.referenceLineY+0.05,chinY:0.7)
        near(personal.deviation(atNose)!,PostureEngine.defaultYellow)
        near(personal.deviation(atEyes)!,PostureEngine.defaultRed)
        precondition(personal.deviation(FaceHeightLandmarks(eyesY:0.5,noseY:0.4,chinY:0.6))==nil,"Invalid ordering cannot produce a posture score")
        precondition(LandmarkHeightCalibration.capture(FaceHeightLandmarks(eyesY:0.35,noseY:.nan,chinY:0.6))==nil)
        var baseline=PoseFeatures([0,0.4,0,0.3,0.6,0.43]);baseline.landmarkHeight=personal
        var current=baseline;current.landmarkHeight=nil;current.heightLandmarks=atEyes
        near(PostureEngine.deviation(current,from:baseline),PostureEngine.defaultRed)
        current.heightLandmarks=atNose
        near(PostureEngine.deviation(current,from:baseline),PostureEngine.defaultYellow)
        current.heightLandmarks=nil
        precondition(PostureEngine.deviation(current,from:baseline).isNaN,"Missing landmarks never silently revert to generic tracking")
        let engine=PostureEngine();precondition(engine.restoreValidated(baseline:baseline,yellow:0.45,red:0.85,delay:2))
        precondition(engine.update(current,at:0).state=="lost")
        // Frozen-average center deliberately remains unchanged: the actual nose
        // and eye crossings must still drive yellow/red, including head tilt.
        current.heightLandmarks=FaceHeightLandmarks(eyesY:personal.referenceLineY+0.001,noseY:personal.referenceLineY+0.06,chinY:0.7)
        for i in 0...10 {_=engine.update(current,at:Double(i)*0.3+1)}
        precondition(engine.alert,"Observed eye crossing completes the original red delay")
        current.heightLandmarks=landmarks
        precondition(engine.update(current,at:4.1).state=="inside" && !engine.alert,"Real green still clears on the first recovered frame")

        let moving=PostureEngine();moving.calibrate()
        for i in 0...40 {
            var nod=PoseFeatures([0,0.4,0,0.3,0.6,0.475])
            nod.heightLandmarks=i.isMultiple(of:2) ? FaceHeightLandmarks(eyesY:0.4,noseY:0.47,chinY:0.63):FaceHeightLandmarks(eyesY:0.4,noseY:0.52,chinY:0.58)
            _=moving.update(nod,at:Double(i)/10)
        }
        precondition(moving.calibrating && moving.baseline==nil,"A nod cannot pass calibration merely by keeping the composite anchor still")
        let store=PreferencesStore(url:directory.appendingPathComponent("preferences.json"))
        let model=CameraModel(store:store,observesLifecycle:false,presentsVisuals:false)
        model.select("synthetic-anatomy");model.active=true;model.stage="green"
        var comfortable=PoseFeatures([0,0.4,0,0.3,0.6,0.43]);comfortable.heightLandmarks=landmarks
        var clock=ProcessInfo.processInfo.systemUptime
        model.receive(comfortable,at:clock);model.capture()
        for i in 1...32 {model.receive(comfortable,at:clock+Double(i)/10)}
        precondition(model.monitoring && model.hasSavedCalibration && model.engine.baseline?.landmarkHeight != nil,"Stable anatomical capture automatically saves and starts")
        let captured=model.engine.baseline!.landmarkHeight!
        near(captured.referenceLineY,personal.referenceLineY)
        near(model.yellow,0.45);near(model.red,0.85);near(model.forgiveness,0.5)
        precondition(!model.canUndoHeightReset && model.persistenceMessage==nil,"Automatic commit finishes the reset without a confirmation action")
        let saved=try store.load()!.calibration(for:"synthetic-anatomy")!
        precondition(saved.landmarkHeight==captured && saved.poseFeatures.landmarkHeight==captured,"Fresh personal geometry survives exact save/load")
        for value in [0.0,0.25,0.5,0.75,1.0,0.5] {
            model.setForgiveness(value)
            near(model.forgiveness,value)
            let multiplier=pow(2,(value-0.5)*2)
            near(model.yellow,0.45*multiplier);near(model.red,0.85*multiplier)
            precondition(PostureEngine.validThresholds(yellow:model.yellow,red:model.red))
            precondition(model.engine.baseline?.landmarkHeight==captured && model.delay==2,"Forgiveness changes neither chosen line nor alert delay")
            let persisted=try store.load()!.calibration(for:"synthetic-anatomy")!
            precondition(persisted.landmarkHeight==captured)
        }
        let reopened=CameraModel(store:store,observesLifecycle:false,presentsVisuals:false)
        let handoff=UpdateSessionState(mode:.paused,cameraID:"synthetic-anatomy",pauseUntilUnix:nil,page:"Posture",controlsVisible:true,preferencesDigest:try reopened.updateResumeStore.currentDigest())
        reopened.resumeAfterUpdate(handoff)
        precondition(reopened.engine.baseline?.landmarkHeight==captured && reopened.paused && !reopened.session.isRunning,"Paused/update restoration retains anatomy without opening capture")
        reopened.stop()
        model.restartSetup();clock += 4
        var other=comfortable;other.heightLandmarks=FaceHeightLandmarks(eyesY:0.32,noseY:0.41,chinY:0.65)
        model.receive(other,at:clock);model.capture()
        for i in 1...32 {model.receive(other,at:clock+Double(i)/10)}
        precondition(model.monitoring && model.hasSavedCalibration && model.engine.baseline?.landmarkHeight != captured,"A successful replacement capture automatically becomes the active saved anatomy")
        let replacement=model.engine.baseline!.landmarkHeight!
        let replacementSaved=try store.load()!.calibration(for:"synthetic-anatomy")!
        precondition(replacementSaved.landmarkHeight==replacement && !model.canUndoHeightReset,"Automatic replacement commit persists the new person and completes undo state")
        model.undoHeightReset()
        precondition(model.engine.baseline?.landmarkHeight==replacement,"Go back after a completed commit cannot resurrect an old person's geometry")
        model.restartSetup();clock += 4
        model.receive(comfortable,at:clock);model.capture()
        for i in 1...10 {model.receive(comfortable,at:clock+Double(i)/10)}
        let confirmedDuringDraft=try store.load()!.calibration(for:"synthetic-anatomy")!
        precondition(model.capturing && confirmedDuringDraft.landmarkHeight==replacement,"An unfinished replacement capture cannot overwrite the last confirmed anatomy")
        model.undoHeightReset()
        precondition(model.monitoring && !model.capturing && model.engine.baseline?.landmarkHeight==replacement,"Go back from an unfinished reset restores the exact latest confirmed person's geometry")
        model.stop()

        var legacy=PosturePreferences();legacy.selectedCameraID="legacy"
        legacy.calibrations["legacy"]=SavedCalibration(cameraID:"legacy",baseline:comfortable.values,yellow:0.6,red:1)
        try store.save(legacy)
        let unchanged=try store.load()!.calibration(for:"legacy")!
        precondition(unchanged.landmarkHeight==nil && unchanged.baseline==comfortable.values && unchanged.yellow==0.6 && unchanged.red==1,"Old profiles remain unchanged until explicit calibration")
        var malformed=saved;malformed.landmarkHeight?.referenceLineY = .nan
        precondition(!malformed.valid,"Malformed optional anatomical metadata is rejected")
        print("PASS: measured nose/eye crossings including tilt, green margin, missing/invalid geometry isolation, red delay/immediate recovery, real model automatic save/start and replacement, forgiveness center/range, save/reload/update/undo, unfinished capture isolation and legacy preservation; synthetic only")
    }
}
