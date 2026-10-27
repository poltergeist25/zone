import Foundation

@main struct UpdateResumeChecks {
    static func check(_ condition:@autoclosure ()throws->Bool,_ message:String="Check failed") rethrows {let result=try condition();precondition(result,message)}
    static func main() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("zone-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let time=2_000_000_000.0
        let old=UpdateResumeStore(directory:directory,build:"50",processID:1111,now:{Date(timeIntervalSince1970:time)})
        let next=UpdateResumeStore(directory:directory,build:"51",processID:2222,now:{Date(timeIntervalSince1970:time+5)})
        try Data("original-private-settings".utf8).write(to:old.preferencesURL)
        let original=try Data(contentsOf:old.preferencesURL)
        let digest=try old.currentDigest()
        func request(from:String="50",to:String="51",pid:Int32=1111,created:Double?=nil,expires:Double?=nil)->UpdateResumeRequest {
            UpdateResumeRequest(operationID:UUID().uuidString,fromBuild:from,toBuild:to,sourcePID:pid,createdAt:created ?? time,expiresAt:expires ?? time+120)
        }
        func write(_ r:UpdateResumeRequest)throws {try JSONEncoder().encode(r).write(to:old.requestURL,options:.atomic)}
        func state(_ mode:UpdateSessionMode)->UpdateSessionState {UpdateSessionState(mode:mode,cameraID:"synthetic-camera",pauseUntilUnix:mode == .paused ? time+600:nil,page:"Progress",controlsVisible:false,preferencesDigest:digest)}
        try check(try next.consume()==nil,"Normal launch has no camera-start handoff")
        for mode in [UpdateSessionMode.tracking,.paused,.off,.setup] {
            try write(request());try check(try old.prepareForTermination(state(mode)))
            let restored=try next.consume()!
            precondition(restored.state==state(mode),"Update preserves exact tracking intent, page and controls visibility")
            try check(try next.consume()==nil,"A consumed handoff cannot replay")
            precondition(!FileManager.default.fileExists(atPath:old.receiptURL.path) && !FileManager.default.fileExists(atPath:old.requestURL.path))
        }
        for bad in [request(from:"wrong"),request(pid:1234),request(created:time-500,expires:time-1),request(created:time+20,expires:time+120),request(expires:time+301),request(to:"50")] {
            try write(bad);try check(try !old.prepareForTermination(state(.tracking)),"Wrong process/build or invalid leases cannot arm resume")
        }
        try write(request());try check(try old.prepareForTermination(state(.tracking)))
        let wrong=UpdateResumeStore(directory:directory,build:"52",processID:3333,now:{Date(timeIntervalSince1970:time+5)})
        try check(try wrong.consume()==nil && wrong.rejection != nil,"Only the intended target build can resume")
        try check(try next.consume()==nil,"Rejected handoffs are consumed rather than deferred to a later ordinary launch")
        try write(request());_=try old.prepareForTermination(state(.tracking))
        try Data("changed".utf8).write(to:old.preferencesURL)
        try check(try next.consume()==nil && next.rejection != nil,"Changed preferences invalidate stale intent")
        try original.write(to:old.preferencesURL)
        try write(request());_=try old.prepareForTermination(state(.tracking))
        try write(request())
        try check(try next.consume()==nil,"An unrelated operation cannot borrow a receipt")
        try write(request());_=try old.prepareForTermination(state(.tracking));old.cancel()
        try check(try next.consume()==nil,"Explicit quit/cancel suppresses auto-resume")
        try write(request());_=try old.prepareForTermination(state(.tracking));try FileManager.default.removeItem(at:old.requestURL)
        try check(try next.consume()==nil,"An orphan receipt cannot start the camera")
        try write(request());_=try old.prepareForTermination(state(.tracking))
        let expired=UpdateResumeStore(directory:directory,build:"51",processID:2222,now:{Date(timeIntervalSince1970:time+121)})
        try check(try expired.consume()==nil,"Expired restart cannot activate capture later")
        try check(try Data(contentsOf:old.preferencesURL)==original,"The handoff never rewrites settings")
        let empty=directory.appendingPathComponent("empty");try FileManager.default.createDirectory(at:empty,withIntermediateDirectories:true)
        let emptyOld=UpdateResumeStore(directory:empty,build:"50",processID:1111,now:{Date(timeIntervalSince1970:time)})
        let emptyNew=UpdateResumeStore(directory:empty,build:"51",processID:2222,now:{Date(timeIntervalSince1970:time+1)})
        try JSONEncoder().encode(request()).write(to:emptyOld.requestURL)
        let off=UpdateSessionState(mode:.off,cameraID:"",pauseUntilUnix:nil,page:"Posture",controlsVisible:true,preferencesDigest:"absent")
        try check(try emptyOld.prepareForTermination(off));try check(try emptyNew.consume()?.state==off)
        print("PASS: one-shot update handoff, all session states, expiry, PID/build/operation/profile binding, canceled/orphan/rejected launches and unchanged private preferences")
    }
}
