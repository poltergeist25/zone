import AppKit
import SwiftUI

@main struct DailyBalanceChecks {
    static func main() throws {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited);app.appearance=NSAppearance(named:.aqua)
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("zone-balance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:temp)}
        let date=DailyProgressCalendar.date(fromID:"2026-10-23")!
        var mixed=DayProgress(dateID:"2026-10-23")
        mixed.add(551,.green,hour:19);mixed.add(248,.yellow,hour:19);mixed.add(281,.red,hour:19)
        let slices=DailyBalanceSummary.segments(mixed)
        precondition(mixed.valid && mixed.trackedSeconds==1080)
        precondition(slices.map(\.title)==["Green","Yellow","Red"])
        precondition(slices.map{ProgressTimeline.percent($0.fraction)}==["51%","23%","26%"])
        precondition(slices.first!.start==0 && abs(slices.last!.end-1)<1e-10)
        precondition(zip(slices,slices.dropFirst()).allSatisfy{abs($0.end-$1.start)<1e-10},"The ring represents one complete distribution")
        let empty=DayProgress(dateID:"2026-10-23")
        precondition(DailyBalanceSummary.segments(empty).allSatisfy{$0.fraction==nil && $0.start==0 && $0.end==0},"Missing time has no score or colored segment")
        var one=empty;one.add(3600,.green,hour:12)
        let single=DailyBalanceSummary.segments(one)
        precondition(single[0].fraction==1 && single[0].end==1 && single[1].fraction==0 && single[2].fraction==0)
        var tiny=one;tiny.add(0.01,.red,hour:12)
        precondition(DailyBalanceSummary.segments(tiny).allSatisfy{$0.start.isFinite && $0.end.isFinite && $0.end >= $0.start && $0.end<=1},"Tiny positive shares retain finite ordered bounds")
        precondition(DailyBalanceSummary.duration(551)=="9m 11s" && DailyBalanceSummary.duration(248)=="4m 8s")
        precondition(DailyBalanceSummary.duration(0.4)=="<1s" && DailyBalanceSummary.duration(0)=="0s" && DailyBalanceSummary.duration(3661)=="1h 1m")
        let url=temp.appendingPathComponent("daily-progress.json")
        try JSONEncoder().encode(DailyProgressFile(days:[mixed])).write(to:url)
        let original=try Data(contentsOf:url)
        let store=ProgressStore(url:url,now:{date.addingTimeInterval(20*3600)})
        precondition(abs(store.today.score! - (551+124)*100/1080.0)<1e-10,"Existing weighted score is unchanged")
        let out=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        func render<V:View>(_ name:String,_ root:V,_ size:NSSize)throws {
            let view=NSHostingView(rootView:root.preferredColorScheme(.light))
            let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.contentView=view;view.frame=NSRect(origin:.zero,size:size)
            RunLoop.main.run(until:Date().addingTimeInterval(0.15));view.layoutSubtreeIfNeeded()
            let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent(name+".png"))
            window.close()
        }
        for (name,day) in [("mixed",mixed),("empty",empty),("all-green",one),("tiny",tiny)] {
            try render("balance-"+name,DailyBalanceChart(day:day).padding(16).background(Color(red:0.965,green:0.955,blue:0.925)),NSSize(width:896,height:254))
        }
        try render("progress-C",ProgressViewPanel(store:store).frame(width:960,height:575,alignment:.top).background(Color(red:0.965,green:0.955,blue:0.925)),NSSize(width:960,height:575))
        let after=try Data(contentsOf:url)
        precondition(after==original,"Viewing C must not rewrite the source history")
        print("PASS: C ring proportions, no-data/zero/single/tiny shares, exact durations, unchanged score/history and five native layouts; synthetic data only")
    }
}
