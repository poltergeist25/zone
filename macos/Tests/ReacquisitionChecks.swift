import AppKit
import Foundation
import Darwin

@main struct ReacquisitionChecks {
    static func main() throws {
        _=NSApplication.shared
        setbuf(stdout,nil)
        var failures=0
        func check(_ condition:Bool,_ label:String){print("\(condition ? "PASS":"FAIL"): \(label)");if !condition{failures += 1}}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("zone-return-\(UUID().uuidString)")
        defer{try? FileManager.default.removeItem(at:root)}
        let baseline=PoseFeatures([0,0.4,0,0.3,0.6,0.5])
        func model(_ name:String)->CameraModel {
            let m=CameraModel(store:PreferencesStore(url:root.appendingPathComponent(name+"/preferences.json")),observesLifecycle:false,presentsVisuals:false)
            m.selectedID="synthetic";m.active=true;m.stage="monitoring"
            precondition(m.engine.restoreValidated(baseline:baseline,yellow:0.45,red:0.85,delay:2))
            m.receive(baseline,at:0)
            return m
        }
        let delayed=model("delayed")
        delayed.receive(nil,at:1,loss:.side)
        delayed.receive(baseline,at:2)
        check(!delayed.hasPose && delayed.score==nil,"A single returning observation cannot restart reminders")
        delayed.receive(baseline,at:2+2.0/3)
        check(delayed.hasPose && delayed.score==0,"A dropped camera frame cannot permanently starve reacquisition")
        check(delayed.engine.baseline?.values==baseline.values,"Reacquisition keeps the chosen height")
        delayed.stop()

        let watchdog=model("watchdog")
        watchdog.receive(nil,at:1,loss:.side)
        watchdog.receive(baseline,at:2)
        watchdog.checkCameraFreshness(at:2.66)
        check(!watchdog.hasPose && watchdog.score==nil && !watchdog.engine.alert,"A stale delivery still clears feedback immediately")
        watchdog.receive(baseline,at:2+2.0/3)
        check(watchdog.hasPose && watchdog.score==0,"A watchdog tick between matched returns does not erase return evidence")
        watchdog.checkCameraFreshness(at:3.34)
        watchdog.receive(baseline,at:3.35)
        check(watchdog.hasPose && watchdog.score==0,"Brief delivery jitter resumes on the next matched frame")
        watchdog.stop()

        let interrupted=model("interrupted")
        interrupted.receive(nil,at:1,loss:.side)
        interrupted.receive(baseline,at:2)
        interrupted.receive(nil,at:2.2,loss:.unknown)
        interrupted.receive(baseline,at:2.3)
        check(!interrupted.hasPose && interrupted.score==nil,"An actual no-face observation resets the return check")
        interrupted.receive(baseline,at:2.7)
        check(interrupted.hasPose && interrupted.score==0,"A clear return after intermittent misses recovers")
        interrupted.stop()

        let expired=model("expired")
        expired.receive(nil,at:1,loss:.side)
        expired.receive(baseline,at:2)
        expired.checkCameraFreshness(at:3.6)
        expired.receive(baseline,at:3.7)
        check(!expired.hasPose && expired.score==nil,"Old return evidence expires across a real camera interruption")
        expired.receive(baseline,at:4.1)
        check(expired.hasPose && expired.score==0,"Fresh matched observations recover after a long interruption")
        expired.stop()
        if failures>0 {throw NSError(domain:"ReacquisitionChecks",code:failures,userInfo:[NSLocalizedDescriptionKey:"\(failures) reacquisition regressions failed"])}
        print("PASS: delayed delivery, watchdog interleave, actual loss reset, expiry and unchanged chosen height; synthetic observations only")
    }
}
