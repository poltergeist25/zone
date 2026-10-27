import AppKit
import Foundation

@main struct RedContinuityChecks {
    static func main() throws {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("zone-red-continuity-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:directory)}
        let baseline=PoseFeatures([0,0.4,0,0.3,0.6,0.4])
        var low=baseline;low.centerY=0.57
        func model(_ name:String,visuals:Bool=false)->CameraModel {
            let m=CameraModel(store:PreferencesStore(url:directory.appendingPathComponent(name+"/preferences.json")),observesLifecycle:false,presentsVisuals:visuals)
            m.selectedID="synthetic";m.active=true;m.stage="review";m.yellow=0.45;m.red=0.85
            precondition(m.engine.restoreValidated(baseline:baseline,yellow:m.yellow,red:m.red,delay:2))
            return m
        }
        // Actual production controller/window, driven by synthetic geometry: review
        // previously hard-coded alert:false even after long sustained red.
        let review=model("review",visuals:true)
        for i in 0...8 {review.receive(low,at:Double(i)*0.3)}
        precondition(review.stage=="review" && review.engine.alert && review.state=="alert")
        precondition(NSApp.windows.contains {$0.isVisible && !$0.ignoresMouseEvents},"Review red must present the original focus card")
        review.receive(baseline,at:2.5)
        precondition(!review.engine.alert && review.state=="inside" && !NSApp.windows.contains {$0.isVisible},"Review recovery clears every effect immediately")
        review.togglePause();precondition(review.paused && !review.engine.alert)
        review.togglePause();review.stop()

        let m=model("bottom",visuals:true);m.receive(baseline,at:0);m.confirm()
        precondition(m.monitoring && !m.setupCheckComplete,"Saving never requires sinking into red first")
        m.receive(low,at:0.3);m.receive(low,at:0.6)
        precondition(!m.engine.alert)
        for i in 3...10 {m.receive(nil,at:Double(i)*0.3,loss:.bottom)}
        precondition(m.bottomExitHeld && !m.hasPose && m.engine.alert && m.state=="alert","A confirmed bottom exit completes the existing red delay")
        precondition(NSApp.windows.contains {$0.isVisible && !$0.ignoresMouseEvents})
        m.receive(baseline,at:3.1)
        precondition(m.hasPose && !m.bottomExitHeld && m.state=="inside" && !m.engine.alert,"First matched upright frame clears the held card")
        precondition(!NSApp.windows.contains {$0.isVisible})
        for i in 11...20 {m.receive(low,at:Double(i)*0.3)}
        precondition(m.engine.alert)
        m.receive(nil,at:6.1,loss:.side)
        precondition(!m.engine.alert && !m.bottomExitHeld && m.score==nil && !NSApp.windows.contains {$0.isVisible},"Side exits clear immediately")
        m.receive(low,at:6.2);m.receive(low,at:6.6)
        for i in 23...31 {m.receive(low,at:Double(i)*0.3)}
        precondition(m.engine.alert)
        m.receive(nil,at:9.4,loss:.bottom);precondition(m.bottomExitHeld)
        m.checkCameraFreshness(at:9.8);precondition(m.bottomExitHeld,"New analysed no-face frames keep camera freshness independent of last good pose")
        m.checkCameraFreshness(at:10.1)
        precondition(!m.bottomExitHeld && !m.engine.alert && !NSApp.windows.contains {$0.isVisible},"Camera stall never masquerades as a bottom exit")
        m.stop()
        let unknown=model("unknown")
        for i in 0...8 {unknown.receive(low,at:Double(i)*0.3)}
        unknown.receive(nil,at:2.5,loss:.unknown)
        precondition(!unknown.engine.alert && !unknown.bottomExitHeld,"Unexplained loss does not invent red continuity")
        unknown.receive(baseline,at:2.6);unknown.receive(baseline,at:3)
        unknown.receive(nil,at:3.1,loss:.bottom)
        precondition(!unknown.bottomExitHeld,"Bottom inference cannot manufacture red from green")
        unknown.stop()
        let count=model("statistics");count.stage="monitoring";count.receive(low,at:0);count.receive(low,at:0.3)
        count.progressStore.flush()
        let historyURL=directory.appendingPathComponent("statistics/daily-progress.json")
        let before=try Data(contentsOf:historyURL)
        for i in 2...12 {count.receive(nil,at:Double(i)*0.3,loss:.bottom)}
        count.progressStore.flush()
        let after=try Data(contentsOf:historyURL)
        precondition(after==before,"Unseen bottom time must never enter the daily score")
        count.stop()

        let store=PreferencesStore(url:directory.appendingPathComponent("draft/preferences.json"))
        var prefs=PosturePreferences();prefs.selectedCameraID="synthetic";prefs.yellow=1.03;prefs.red=2.25
        prefs.calibrations["synthetic"]=SavedCalibration(cameraID:"synthetic",baseline:baseline.values,yellow:1.03,red:2.25)
        try store.save(prefs)
        let draft=CameraModel(store:store,observesLifecycle:false,presentsVisuals:false)
        draft.active=true;draft.stage="monitoring";draft.engine.restoreValidated(baseline:baseline,yellow:1.03,red:2.25,delay:2)
        draft.restartSetup();precondition(draft.yellow==0.45 && draft.red==0.85 && !draft.hasPose)
        draft.setForgiveness(0.1);draft.delay=3;draft.applyThresholds()
        let onDisk=try store.load()!
        precondition(onDisk.yellow==1.03 && onDisk.red==2.25 && onDisk.delay==3,"Draft levels never leak into saved preferences")
        draft.restartSetup();draft.undoHeightReset()
        precondition(draft.yellow==1.03 && draft.red==2.25 && draft.engine.baseline?.values==baseline.values,"Repeated resets preserve the exact confirmed undo target")
        draft.stop()
        print("PASS: actual review red card, immediate green, optional practice, bottom/side/stale continuity, excluded missing statistics, transactional reset defaults/undo; synthetic geometry")
    }
}
