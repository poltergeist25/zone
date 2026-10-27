import AppKit
import SwiftUI

/// Synthetic geometry and layout only. Never starts a camera or uses the real profile.
@main struct HeightPanelChecks {
    static func main() throws {
        for height in [175.0,240,360,460] {
            let scale=HeightMeterScale(height:height)
            precondition(scale.travel>0 && scale.y(0)==HeightMeterScale.top)
            precondition(abs(scale.y(3)-(height-HeightMeterScale.bottom))<1e-8,"Meter reaches its full available vertical extent")
            for level in [0.0,0.15,0.45,0.85,1.5,3] {
                precondition(abs(scale.value(at:scale.y(level))-level)<1e-8,"Drag mapping must preserve thresholds at every supported meter height")
            }
            precondition(scale.y(-1)==scale.y(0) && scale.y(4)==scale.y(3),"Markers stay inside the same calibrated range")
            precondition(scale.value(at:HeightMeterScale.top-10)<0,"Out-of-range drags still reach existing model validation")
        }
        precondition(HeightMeterScale(height:0).travel>0,"Transient short proposals cannot divide by zero")
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited);app.appearance=NSAppearance(named:.aqua)
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("zone-height-panel-\(UUID().uuidString)")
        defer{try? FileManager.default.removeItem(at:temp)}
        let camera="synthetic-height-panel-camera"
        var preferences=PosturePreferences();preferences.selectedCameraID=camera
        preferences.calibrations[camera]=SavedCalibration(cameraID:camera,baseline:[0,0.4,0,0.3,0.6,0.5],yellow:0.45,red:0.85)
        let store=PreferencesStore(url:temp.appendingPathComponent("preferences.json"));try store.save(preferences)
        let original=try Data(contentsOf:store.url)
        let model=CameraModel(store:store,observesLifecycle:false,presentsVisuals:false)
        model.cameras=[CameraChoice(id:camera,name:"Studio Display Camera")]
        let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        func render(_ name:String)throws {
            let size=ZoneWindowLayout.size
            let view=NSHostingView(rootView:MainView(model:model).preferredColorScheme(.light))
            let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.contentView=view;view.frame=NSRect(origin:.zero,size:size)
            RunLoop.main.run(until:Date().addingTimeInterval(0.15));view.layoutSubtreeIfNeeded()
            precondition(view.frame.size==size,"Meter growth cannot grow the controls window")
            let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))
            window.close()
        }
        try render("height-panel-camera-off")
        // Illustrative recent samples expose the live chart geometry in renders.
        let chartNow=Date()
        for second in 0...300 {
            let deviation=0.4+0.35*sin(Double(second)/22)
            model.liveScore.record(deviation:deviation,yellow:0.45,red:0.85,at:chartNow.addingTimeInterval(Double(second)-300),eligible:true)
        }
        model.active=true;model.stage="monitoring";model.state="inside";model.score=0;model.hasPose=true
        try render("height-panel-tracking")
        model.paused=true;model.hasPose=false;model.score=nil;model.state="paused"
        try render("height-panel-paused")
        model.paused=false;model.state="lost";model.message="Tracking paused. Bring your face back into view."
        try render("height-panel-lost")
        model.stop()
        let after=try Data(contentsOf:store.url)
        precondition(after==original,"Layout changes must not rewrite saved height/levels")
        print("PASS: flexible meter range/drag geometry, full extent, transient bounds, fixed-size off/tracking/paused/lost native renders, unchanged saved levels; synthetic only")
    }
}
