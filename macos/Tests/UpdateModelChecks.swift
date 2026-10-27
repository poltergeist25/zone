import AppKit
import AVFoundation

@main struct UpdateModelChecks {
    static func main() throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("zone-update-model-\(UUID().uuidString)")
        defer{try? FileManager.default.removeItem(at:root)}
        let baseline=PoseFeatures([0,0.4,0,0.3,0.6,0.5])
        func model(_ name:String,observesLifecycle:Bool=false)throws->CameraModel {
            let store=PreferencesStore(url:root.appendingPathComponent(name+"/preferences.json"))
            var prefs=PosturePreferences();prefs.selectedCameraID="synthetic"
            prefs.calibrations["synthetic"]=SavedCalibration(cameraID:"synthetic",baseline:baseline.values,yellow:0.45,red:0.85)
            try store.save(prefs)
            return CameraModel(store:store,observesLifecycle:observesLifecycle,presentsVisuals:false,updateBuild:"50")
        }
        func state(_ model:CameraModel,_ mode:UpdateSessionMode,until:Double?=nil)throws->UpdateSessionState {
            UpdateSessionState(mode:mode,cameraID:"synthetic",pauseUntilUnix:until,page:"Progress",controlsVisible:false,preferencesDigest:try model.updateResumeStore.currentDigest())
        }
        let live=try model("live");var starts=0
        live.resumeAfterUpdate(try state(live,.tracking),cameraAuthorized:true,cameraAvailable:true,startCameraAction:{starts += 1})
        precondition(starts==1 && !live.session.isRunning,"Eligible handoff chooses capture once; test replaces hardware start")
        for mode in [UpdateSessionMode.off,.setup] {
            let m=try model(mode.rawValue);var called=false
            m.resumeAfterUpdate(try state(m,mode),cameraAuthorized:true,cameraAvailable:true,startCameraAction:{called=true})
            precondition(!called && !m.active && !m.session.isRunning,"Off and unfinished setup must not silently start camera")
        }
        for (auth,available) in [(false,true),(true,false)] {
            let m=try model("denied-\(auth)");var called=false
            m.resumeAfterUpdate(try state(m,.tracking),cameraAuthorized:auth,cameraAvailable:available,startCameraAction:{called=true})
            precondition(!called && !m.active && m.state=="error","No camera fallback or permission prompt after update")
        }
        let mismatch=try model("mismatch");var mismatchedStart=false
        let wrong=UpdateSessionState(mode:.tracking,cameraID:"another-camera",pauseUntilUnix:nil,page:"Posture",controlsVisible:true,preferencesDigest:try mismatch.updateResumeStore.currentDigest())
        mismatch.resumeAfterUpdate(wrong,cameraAuthorized:true,cameraAvailable:true,startCameraAction:{mismatchedStart=true})
        precondition(!mismatchedStart && !mismatch.active)
        let paused=try model("paused");var resumed=0
        let deadline=Date().addingTimeInterval(300)
        paused.resumeAfterUpdate(try state(paused,.paused,until:deadline.timeIntervalSince1970),cameraAuthorized:true,cameraAvailable:true,startCameraAction:{resumed += 1})
        precondition(paused.active && paused.monitoring && paused.paused && !paused.cameraEnabled && !paused.session.isRunning && abs((paused.pauseUntil?.timeIntervalSince1970 ?? 0)-deadline.timeIntervalSince1970)<0.000001)
        precondition(paused.engine.baseline?.values==baseline.values && resumed==0,"Paused update restores exact setup without capture")
        paused.togglePause();precondition(resumed==1 && !paused.paused,"Resume opens a new capture graph after a paused update")
        let timed=try model("timed");var timedStarts=0
        timed.resumeAfterUpdate(try state(timed,.paused,until:deadline.timeIntervalSince1970),cameraAuthorized:true,cameraAvailable:true,startCameraAction:{timedStarts += 1})
        timed.pollPause(at:deadline.addingTimeInterval(-1));precondition(timedStarts==0)
        timed.pollPause(at:timed.pauseUntil!);precondition(timedStarts==1 && !timed.paused)
        let expired=try model("expired-pause");var forbidden=false
        expired.resumeAfterUpdate(try state(expired,.paused,until:Date().addingTimeInterval(-1).timeIntervalSince1970),cameraAuthorized:false,cameraAvailable:true,startCameraAction:{forbidden=true})
        precondition(!forbidden && !expired.active && expired.state=="error")
        let reset=try model("reset-paused");var resetStarts=0
        reset.resumeAfterUpdate(try state(reset,.paused),cameraAuthorized:true,cameraAvailable:true,startCameraAction:{resetStarts += 1})
        reset.restartSetup();precondition(resetStarts==1 && reset.stage=="green" && !reset.paused,"Recalibration after a paused update also opens capture")
        let stopped=try model("stop-paused");var staleStart=false
        stopped.resumeAfterUpdate(try state(stopped,.paused),cameraAuthorized:true,cameraAvailable:true,startCameraAction:{staleStart=true})
        stopped.stop();stopped.togglePause();precondition(!staleStart && !stopped.active)
        let quitting=try model("quitting",observesLifecycle:true)
        quitting.active=true;quitting.stage="monitoring";quitting.engine.restoreValidated(baseline:baseline,yellow:0.45,red:0.85,delay:2)
        quitting.updateWindowContext={(page:"Progress",visible:false)}
        let now=Date().timeIntervalSince1970
        let request=UpdateResumeRequest(operationID:UUID().uuidString,fromBuild:"50",toBuild:"51",sourcePID:quitting.updateResumeStore.processID,createdAt:now,expiresAt:now+120)
        try JSONEncoder().encode(request).write(to:quitting.updateResumeStore.requestURL)
        let original=try Data(contentsOf:quitting.updateResumeStore.preferencesURL)
        // Exercise the registered notification, not just the delegate method.
        // macOS may deliver this observer before applicationWillTerminate.
        NotificationCenter.default.post(name:NSApplication.willTerminateNotification,object:NSApplication.shared)
        let saved=try JSONDecoder().decode(UpdateResumeReceipt.self,from:Data(contentsOf:quitting.updateResumeStore.receiptURL))
        precondition(saved.state.mode == .tracking && saved.state.page=="Progress" && !saved.state.controlsVisible && !quitting.active,"Snapshot precedes camera stop")
        quitting.prepareForApplicationTermination()
        let repeated=try JSONDecoder().decode(UpdateResumeReceipt.self,from:Data(contentsOf:quitting.updateResumeStore.receiptURL))
        precondition(repeated==saved,"Delegate/notification ordering cannot overwrite tracking intent after stop")
        let after=try Data(contentsOf:quitting.updateResumeStore.preferencesURL)
        precondition(after==original,"Update lifecycle never rewrites chosen calibration/settings")
        for m in [live,mismatch,paused,timed,expired,reset,stopped,quitting] {m.stop()}
        print("PASS: eligible update start, off/setup/missing camera/permission isolation, paused/timed/manual resume, paused reset/stop, snapshot-before-stop idempotence and exact saved setup; injected capture, no hardware started")
    }
}
