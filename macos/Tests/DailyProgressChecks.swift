import Foundation

// Compile with Sources/Engine.swift and Sources/DailyProgress.swift only. All time is synthetic.
@main struct DailyProgressChecks {
    static var checks=0
    static func check(_ condition:@autoclosure ()->Bool,_ name:String) {
        guard condition()else{fatalError("FAIL: \(name)")};checks += 1;print("PASS: \(name)")
    }
    static func near(_ a:Double?,_ b:Double,_ tolerance:Double=1e-6)->Bool {a.map{abs($0-b)<tolerance} ?? false}
    static func eastern(_ y:Int,_ m:Int,_ d:Int,_ h:Int,_ minute:Int=0,_ seconds:Double=0)->Date {
        DailyProgressCalendar.calendar.date(from:DateComponents(year:y,month:m,day:d,hour:h,minute:minute))!.addingTimeInterval(seconds)
    }
    // Engine defaults: yellow 0.6, red 1.0.
    static let green=0.2,yellow=0.8,red=1.4
    static func main() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("daily-progress-checks-\(UUID().uuidString)",isDirectory:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        var clock=eastern(2026,1,15,12)
        func makeStore(_ name:String,saveInterval:Double=30)->ProgressStore {
            ProgressStore(url:directory.appendingPathComponent(name),now:{clock},saveInterval:saveInterval)
        }
        let base=eastern(2026,1,15,10)
        func at(_ seconds:Double)->Date {base.addingTimeInterval(seconds)}

        check(PostureBand.classify(score:0.59,yellow:0.6,red:1) == .green,"Below yellow boundary is green")
        check(PostureBand.classify(score:0.6,yellow:0.6,red:1) == .yellow,"Yellow boundary matches engine >= rule")
        check(PostureBand.classify(score:1,yellow:0.6,red:1) == .red,"Red boundary matches engine >= rule")
        check(PostureBand.classify(score:nil,yellow:0.6,red:1)==nil && PostureBand.classify(score:.nan,yellow:0.6,red:1)==nil,"Missing or nonfinite score has no band")
        check(PostureBand.classify(score:0.2,yellow:0.8,red:0.9)==nil,"Invalid thresholds are not classified")

        // 100 green frames over 1 s, then 10 red frames over 9 s: time, not frames, is the denominator.
        let weighted=makeStore("weighted.json")
        for i in 0..<100 {weighted.record(score:green,yellow:0.6,red:1,at:at(Double(i)*0.01),eligible:true)}
        for i in 0...9 {weighted.record(score:red,yellow:0.6,red:1,at:at(1+Double(i)),eligible:true)}
        weighted.record(score:red,yellow:0.6,red:1,at:at(11),eligible:false)
        let w=weighted.today
        check(near(w.greenSeconds,1) && near(w.redSeconds,9) && w.yellowSeconds==0,"Seconds integrate between consecutive samples")
        check(near(w.score,10),"Score is time-weighted, not frame-weighted")
        check(near(w.greenFraction,0.1),"Green fraction is time-weighted")
        check(near(w.trackedSeconds,10),"Interval ending in ineligible sample is excluded")

        let formula=makeStore("formula.json")
        for i in 0...30 {formula.record(score:i<20 ? green:i<30 ? yellow:red,yellow:0.6,red:1,at:at(Double(i)),eligible:true)}
        formula.record(score:red,yellow:0.6,red:1,at:at(31),eligible:true)
        let f=formula.today
        check(near(f.greenSeconds,20) && near(f.yellowSeconds,10) && near(f.redSeconds,1),"Explicit breakdown per band")
        check(near(f.score,100*(20+0.5*10)/31),"Score is 100*(green+0.5*yellow)/tracked")

        let paused=makeStore("paused.json")
        paused.record(score:green,yellow:0.6,red:1,at:at(0),eligible:true)
        for i in 1...5 {paused.record(score:green,yellow:0.6,red:1,at:at(Double(i)),eligible:false)}
        paused.record(score:nil,yellow:0.6,red:1,at:at(6),eligible:true)
        paused.record(score:green,yellow:0.6,red:1,at:at(7),eligible:true)
        paused.record(score:green,yellow:0.6,red:1,at:at(7.5),eligible:true)
        check(near(paused.today.trackedSeconds,0.5),"Paused, lost and missing-score samples count nothing")

        let gaps=makeStore("gaps.json")
        gaps.record(score:green,yellow:0.6,red:1,at:at(0),eligible:true)
        gaps.record(score:green,yellow:0.6,red:1,at:at(600),eligible:true)
        check(gaps.today.trackedSeconds==0,"Long gap (absence) is excluded, not credited")
        gaps.record(score:green,yellow:0.6,red:1,at:at(601),eligible:true)
        check(near(gaps.today.trackedSeconds,1),"Monitoring resumes after a gap")
        gaps.record(score:green,yellow:0.6,red:1,at:at(602.6),eligible:true)
        check(near(gaps.today.trackedSeconds,1),"Gap just over the cap counts nothing")

        let backwards=makeStore("backwards.json")
        backwards.record(score:green,yellow:0.6,red:1,at:at(10),eligible:true)
        backwards.record(score:green,yellow:0.6,red:1,at:at(11),eligible:true)
        backwards.record(score:red,yellow:0.6,red:1,at:at(10.5),eligible:true)
        backwards.record(score:green,yellow:0.6,red:1,at:at(11.5),eligible:true)
        backwards.record(score:green,yellow:0.6,red:1,at:at(11.5),eligible:true)
        backwards.record(score:green,yellow:0.6,red:1,at:at(12),eligible:true)
        check(near(backwards.today.greenSeconds,1.5) && backwards.today.redSeconds==0,"Nonmonotonic sample rejected and never bridged")
        check(backwards.rejectedSamples==1,"Rejected sample is counted")

        let hourSplit=makeStore("hours.json")
        hourSplit.record(score:yellow,yellow:0.6,red:1,at:eastern(2026,1,15,10,59,59.5),eligible:true)
        hourSplit.record(score:yellow,yellow:0.6,red:1,at:eastern(2026,1,15,11,0,0.75),eligible:true)
        let h=hourSplit.today
        check(near(h.hours[10].yellowSeconds,0.5) && near(h.hours[11].yellowSeconds,0.75),"Interval splits across Eastern hour")

        clock=eastern(2026,1,16,9)
        let midnight=makeStore("midnight.json")
        midnight.record(score:green,yellow:0.6,red:1,at:eastern(2026,1,15,23,59,59.4),eligible:true)
        midnight.record(score:green,yellow:0.6,red:1,at:eastern(2026,1,16,0,0,0.4),eligible:true)
        midnight.flush()
        let before=midnight.day(id:"2026-01-15"),after=midnight.day(id:"2026-01-16")
        check(near(before?.hours[23].greenSeconds,0.6) && near(before?.greenSeconds,0.6),"Pre-midnight share stays on previous Eastern day")
        check(near(after?.hours[0].greenSeconds,0.4) && midnight.today.dateID=="2026-01-16","Post-midnight share lands on new day")
        check(midnight.days.map(\.dateID)==["2026-01-15","2026-01-16"],"Days are published in date order")
        // 04:59:59.5Z is 23:59:59.5 Eastern, a UTC day earlier than naive UTC grouping would suggest.
        check(DailyProgressCalendar.dateID(Date(timeIntervalSince1970:1768539599.5))=="2026-01-15","Date IDs use Eastern wall time")

        let fallBack=makeStore("fallback.json")
        let firstOne=eastern(2026,11,1,1,30)
        fallBack.record(score:green,yellow:0.6,red:1,at:firstOne,eligible:true)
        fallBack.record(score:green,yellow:0.6,red:1,at:firstOne.addingTimeInterval(1),eligible:true)
        fallBack.record(score:green,yellow:0.6,red:1,at:firstOne.addingTimeInterval(3600),eligible:true)
        fallBack.record(score:green,yellow:0.6,red:1,at:firstOne.addingTimeInterval(3601),eligible:true)
        check(near(fallBack.day(for:firstOne).hours[1].greenSeconds,2),"Repeated fall-back hour shares one bucket")

        clock=eastern(2026,1,15,12)
        let throttled=makeStore("throttled.json")
        for i in 0...10 {throttled.record(score:green,yellow:0.6,red:1,at:at(Double(i)),eligible:true)}
        check(!FileManager.default.fileExists(atPath:throttled.url.path),"Writes are throttled during monitoring")
        for i in 11...45 {throttled.record(score:green,yellow:0.6,red:1,at:at(Double(i)),eligible:true)}
        check(FileManager.default.fileExists(atPath:throttled.url.path),"Throttled write happens after save interval")
        throttled.record(score:green,yellow:0.6,red:1,at:at(46),eligible:false)
        throttled.flush()
        let restarted=makeStore("throttled.json")
        check(restarted.today==throttled.today && near(restarted.today.greenSeconds,45),"Flush on stop persists exact totals across restart")
        check(restarted.errorMessage==nil,"Clean reload has no error")
        restarted.record(score:green,yellow:0.6,red:1,at:at(47),eligible:true)
        check(near(restarted.today.greenSeconds,45),"First sample after restart does not bridge downtime")
        restarted.record(score:green,yellow:0.6,red:1,at:at(48),eligible:true)
        restarted.flush()
        check(near(makeStore("throttled.json").today.greenSeconds,46),"Restarted store keeps accumulating the same day")

        clock=eastern(2026,1,17,12)
        let nextDay=makeStore("throttled.json")
        check(nextDay.today.trackedSeconds==0 && nextDay.today.score==nil && nextDay.today.greenFraction==nil,"New day starts empty, never as green")
        check(nextDay.day(id:"2026-01-15") != nil,"History survives date change")
        check(near(nextDay.coverage(of:nextDay.day(id:"2026-01-15")!),46.0/86400),"Past-day coverage uses full day length")

        let corruptURL=directory.appendingPathComponent("corrupt.json")
        try Data("not json".utf8).write(to:corruptURL)
        let corrupt=ProgressStore(url:corruptURL,now:{clock})
        check(corrupt.errorMessage != nil && corrupt.days.isEmpty,"Corrupt history is surfaced, not invented")
        let asideFiles=try FileManager.default.contentsOfDirectory(atPath:directory.path).filter{$0.hasPrefix("corrupt.unreadable-")}
        check(asideFiles.count==1,"Corrupt history is set aside instead of overwritten")

        var tampered=weighted.today;tampered.greenSeconds += 100
        try JSONEncoder().encode(DailyProgressFile(days:[tampered])).write(to:corruptURL)
        check(ProgressStore(url:corruptURL,now:{clock}).errorMessage != nil,"Day totals inconsistent with hours rejected")

        let blocked=directory.appendingPathComponent("blocked");try Data("file".utf8).write(to:blocked)
        let failing=ProgressStore(url:blocked.appendingPathComponent("daily-progress.json"),now:{clock})
        failing.record(score:green,yellow:0.6,red:1,at:at(0),eligible:true)
        failing.record(score:green,yellow:0.6,red:1,at:at(1),eligible:true)
        failing.flush()
        check(failing.errorMessage != nil,"Save failure is surfaced")
        check(ProgressStore.defaultURL.path.hasSuffix("Posture Zone/daily-progress.json"),"Default path is Application Support/Posture Zone")
        print("\(checks) daily progress checks passed")
    }
}
