import SwiftUI
import AppKit
import AVFoundation

private let forest=Color(red:0.13,green:0.25,blue:0.19)
private let paper=Color(red:0.965,green:0.955,blue:0.925)
private let mint=Color(red:0.88,green:0.93,blue:0.86)

#if !POSTURE_RENDER
@main struct ZoneApp {
    static func main() {
        if CommandLine.arguments.contains("--list-cameras") {
            CameraModel.devices().forEach {print("\($0.localizedName) | \($0.deviceType.rawValue)")}
            return
        }
        let app=NSApplication.shared
        let delegate=ZoneAppDelegate()
        app.delegate=delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {app.run()}
    }
}
#endif

enum ZoneWindowLayout {
    static let size=NSSize(width:960,height:720)
    static let heightColumnWidth:CGFloat=260
}

enum ControlsPage:String,CaseIterable {case posture="Posture",progress="Progress",settings="Settings"}

enum ZoneBranding {
    static func copyright(at date:Date)->String {
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=TimeZone(identifier:"America/New_York")!
        return "© \(calendar.component(.year,from:date)) Gramercy Systems Inc"
    }
}

// Use the available content height for both columns, with natural measurement
// only when no height is proposed. No geometry-observer feedback is needed.
struct BalancedPostureColumns:Layout {
    var rightWidth:CGFloat=ZoneWindowLayout.heightColumnWidth
    var spacing:CGFloat=28
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ())->CGSize {
        let width=proposal.width ?? 904
        guard subviews.count==2 else{return .zero}
        let left=max(0,width-rightWidth-spacing)
        let height=proposal.height ?? max(subviews[0].sizeThatFits(ProposedViewSize(width:left,height:nil)).height,
                       subviews[1].sizeThatFits(ProposedViewSize(width:rightWidth,height:nil)).height)
        return CGSize(width:width,height:height)
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        guard subviews.count==2 else{return}
        let left=max(0,bounds.width-rightWidth-spacing)
        subviews[0].place(at:bounds.origin,anchor:.topLeading,proposal:ProposedViewSize(width:left,height:bounds.height))
        subviews[1].place(at:CGPoint(x:bounds.minX+left+spacing,y:bounds.minY),anchor:.topLeading,
                          proposal:ProposedViewSize(width:rightWidth,height:bounds.height))
    }
}

struct MainView:View {
    @ObservedObject var model:CameraModel
    var onHideControls:()->Void = {}
    var onQuit:()->Void = {}
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:24) {
                Spacer()
                HStack(spacing:32) {
                    ForEach(ControlsPage.allCases,id:\.self) {page in
                        Button {model.controlsPage=page} label: {
                            Text(page.rawValue)
                                .font(.system(size:14,weight:model.controlsPage==page ? .semibold:.regular))
                                .foregroundStyle(forest.opacity(model.controlsPage==page ? 1:0.68))
                                .frame(width:80).padding(.vertical,8)
                                .contentShape(Rectangle())
                                .overlay(alignment:.bottom) {
                                    if model.controlsPage==page {
                                        Capsule().fill(forest).frame(width:54,height:1.5)
                                    }
                                }
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(model.controlsPage==page ? .isSelected:[])
                            .help("Show \(page.rawValue.lowercased())")
                    }
                }.accessibilityElement(children:.contain).accessibilityLabel("Controls page")
                Spacer()
            }.padding(.horizontal,28).padding(.vertical,12)
            Divider().overlay(forest.opacity(0.1))
            Group {
                switch model.controlsPage {
                case .posture:posturePage
                case .progress:ProgressViewPanel(store:model.progressStore).padding(.top,12)
                case .settings:settingsPage
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
            Divider().overlay(forest.opacity(0.1))
            HStack {
                TimelineView(.everyMinute){context in
                    Text(ZoneBranding.copyright(at:context.date)).font(.system(size:11)).foregroundStyle(forest.opacity(0.7))
                }
                Spacer()
                Label("Private on this Mac",systemImage:"lock.shield")
                    .font(.system(size:13,weight:.medium))
                    .padding(.horizontal,12).padding(.vertical,8)
                    .background(mint.opacity(0.7),in:Capsule())
            }.padding(.horizontal,28).padding(.vertical,12)
        }.frame(width:ZoneWindowLayout.size.width,height:ZoneWindowLayout.size.height)
        .background(paper).foregroundStyle(forest)
    }
    private var posturePage:some View {
        BalancedPostureColumns {
            VStack(alignment:.leading,spacing:16) {
                LiveScoreChart(store:model.liveScore,inactiveStatus:inactiveTrackingStatus)
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
                HStack(alignment:.center,spacing:16) {
                    cameraPanel
                    VStack(alignment:.leading,spacing:9) {
                        cameraToggle
                        cameraChooser
                        Text(model.loading ? "Opening your camera…":model.paused ? "Height saved.":!model.active ? "Your video stays on this Mac.":model.state=="lost" ? "Bring your face back into view.":"The dotted line is your chosen height.")
                            .font(.system(size:11)).foregroundStyle(forest.opacity(0.7))
                            .fixedSize(horizontal:false,vertical:true)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.frame(height:102)
            }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            heightPanel.frame(width:ZoneWindowLayout.heightColumnWidth)
        }.padding(28)
    }
    private var cameraPanel:some View {
        ZStack {
            RoundedRectangle(cornerRadius:13).fill(forest)
            // Keep the preview attached while paused; cover its last frame honestly.
            if model.active || model.loading {
                CameraPreview(model:model).clipShape(RoundedRectangle(cornerRadius:13))
            }
            if !model.active || model.paused {
                RoundedRectangle(cornerRadius:13).fill(forest)
                VStack(spacing:8) {
                    Image(systemName:model.paused ? "pause.circle":"person.crop.rectangle")
                        .font(.system(size:36,weight:.ultraLight))
                        .accessibilityLabel(model.paused ? "Camera paused":"Camera off")
                }.foregroundStyle(mint)
            }
            if model.active && !model.paused {
                FaceHeightGuide(points:model.landmarks,aspect:model.frameAspect,baseline:model.engine.baseline.map{$0.landmarkHeight?.referenceLineY ?? $0.centerY})
            }
            if model.capturing {
                Text("\(max(1,Int(ceil(3.0*(1-model.progress)))))")
                    .font(.system(size:40,design:.serif)).foregroundStyle(.white).shadow(radius:8)
                    .allowsHitTesting(false)
            }
        }.frame(width:180,height:102)
    }
    private var cameraToggle:some View {
        Toggle(model.cameraEnabled ? "Camera on":"Camera off",isOn:Binding(get:{model.cameraEnabled},set:{model.setCameraEnabled($0)}))
            .toggleStyle(.switch).controlSize(.small)
            .font(.system(size:12,weight:.semibold)).tint(Color(red:0.25,green:0.56,blue:0.40))
            .disabled(model.selectedID.isEmpty && !model.cameraEnabled)
            .help("Turn the selected camera on or off. Your saved height is kept.")
    }
    private var cameraChooser:some View {
        HStack(spacing:10) {
            Picker("Camera",selection:Binding(get:{model.selectedID},set:{model.select($0)})) {
                if model.selectedID.isEmpty {Text("Choose a camera").tag("")}
                ForEach(model.cameras){camera in Text(camera.name).tag(camera.id)}
            }.labelsHidden().frame(maxWidth:.infinity)
            Button(action:model.refreshCameras){Image(systemName:"arrow.clockwise")}
                .accessibilityLabel("Refresh cameras").help("Refresh available cameras")
        }.controlSize(.regular)
    }
    private var heightPanel:some View {
        VStack(alignment:.leading,spacing:12) {
            if model.paused {
                VStack(alignment:.leading,spacing:5) {
                    Text("Paused").font(.system(size:16,weight:.semibold))
                    Text("Camera off · height saved").font(.system(size:11)).foregroundStyle(forest.opacity(0.7))
                }
            }
            if !model.paused && (model.loading || model.state=="error" || (model.active && (model.bottomExitHeld || model.score == nil || model.stage=="green" || model.state=="lost"))) {
                Text(model.message).font(.system(size:12)).lineSpacing(3)
                    .fixedSize(horizontal:false,vertical:true)
            }
            if !model.paused && !model.active && !model.loading && model.state != "error" {
                Text(model.hasSavedCalibration ? "Turn Camera on to resume.":"Choose a camera, then turn Camera on to set your height.")
                    .font(.system(size:12)).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
            }
            if let problem=model.persistenceMessage {
                Label(problem,systemImage:"exclamationmark.circle").font(.system(size:11,weight:.medium))
                    .foregroundStyle(Color(red:0.65,green:0.18,blue:0.15)).fixedSize(horizontal:false,vertical:true)
            }
            if model.capturing {ProgressView(value:model.progress).tint(forest)}
            if model.stage=="review" || model.monitoring || (!model.active && model.hasSavedCalibration) {
                HeightThermometer(score:model.active && !model.paused && model.hasPose ? model.score:nil,
                                  yellow:model.yellow,red:model.red,onChange:model.setHeightBoundary,travel:144,
                                  fillsAvailableHeight:true,
                                  inactiveStatus:inactiveTrackingStatus)
                    .frame(maxHeight:.infinity)
            }
            heightActions
            if model.canUndoHeightReset {
                Button("Go back",action:model.undoHeightReset)
                    .buttonStyle(.plain).font(.system(size:12,weight:.medium)).underline().disabled(model.loading)
            }
        }.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .background(mint,in:RoundedRectangle(cornerRadius:22))
    }
    private var inactiveTrackingStatus:String {
        if model.paused {return "Paused"}
        if model.loading {return "Starting camera"}
        if model.state=="error" {return "Tracking unavailable"}
        if !model.active {return "Camera off"}
        if model.state=="lost" || !model.hasPose {return "Looking for you"}
        return "Finding your height"
    }
    @ViewBuilder private var heightActions:some View {
        if model.active && model.stage=="green" {
            Button(model.capturing ? "Hold still…":"Set my height",action:model.capture)
                .buttonStyle(PrimaryButton()).disabled(!model.hasPose || model.capturing)
        } else if model.active && model.stage=="review" {
            VStack(spacing:12) {
                Button("Try saving again",action:model.confirm).buttonStyle(PrimaryButton())
                    .disabled(!model.hasPose || model.paused || !PostureEngine.validThresholds(yellow:model.yellow,red:model.red))
                Button("Set my height again",action:model.back).buttonStyle(.plain).font(.system(size:12))
            }
        } else if model.active && model.monitoring {
            VStack(alignment:.leading,spacing:10) {
                HStack(spacing:10) {
                    Button(model.paused ? "Resume":"Pause",action:model.togglePause).buttonStyle(PrimaryButton())
                    Button("Reset height",action:model.restartSetup)
                        .buttonStyle(.plain).font(.system(size:12,weight:.regular))
                        .frame(width:96,height:42)
                        .background(.white.opacity(0.35),in:RoundedRectangle(cornerRadius:10))
                        .overlay(RoundedRectangle(cornerRadius:10).stroke(forest.opacity(0.12),lineWidth:0.5))
                }
                if let until=model.pauseUntil {
                    Text("Resumes at \(Self.pauseTime(until))").font(.system(size:11)).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var settingsPage:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Text("Settings").font(.system(size:30,design:.serif))
                VStack(spacing:20) {
                    forgiveness
                    Divider().overlay(forest.opacity(0.1))
                    VStack(alignment:.leading,spacing:14) {
                        HStack {
                            Text("Red alert").font(.system(size:13,weight:.semibold))
                            Spacer()
                            Toggle("Red alert",isOn:Binding(get:{model.redAlertEnabled},set:{model.setRedAlertEnabled($0)}))
                                .toggleStyle(.switch).labelsHidden().tint(forest)
                                .accessibilityLabel("Automatic red alert")
                                .help("Show the focus card when you stay in red. Edge effects remain on.")
                        }
                        reminderTiming
                    }
                    Divider().overlay(forest.opacity(0.1))
                    VStack(alignment:.leading,spacing:10) {
                        HStack {
                            Text("Effect strength").font(.system(size:13,weight:.semibold))
                            Spacer()
                            Text("\(model.smokeDepth.formatted(.number.precision(.fractionLength(0...1))))×")
                                .font(.system(size:12)).monospacedDigit()
                        }
                        Slider(value:Binding(get:{model.smokeDepth},set:{model.setSmokeDepth($0)}),in:0...10)
                            .tint(forest).accessibilityLabel("Effect strength")
                        Text("Default: \(PosturePreferences.defaultEffectStrength.formatted(.number.precision(.fractionLength(0...1))))×")
                            .font(.system(size:11)).foregroundStyle(.secondary)
                    }
                }.padding(22).background(mint,in:RoundedRectangle(cornerRadius:20))
                if let problem=model.persistenceMessage {
                    Label(problem,systemImage:"exclamationmark.circle").font(.system(size:12))
                        .foregroundStyle(Color(red:0.65,green:0.18,blue:0.15)).fixedSize(horizontal:false,vertical:true)
                }
                HStack {
                    Spacer()
                    Button(action:onQuit) {
                        Label("Quit app",systemImage:"power")
                            .font(.system(size:14,weight:.semibold)).frame(minWidth:134,minHeight:32)
                    }.buttonStyle(.borderedProminent).controlSize(.large).tint(forest)
                        .help("Stop the camera and quit Zone (⌘Q)")
                }
            }.frame(maxWidth:620,alignment:.leading).padding(.horizontal,28).padding(.vertical,24).frame(maxWidth:.infinity)
        }
    }
    private var forgiveness:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("Forgiveness").font(.system(size:13,weight:.semibold))
            Slider(value:Binding(get:{model.forgiveness},set:{model.setForgiveness($0)}),in:0...1)
                .tint(forest).accessibilityLabel("Posture forgiveness")
                .help("Moves both yellow and red boundaries while keeping your chosen height. Left is stricter; right gives more room to move.")
            ZStack {
                Text("Default")
                HStack {Text("Strict");Spacer();Text("Forgiving")}
            }.font(.system(size:11)).foregroundStyle(.secondary)
        }
    }
    private static func pauseTime(_ date:Date)->String {
        let formatter=DateFormatter();formatter.timeZone=TimeZone(identifier:"America/New_York");formatter.dateFormat="h:mm a z";return formatter.string(from:date)
    }
    private var reminderTiming:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack{Text("Delay").font(.system(size:13,weight:.semibold));Spacer();Text(String(format:"%.1f seconds",model.delay)).font(.system(size:12)).monospacedDigit()}
            Slider(value:Binding(get:{model.delay},set:{model.delay=$0;model.applyThresholds()}),in:1...5).tint(forest).accessibilityLabel("Red alert delay")
            Text("Default: \(PosturePreferences.defaultAlertDelay.formatted(.number.precision(.fractionLength(0...1)))) seconds")
                .font(.system(size:11)).foregroundStyle(.secondary)
        }
    }

}

struct PrimaryButton:ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration:Configuration)->some View {
        configuration.label.font(.system(size:12,weight:.semibold)).foregroundStyle(.white)
            .frame(maxWidth:.infinity).frame(height:42).padding(.horizontal,12)
            .background(forest.opacity(configuration.isPressed ? 0.8:1),in:RoundedRectangle(cornerRadius:10))
            .opacity(isEnabled ? 1:0.45)
    }
}
private struct SecondaryButton:ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration:Configuration)->some View {
        configuration.label.font(.system(size:12,weight:.semibold)).foregroundStyle(forest)
            .frame(maxWidth:.infinity).frame(height:42).padding(.horizontal,12)
            .background(Color.white.opacity(configuration.isPressed ? 0.85:0.6),in:RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(forest.opacity(0.18)))
            .opacity(isEnabled ? 1:0.45)
    }
}

final class PreviewView:NSView {
    let preview=AVSampleBufferDisplayLayer()
    override init(frame:NSRect){super.init(frame:frame);wantsLayer=true;layer?.backgroundColor=NSColor.black.cgColor;layer?.addSublayer(preview);preview.videoGravity = .resizeAspect;preview.setAffineTransform(CGAffineTransform(scaleX:-1,y:1))}
    required init?(coder:NSCoder){fatalError("Not supported")}
    override func layout(){super.layout();preview.frame=bounds}
}
struct CameraPreview:NSViewRepresentable {
    let model:CameraModel
    func makeCoordinator()->CameraModel {model}
    func makeNSView(context:Context)->PreviewView{let view=PreviewView();model.setPreviewLayer(view.preview);return view}
    func updateNSView(_ view:PreviewView,context:Context){}
    static func dismantleNSView(_ view:PreviewView,coordinator:CameraModel){coordinator.setPreviewLayer(nil);view.preview.sampleBufferRenderer.flush()}
}

final class ZoneAlertController {
    private let live=LiveZoneVisualsController()
    private var policyObserver:NSObjectProtocol?
    private var appearance=ZoneAppearance.hidden
    private var severity=0.0
    private var progress=0.0
    private var appliedMode:DiagnosticVisualMode?
    private var redAlertEnabled=true
    init() {
        policyObserver=NotificationCenter.default.addObserver(forName:.diagnosticVisualPolicyChanged,object:nil,queue:.main){[weak self] _ in self?.presentCurrent()}
        presentCurrent()
    }
    deinit {if let policyObserver{NotificationCenter.default.removeObserver(policyObserver)}}
    var pauseAction:(()->Void)? {didSet{live.pauseAction=pauseAction}}
    func setReminderMode(_ mode:ReminderMode,depth:CGFloat?=nil){
        live.smokeDepthScale = depth ?? mode.smokeScale
    }
    func setEdgeEffectStyle(_ style:EdgeEffectStyle){live.edgeEffectStyle=style}
    func setRedAlertEnabled(_ enabled:Bool) {
        guard redAlertEnabled != enabled else{return}
        redAlertEnabled=enabled
        if !enabled {VisualStylesController.shared.dismissPreview()}
        presentCurrent()
    }
    func update(_ result:ZoneResult,monitoring:Bool,paused:Bool,tracking:Bool) {
        appearance=ZoneAppearance.resolve(result,monitoring:monitoring,paused:paused,tracking:tracking)
        severity=result.haloSeverity;progress=result.alertProgress
        presentCurrent()
    }
    private func presentCurrent() {
        let mode=DiagnosticVisualPolicy.shared.mode
        if mode.suppressesOverlays {live.present(.hidden)}
        if appliedMode != mode {
            appliedMode=mode
            live.showsSmoke=mode.showsSmoke
            live.showsMenuGlow=mode.showsMenuGlow
            if mode.suppressesOverlays {VisualStylesController.shared.dismissPreview()}
        }
        // Retain the latest presentation while ablated, so expiry/removal can
        // restore it without requiring a new camera result or changing tracking.
        if !mode.suppressesOverlays {
            // Suppress only the card. Red severity and its quiet edge feedback
            // remain intact, independent of whether the card is enabled.
            let presented=appearance == .redFocus && !redAlertEnabled ? ZoneAppearance.yellowHalo:appearance
            live.present(presented,severity:severity,progress:progress)
        }
    }
    func show(preview:Bool) {if preview{VisualStylesController.shared.showFocusPreview()}}
    func hideReminder(){appearance = .hidden;presentCurrent()}
    func hide(){appearance = .hidden;presentCurrent()}
}
struct MainWindowIdentity:NSViewRepresentable {
    func makeNSView(context:Context)->NSView {NSView()}
    func updateNSView(_ view:NSView,context:Context) {DispatchQueue.main.async {view.window?.identifier=NSUserInterfaceItemIdentifier("posture-main")}}
}
