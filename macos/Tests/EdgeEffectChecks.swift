import AppKit

@main struct EdgeEffectChecks {
    static func main() throws {
        let app=NSApplication.shared
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("zone-edge-\(UUID().uuidString)")
        defer{try? FileManager.default.removeItem(at:temp)}
        let store=PreferencesStore(url:temp.appendingPathComponent("preferences.json"))
        var legacy=PosturePreferences();legacy.selectedCameraID="synthetic-camera"
        legacy.smokeDepth=6.5;legacy.delay=3;legacy.yellow=0.8;legacy.red=1.5
        let baseline=[0.0,0.4,0,0.3,0.6,0.5]
        legacy.calibrations["synthetic-camera"]=SavedCalibration(cameraID:"synthetic-camera",baseline:baseline,yellow:0.8,red:1.5)
        try store.save(legacy)
        let model=CameraModel(store:store,observesLifecycle:false,presentsVisuals:false)
        precondition(model.edgeEffectStyle == .tide,"Missing style defaults to selected Side tide")
        for style in EdgeEffectStyle.allCases {
            model.setEdgeEffectStyle(style)
            let reloaded=CameraModel(store:store,observesLifecycle:false,presentsVisuals:false)
            precondition(reloaded.edgeEffectStyle == style,"Selection survives reload")
            let saved=try store.load()!
            precondition(saved.calibrations["synthetic-camera"]?.baseline == baseline)
            precondition(saved.selectedCameraID == "synthetic-camera" && saved.smokeDepth == 6.5 && saved.delay == 3)
            let controller=LiveZoneVisualsController();controller.showsMenuGlow=true
            controller.edgeEffectStyle=style;controller.smokeDepthScale=6.5
            controller.present(.greenHalo)
            precondition(!app.windows.contains{$0.isVisible},"No style shows in green")
            controller.present(.yellowHalo,severity:1.3)
            let first=app.windows.filter{$0.isVisible}
            precondition(first.count == 2*NSScreen.screens.count && first.allSatisfy{$0.ignoresMouseEvents})
            controller.present(.redFocus,severity:2.2,progress:1)
            precondition(app.windows.filter{$0.isVisible && !$0.ignoresMouseEvents}.count == 1,"Original card retained")
            controller.edgeEffectStyle=style == .smoke ? .vignette:.smoke
            precondition(app.windows.filter{$0.isVisible}.count == first.count+1,"Switch replaces edge panels, retains glow and card")
            controller.smokeDepthScale=0
            precondition(app.windows.filter{$0.isVisible && $0.ignoresMouseEvents}.count == NSScreen.screens.count,"Zero keeps menu glow only")
            controller.smokeDepthScale=6.5
            controller.present(.hidden)
            precondition(!app.windows.contains{$0.isVisible},"Recovery is synchronous for every style")
        }
        for style in EdgeEffectStyle.allCases where style != .smoke {
            let view=PeripheralEffectView(style:style,severity:1.3,depthScale:6.5)
            view.frame=NSRect(x:0,y:0,width:920,height:680);view.layout()
            precondition(view.layer?.sublayers?.count == 5,"Bounded four gradients plus outline")
            precondition(view.layer?.sublayers?.allSatisfy{($0.animationKeys() ?? []).isEmpty} == true,"No continuous animation")
            view.setSeverity(2);view.setSeverity(1)
            precondition(view.layer?.sublayers?.allSatisfy{($0.animationKeys() ?? []).isEmpty} == true,"Retreat cancels previous color transition")
            view.setDepthScale(0)
            precondition(view.layer?.sublayers?.allSatisfy{$0.isHidden} == true,"Zero removes all edge drawing")
            precondition(view.hitTest(.zero) == nil,"Effects remain click-through")
            view.setDepthScale(6.5);view.layout()
            let layers=view.layer!.sublayers!
            let visible=layers.filter{!$0.isHidden}.count
            precondition(visible == (style == .corners || style == .horizon ? 1:style == .tide ? 2:style == .glow ? 5:4),"Style uses intended edge placement")
            if style == .corners {
                let shape=layers.last as! CAShapeLayer
                precondition(shape.path != nil && shape.fillColor == nil,"Corners are four unfilled brackets")
            }
            if style == .tide {precondition(layers.filter{!$0.isHidden}.allSatisfy{($0 as? CAGradientLayer)?.type == .radial},"Side tide has soft radial edges")}
            if style == .horizon {precondition(!layers[0].isHidden && layers.dropFirst().allSatisfy{$0.isHidden},"Horizon stays at the top edge")}

        }
        print("PASS: A through F migration, persisted choice, preserved calibration, live switching, zero, green clear, bounded layers")
    }
}
