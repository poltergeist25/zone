import AppKit
import Foundation

/// Card-only preference: genuine production panels, synthetic poses and store.
@main struct RedAlertPreferenceChecks {
    static func main() throws {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("zone-red-switch-\(UUID().uuidString)")
        defer{try? FileManager.default.removeItem(at:directory)}
        let store=PreferencesStore(url:directory.appendingPathComponent("preferences.json"))
        let baseline=PoseFeatures([0,0.4,0,0.3,0.6,0.4])
        var low=baseline;low.centerY=0.57
        var prefs=PosturePreferences();prefs.selectedCameraID="synthetic-card";prefs.yellow=0.45;prefs.red=0.85
        prefs.menuBarStyle="score" // Legacy number preference must not reappear.
        prefs.calibrations["synthetic-card"]=SavedCalibration(cameraID:"synthetic-card",baseline:baseline.values,yellow:0.45,red:0.85)
        try store.save(prefs)
        let model=CameraModel(store:store,observesLifecycle:false,presentsVisuals:true)
        defer{model.stop();VisualStylesController.shared.dismissPreview()}
        precondition(model.redAlertEnabled && model.menuBarStyle == .color,"Default card stays on; old number style is normalized")
        model.active=true;model.stage="monitoring"
        precondition(model.engine.restoreValidated(baseline:baseline,yellow:0.45,red:0.85,delay:2))
        func focusVisible()->Bool {app.windows.contains{$0.isVisible && !$0.ignoresMouseEvents}}
        func edgesVisible()->Bool {app.windows.contains{$0.isVisible && $0.ignoresMouseEvents}}
        for i in 0...9 {model.receive(low,at:Double(i)*0.3)}
        precondition(model.engine.alert && focusVisible(),"Enabled sustained red shows the real focus panel")
        let score=model.score
        model.setRedAlertEnabled(false)
        precondition(!model.redAlertEnabled && !focusVisible() && edgesVisible(),"Disabling clears the card immediately and preserves edge effects")
        precondition(model.monitoring && model.active && model.engine.alert && model.score==score && model.engine.baseline!.values==baseline.values,"Card preference cannot alter camera, classification, score or calibration")
        let reopened=CameraModel(store:store,observesLifecycle:false,presentsVisuals:false)
        precondition(!reopened.redAlertEnabled && reopened.hasSavedCalibration && !reopened.active,"Disabled card persists while ordinary launch remains camera off")
        reopened.stop()
        let beforePreview=try Data(contentsOf:store.url)
        model.alerts.show(preview:true)
        precondition(focusVisible() && !model.redAlertEnabled,"Explicit preview works even with automatic card disabled")
        let afterPreview=try Data(contentsOf:store.url)
        precondition(beforePreview==afterPreview,"Preview cannot silently enable the card")
        VisualStylesController.shared.dismissPreview()
        precondition(!focusVisible() && edgesVisible())
        model.setRedAlertEnabled(true)
        precondition(focusVisible() && model.engine.alert,"Re-enabling presents the existing completed red delay")
        model.setRedAlertEnabled(false)
        model.receive(baseline,at:3)
        precondition(!focusVisible() && !edgesVisible() && !model.engine.alert,"A green frame still immediately removes every effect")
        let saved=try store.load()!.calibration(for:"synthetic-card")!
        precondition(saved.baseline==baseline.values && saved.yellow==0.45 && saved.red==0.85)
        print("PASS: card-only toggle immediate clearing, retained red edges/classification, persisted disabled setting, legacy score normalization, independent preview, re-enable and immediate green; synthetic only")
    }
}
