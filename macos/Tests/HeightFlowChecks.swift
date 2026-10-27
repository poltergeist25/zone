import SwiftUI
import AppKit

@main struct HeightFlowChecks {
    static func main() throws {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited);app.appearance=NSAppearance(named:.aqua)
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("zone-height-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:temporary)}
        let store=PreferencesStore(url:temporary.appendingPathComponent("preferences.json"))
        let model=CameraModel(store:store,observesLifecycle:false,presentsVisuals:false)
        let origin=ProcessInfo.processInfo.systemUptime
        func receive(_ pose:PoseFeatures?,at time:Double) {model.receive(pose,at:origin+time)}
        model.select("synthetic-height-camera");model.active=true;model.stage="green"
        let neutral=PoseFeatures([0,0.4,0,0.3,0.6,0.5])
        receive(neutral,at:0);model.capture()
        for i in 0...31 {receive(neutral,at:Double(i)/10)}
        precondition(model.monitoring && !model.capturing && model.engine.baseline != nil,"One successful capture starts monitoring automatically")
        let saved=try store.load()!.calibration(for:"synthetic-height-camera")!
        precondition(model.hasSavedCalibration && saved.baseline==model.engine.baseline!.values,"Automatic start first persists the captured height")
        precondition(!model.canUndoHeightReset && model.persistenceMessage==nil,"Successful commit leaves no pending reset or save step")
        model.setHeightBoundary(-1,isRed:false);precondition(model.yellow==0.15)
        model.setHeightBoundary(99,isRed:true);precondition(model.red==3)
        model.setHeightBoundary(99,isRed:false)
        precondition(PostureEngine.validThresholds(yellow:model.yellow,red:model.red) && model.red-model.yellow>=0.39,"Dragged levels cannot overlap")
        model.setHeightBoundary(0.6,isRed:false);model.setHeightBoundary(1,isRed:true)
        // Level adjustments remain live and persist after the automatic start.
        let adjusted=try store.load()!.calibration(for:"synthetic-height-camera")!
        precondition(adjusted.yellow==0.6 && adjusted.red==1 && adjusted.baseline==saved.baseline)
        var low=neutral;low.centerY=0.62
        receive(low,at:3.2);receive(low,at:3.7);receive(neutral,at:3.8)
        precondition(model.monitoring && model.hasSavedCalibration,"No level-practice or confirmation action is required")
        for i in 39...75 {receive(low,at:Double(i)/10)}
        precondition(model.state=="alert" && model.engine.alert,"Sustained lower height shows the card")
        receive(neutral,at:7.6)
        precondition(model.state=="inside" && model.score!<1e-8 && !model.engine.alert,"Rising clears on the same frame")
        let restored=CameraModel(store:store,observesLifecycle:false,presentsVisuals:false)
        precondition(restored.hasSavedCalibration && !restored.active && restored.yellow==model.yellow && restored.red==model.red,"Height and dragged levels survive launch without starting camera")
        receive(nil,at:7.7);precondition(model.state=="inside" && model.score==nil)
        receive(nil,at:8.8);precondition(model.state=="lost")
        receive(neutral,at:8.9);receive(neutral,at:9.3)
        model.alerts.hide();model.score=0.8;model.state="yellow"
        if CommandLine.arguments.count>1 {
            let out=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
            try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
            for width in [920] {
                let size=NSSize(width:width,height:680)
                let view=NSHostingView(rootView:MainView(model:model).preferredColorScheme(.light))
                let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
                window.isReleasedWhenClosed=false;window.contentView=view;view.frame=NSRect(origin:.zero,size:size)
                view.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.2));view.layoutSubtreeIfNeeded()
                let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
                view.cacheDisplay(in:view.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent("height-monitoring-\(width).png"))
                window.close()
            }
        }
        model.stop()
        print("PASS: single-capture automatic save/start, adjustable ordered levels, delayed red/immediate recovery, local persistence, tracking-loss reset; no camera started")
    }
}
