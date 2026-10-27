import AppKit
import Foundation

// A short-lived installer helper, never a background service or forced quitter.
let bundleID = "com.arungupta.posturezone"
func output(_ object:[String:Any],code:Int32=0)->Never {
    let data=try! JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
    FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10]));exit(code)
}
guard CommandLine.arguments.count >= 3 else {output(["error":"Use status APP or terminate APP PID"],code:2)}
let action=CommandLine.arguments[1]
let target=URL(fileURLWithPath:CommandLine.arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
let all=NSRunningApplication.runningApplications(withBundleIdentifier:bundleID)
guard all.count <= 1 else {output(["error":"Multiple Zone owners are running"],code:3)}
guard all.allSatisfy({$0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath()==target}) else {
    output(["error":"A Zone owner is running from another path"],code:3)
}
if let app=all.first {
    let expected=target.appendingPathComponent("Contents/MacOS/PostureZone")
    guard app.executableURL?.standardizedFileURL.resolvingSymlinksInPath()==expected else {
        output(["error":"Unexpected owned executable path"],code:3)
    }
}
let info=Bundle(url:target)?.infoDictionary ?? [:]
guard info["CFBundleIdentifier"] as? String == bundleID,
      info["CFBundleExecutable"] as? String == "PostureZone",
      let build=info["CFBundleVersion"] as? String else {output(["error":"Unexpected installed bundle identity"],code:3)}
if action == "status" {
    var result:[String:Any]=["running":!all.isEmpty,"path":target.path,"build":build,
                           "updateResumeVersion":(info["ZoneUpdateResumeVersion"] as? NSNumber)?.intValue ?? 0]
    if let app=all.first {result["pid"]=app.processIdentifier}
    output(result)
}
guard action == "terminate",CommandLine.arguments.count==4,
      let expected=Int32(CommandLine.arguments[3]),let app=all.first,
      app.processIdentifier==expected,
      app.executableURL?.lastPathComponent=="PostureZone" else {
    output(["error":"Owned process identity changed before termination"],code:3)
}
guard app.terminate() else {output(["error":"Normal termination refused","pid":expected],code:4)}
let deadline=Date().addingTimeInterval(15)
while !app.isTerminated && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.05))}
guard app.isTerminated else {output(["error":"Normal termination timed out; no force used","pid":expected],code:5)}
output(["terminated":true,"pid":expected,"path":target.path,"build":build])
