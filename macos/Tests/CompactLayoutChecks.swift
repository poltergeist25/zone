import AppKit
import SwiftUI

@main struct CompactLayoutChecks {
    static func main() throws {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited);app.appearance=NSAppearance(named:.aqua)
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("zone-layout-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:temp)}
        let model=CameraModel(store:PreferencesStore(url:temp.appendingPathComponent("preferences.json")),observesLifecycle:false,presentsVisuals:false)
        let output=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        func render<V:View>(_ name:String,_ root:V) throws {
            let size=ZoneWindowLayout.size
            let view=NSHostingView(rootView:root.preferredColorScheme(.light))
            let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.contentView=view;view.frame=NSRect(origin:.zero,size:size)
            RunLoop.main.run(until:Date().addingTimeInterval(0.15));view.layoutSubtreeIfNeeded()
            precondition(view.frame.size==size,"State must not grow the window")
            let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))
            window.close()
        }
        try render("fresh",MainView(model:model))
        let savedStore=PreferencesStore(url:temp.appendingPathComponent("saved.json"))
        var saved=PosturePreferences();saved.selectedCameraID="synthetic-camera"
        saved.calibrations["synthetic-camera"]=SavedCalibration(cameraID:"synthetic-camera",baseline:[0,0.4,0,0.3,0.6,0.5],yellow:0.6,red:1)
        try savedStore.save(saved)
        let savedModel=CameraModel(store:savedStore,observesLifecycle:false,presentsVisuals:false)
        savedModel.cameras=[CameraChoice(id:"synthetic-camera",name:"Studio Display Camera")]
        precondition(savedModel.hasSavedCalibration && !savedModel.cameraEnabled)
        try render("saved-off",MainView(model:savedModel))
        model.active=true;model.stage="green";model.hasPose=true
        try render("capture",MainView(model:model))
        model.stage="review";model.score=0.8;model.message="Try your levels before you begin."
        try render("review",MainView(model:model))
        model.stage="monitoring";model.state="inside";model.score=0
        try render("monitoring",MainView(model:model))
        model.paused=true
        try render("paused",MainView(model:model))
        model.paused=false;model.state="lost";model.score=nil;model.message="Tracking paused. Keep your face in view."
        try render("lost",MainView(model:model))
        model.controlsPage = .progress
        try render("progress",MainView(model:model))
        model.controlsPage = .settings
        try render("settings",MainView(model:model))
        model.stop()
        print("PASS: nine native layouts retain960x720 content; synthetic state only, no camera started")
    }
}
