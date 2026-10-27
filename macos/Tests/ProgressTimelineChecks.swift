import AppKit
import SwiftUI

@main struct ProgressTimelineChecks {
    static func main() throws {
        let calendar=DailyProgressCalendar.calendar
        func date(_ id:String)->Date{DailyProgressCalendar.date(fromID:id)!}
        let week=ProgressTimeline.week(containing:date("2026-10-22"))
        precondition(week.map(DailyProgressCalendar.dateID)==["2026-10-19","2026-10-20","2026-10-21","2026-10-22","2026-10-23","2026-10-24","2026-10-25"])
        precondition(ProgressTimeline.week(containing:date("2026-10-22"),offset:-1).first.map(DailyProgressCalendar.dateID)=="2026-10-12")
        let dst=ProgressTimeline.week(containing:date("2026-11-01"))
        precondition(dst.count==7 && Set(dst.map(DailyProgressCalendar.dateID)).count==7)
        precondition(dst.allSatisfy{calendar.component(.hour,from:$0)==0},"Week uses calendar days through DST")
        var today=DayProgress(dateID:"2026-10-22")
        precondition(ProgressTimeline.hours(for:today)==9...16 && today.score==nil)
        today.add(3600,.green,hour:9)
        today.add(2736,.green,hour:10);today.add(864,.yellow,hour:10)
        today.add(2736,.green,hour:14);today.add(864,.red,hour:14)
        today.add(2160,.green,hour:15);today.add(1440,.yellow,hour:15)
        precondition(today.valid && today.trackedSeconds==14400 && today.score==86)
        var early=today;early.add(1,.green,hour:0);early.add(1,.red,hour:23)
        precondition(ProgressTimeline.hours(for:early)==0...23,"All real tracked hours remain reachable")
        precondition(ProgressTimeline.hourLabel(0)=="12 AM" && ProgressTimeline.hourLabel(12)=="12 PM" && ProgressTimeline.hourLabel(24)=="12 AM")
        precondition(ProgressTimeline.duration(14400)=="4h" && ProgressTimeline.percent(nil)=="—")
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited);app.appearance=NSAppearance(named:.aqua)
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("progress-B-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:temp)}
        var days=[today]
        for (id,score) in [("2026-10-19",82),("2026-10-20",88),("2026-10-21",79)] {
            var day=DayProgress(dateID:id);day.add(Double(score)*36,.green,hour:10);day.add(Double(100-score)*36,.red,hour:10);days.append(day)
        }
        let url=temp.appendingPathComponent("daily-progress.json")
        try JSONEncoder().encode(DailyProgressFile(days:days)).write(to:url)
        let original=try Data(contentsOf:url)
        let store=ProgressStore(url:url,now:{date("2026-10-22").addingTimeInterval(18*3600)})
        precondition(store.today.score==86 && store.day(id:"2026-10-23")==nil)
        let output=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        func render(_ name:String,_ store:ProgressStore) throws {
            let size=NSSize(width:960,height:575)
            let view=NSHostingView(rootView:ProgressViewPanel(store:store).preferredColorScheme(.light)
                .frame(width:size.width,height:size.height,alignment:.top)
                .background(Color(red:0.965,green:0.955,blue:0.925)))
            let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.contentView=view;view.frame=NSRect(origin:.zero,size:size)
            RunLoop.main.run(until:Date().addingTimeInterval(0.2));view.layoutSubtreeIfNeeded()
            precondition(view.frame.size==size)
            let image=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:image)
            try image.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))
            window.close()
        }
        try render("progress-B-example",store)
        try render("progress-B-empty",ProgressStore(url:temp.appendingPathComponent("empty.json"),now:{date("2026-10-22")}))
        precondition(tryLoad(url)==original,"Displaying history never rewrites it")
        print("PASS: daily score/empty semantics, Monday week navigation, DST dates, stored hour range and history bytes unchanged")
    }
    static func tryLoad(_ url:URL)->Data{try! Data(contentsOf:url)}
}
