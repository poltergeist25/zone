import Foundation

@main struct TrackerAblationChecks {
    static func main() throws {
        func data(_ mode:String?,expires:Double=200)throws->Data {
            var request:[String:Any]=["expires":expires,"visual_mode":"full"]
            if let mode {request["tracker_mode"]=mode}
            return try JSONSerialization.data(withJSONObject:request)
        }
        var lease=DiagnosticVisualLease()
        lease.replace(data:try data("full"),wallTime:100,uptime:10)
        precondition(lease.forcesFullTracker(wallTime:101,uptime:11))
        precondition(!lease.forcesFullTracker(wallTime:201,uptime:12),"Expired diagnostics cannot leave tracking in a test mode")
        lease.replace(data:try data("patch"),wallTime:102,uptime:12)
        precondition(!lease.forcesFullTracker(wallTime:103,uptime:13))
        lease.replace(data:try data("full"),wallTime:104,uptime:14)
        precondition(lease.forcesFullTracker(wallTime:105,uptime:15))
        precondition(!lease.forcesFullTracker(wallTime:105,uptime:111),"Changing an ablation cannot extend its monotonic lease")
        lease.replace(data:nil,wallTime:106,uptime:16)
        precondition(!lease.forcesFullTracker(wallTime:107,uptime:17),"Removal immediately restores normal tracking")
        for mode in [nil,"unknown","patch"] as [String?] {
            var normal=DiagnosticVisualLease()
            normal.replace(data:try data(mode),wallTime:100,uptime:10)
            precondition(!normal.forcesFullTracker(wallTime:101,uptime:11))
        }
        var invalid=DiagnosticVisualLease()
        invalid.replace(data:try data("full",expires:2000),wallTime:100,uptime:10)
        precondition(!invalid.forcesFullTracker(wallTime:101,uptime:11),"Overlong leases fail closed")
        for radius in [7,10,12,0,99] {
            var sized=DiagnosticVisualLease()
            let bytes=try JSONSerialization.data(withJSONObject:["expires":200,"tracker_radius":radius])
            sized.replace(data:bytes,wallTime:100,uptime:10)
            precondition(sized.trackerRadius(wallTime:101,uptime:11)==([7,10,12].contains(radius) ? radius:7))
            precondition(sized.trackerRadius(wallTime:201,uptime:12)==7,"Expiry restores ordinary template size")
            sized.replace(data:nil,wallTime:102,uptime:12)
            precondition(sized.trackerRadius(wallTime:103,uptime:13)==7,"Removal restores ordinary template size")
        }
        print("PASS: temporary full/patch tracker comparison, default/missing/unknown mode safety, expiry/removal and unchanged monotonic deadline")
    }
}
