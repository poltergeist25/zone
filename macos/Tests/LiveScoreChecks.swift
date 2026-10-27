import Foundation
import AppKit
@main struct LiveScoreChecks {
 static func main()throws {
    _=NSApplication.shared
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent("zone-live-\(UUID().uuidString)")
    defer{try? FileManager.default.removeItem(at:dir)}
    let model=CameraModel(store:PreferencesStore(url:dir.appendingPathComponent("preferences.json")),observesLifecycle:false,presentsVisuals:false)
    let baseline=PoseFeatures([0,0.4,0,0.3,0.6,0.5])
    precondition(model.engine.restoreValidated(baseline:baseline,yellow:0.6,red:1,delay:2))
    for amount in [0.0,0.5,1.0] {
        model.setForgiveness(amount)
        precondition(abs(model.forgiveness-amount)<0.00001 && PostureEngine.validThresholds(yellow:model.yellow,red:model.red))
        precondition(model.engine.baseline?.values==baseline.values,"Forgiveness does not recalibrate")
        let saved=try PreferencesStore(url:dir.appendingPathComponent("preferences.json")).load()!
        precondition(abs(saved.yellow-model.yellow)<0.00001)
    }
    let beforeInvalid=model.forgiveness
    model.setForgiveness(.nan);precondition(model.forgiveness==beforeInvalid,"Invalid input must leave the slider unchanged")
    precondition(LiveScoreStore.value(deviation:0,yellow:0.6,red:1)==100)
    precondition(LiveScoreStore.value(deviation:0.6,yellow:0.6,red:1)==85)
    precondition(LiveScoreStore.value(deviation:1,yellow:0.6,red:1)==50)
    precondition(LiveScoreStore.value(deviation:.nan,yellow:0.6,red:1)==nil)
    let live=LiveScoreStore(),origin=Date()
    for i in 0...700 {live.record(deviation:Double(i%10)/10,yellow:0.6,red:1,at:origin.addingTimeInterval(Double(i)),eligible:true)}
    precondition(live.points.count<=301,"Five-minute history is bounded")
    live.record(deviation:nil,yellow:0.6,red:1,at:origin.addingTimeInterval(700.2),eligible:false)
    precondition(live.current==nil && live.points.last?.value==nil,"Loss creates a gap immediately")
    live.record(deviation:0,yellow:0.6,red:1,at:origin.addingTimeInterval(720),eligible:true)
    precondition(live.points[live.points.count-2].value==nil && live.current==100,"Recovery never bridges an absence")
    live.record(deviation:0.8,yellow:0.6,red:1,at:origin,eligible:true)
    precondition(live.current==100,"Out of order samples cannot rewind the chart")
    let dense=LiveScoreStore()
    for i in 0...1200 {dense.record(deviation:Double(i%10)/10,yellow:0.6,red:1,at:origin.addingTimeInterval(Double(i)/3),eligible:true)}
    precondition((899...903).contains(dense.points.count),"Five minutes retain every3fps observation without truncating the time window")
    precondition(dense.points.last!.date.timeIntervalSince(dense.points.first!.date)>=299,"Every motion option still spans five minutes")
    precondition(dense.points.filter{$0.originalSample}.count<=302,"Original comparison keeps its approximate one-second detail")
    dense.interrupt(at:origin.addingTimeInterval(400.05))
    precondition(dense.current==nil && dense.points.last!.value==nil,"Fast plotting cannot delay a loss gap")
    precondition(dense.currentEndpoint(at:origin.addingTimeInterval(400.1))==nil,"Missing tracking must immediately remove the live point")
    dense.record(deviation:0,yellow:0.6,red:1,at:origin.addingTimeInterval(401),eligible:true)
    precondition(dense.currentEndpoint(at:origin.addingTimeInterval(402.5))?.value==100,"The live point follows a fresh valid sample")
    precondition(dense.currentEndpoint(at:origin.addingTimeInterval(402.51))==nil,"A stale last value must not look like a fresh reading")
    precondition(dense.currentEndpoint(at:origin.addingTimeInterval(400.9))==nil,"A future sample cannot be presented early")
    let summary=dense.historyDescription(at:origin.addingTimeInterval(401),inactiveStatus:"Paused")
    precondition(summary.contains("ranged from") && summary.contains("Gaps"),"Accessible history describes range and interruptions")
    let expired=dense.historyDescription(at:origin.addingTimeInterval(800),inactiveStatus:"Paused")
    precondition(expired.contains("No readings in the last five minutes"),"History summary cannot describe readings outside the chart window")
    model.stop()
    print("PASS: forgiveness ordered/persistent without baseline mutation; live scoring anchors, bounded history, loss gaps and no rewind")
 }
}
