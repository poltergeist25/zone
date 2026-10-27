import SwiftUI
import AppKit

private enum VisualZone:String,CaseIterable,Identifiable {
    case green="Green",yellow="Yellow",red="Red"
    var id:String{rawValue}
    var color:Color {
        switch self {case .green:return Color(red:0.26,green:0.55,blue:0.39);case .yellow:return Color(red:0.82,green:0.55,blue:0.14);case .red:return Color(red:0.76,green:0.24,blue:0.22)}
    }
    var softColor:Color {
        switch self {case .green:return Color(red:0.83,green:0.93,blue:0.85);case .yellow:return Color(red:0.98,green:0.89,blue:0.66);case .red:return Color(red:0.98,green:0.78,blue:0.72)}
    }
    var title:String {switch self{case .green:return "In your zone.";case .yellow:return "A gentle reset.";case .red:return "Out of your zone."}}
    var short:String {switch self{case .green:return "Comfortably in your zone";case .yellow:return "A little room to reset";case .red:return "Come back to your position"}}
    var detail:String {switch self{case .green:return "A quiet signal that you’re right where you want to be.";case .yellow:return "You’re nearing your edge. A small adjustment is enough.";case .red:return "Ease back toward the comfortable position you chose."}}
    var symbol:String {switch self{case .green:return "checkmark";case .yellow:return "arrow.up.right";case .red:return "arrow.up"}}
}
private enum VisualStyle:Int,CaseIterable,Identifiable {
    case halo,pill,card
    var id:Int{rawValue}
    var name:String{switch self{case .halo:return "Liquid smoke";case .pill:return "Floating glass";case .card:return "Focus card"}}
    var number:String{String(format:"%02d",rawValue+1)}
    var category:String{switch self{case .halo:return "AT THE EDGE OF YOUR ATTENTION";case .pill:return "A QUIET COMPANION";case .card:return "IMPOSSIBLE TO MISS"}}
    var explanation:String{switch self{case .halo:return "Fluid mist along every edge. Color and depth follow your posture, retreating as you improve.";case .pill:return "A small glass capsule above your work. Color, words and a little reassurance.";case .card:return "A generous reminder for sustained red, while the quiet edge mist remains."}}
}
private enum VisualPalette {
    static let paper=Color(red:0.965,green:0.955,blue:0.93)
    static let ink=Color(red:0.13,green:0.25,blue:0.20)
}

enum FocusCardLayout {
    static func frame(in available:NSRect)->NSRect {
        let width=min(740,available.width*0.9),height=min(450,available.height*0.88)
        return NSRect(x:available.midX-width/2,y:available.midY-height/2,width:width,height:height)
    }
}

final class VisualStylesController:NSObject,NSWindowDelegate {
    static let shared=VisualStylesController()
    private var gallery:NSWindow?
    private var overlay:NSPanel?
    private var dismissTimer:Timer?
    private var terminationObserver:NSObjectProtocol?
    private var diagnosticObserver:NSObjectProtocol?
    private override init() {
        super.init()
        terminationObserver=NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main){[weak self] _ in self?.dismissPreview()}
        diagnosticObserver=NotificationCenter.default.addObserver(forName:.diagnosticVisualPolicyChanged,object:nil,queue:.main){[weak self] _ in
            if DiagnosticVisualPolicy.shared.mode.suppressesOverlays {self?.dismissPreview()}
        }
    }
    deinit {
        if let terminationObserver{NotificationCenter.default.removeObserver(terminationObserver)}
        if let diagnosticObserver{NotificationCenter.default.removeObserver(diagnosticObserver)}
    }
    func showGallery() {
        if gallery==nil {
            let window=NSWindow(contentRect:NSRect(origin:.zero,size:ZoneWindowLayout.size),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            window.title="Choose your atmosphere"
            window.identifier=NSUserInterfaceItemIdentifier("PostureZone.VisualGallery")
            window.titlebarAppearsTransparent=true
            window.isReleasedWhenClosed=false
            window.contentMinSize=ZoneWindowLayout.size
            window.contentMaxSize=ZoneWindowLayout.size
            window.delegate=self
            window.contentView=NSHostingView(rootView:VisualGalleryView(controller:self))
            window.center();gallery=window
        }
        if let main=mainWindow,let window=gallery {
            window.setFrameOrigin(main.frame.origin)
            main.orderOut(nil)
        }
        gallery?.makeKeyAndOrderFront(nil)
    }
    private var mainWindow:NSWindow? {NSApp.windows.first{$0.identifier?.rawValue == "posture-main"}}
    func backToPosture() {
        dismissPreview();gallery?.orderOut(nil)
        if let origin=gallery?.frame.origin {mainWindow?.setFrameOrigin(origin)}
        mainWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification:Notification) {
        guard notification.object as? NSWindow === gallery else{return}
        dismissPreview();mainWindow?.makeKeyAndOrderFront(nil)
    }
    func showFocusPreview(){tryStyle(.card,zone:.red)}
    fileprivate func tryStyle(_ style:VisualStyle,zone:VisualZone) {
        dismissPreview()
        guard !DiagnosticVisualPolicy.shared.mode.suppressesOverlays else{return}
        let screen=gallery?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else{return}
        let usable=screen.visibleFrame
        let rect:NSRect
        switch style {
        case .halo:rect=screen.frame
        case .pill:rect=NSRect(x:usable.midX-190,y:usable.maxY-106,width:380,height:88)
        case .card:rect=FocusCardLayout.frame(in:usable)
        }
        let panel=VisualPreviewPanel(contentRect:rect,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.level = .floating
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
        panel.hidesOnDeactivate=false;panel.isReleasedWhenClosed=false;panel.animationBehavior = .none
        panel.isOpaque=false;panel.backgroundColor = .clear
        panel.hasShadow=style != .halo
        panel.ignoresMouseEvents=style == .halo
        let close:()->Void={ [weak self] in self?.dismissPreview() }
        switch style {
        case .halo:panel.contentView=NSHostingView(rootView:DesktopHalo(zone:zone))
        case .pill:panel.contentView=NSHostingView(rootView:DesktopPill(zone:zone,close:close))
        case .card:panel.contentView=NSHostingView(rootView:DesktopFocusCard(zone:zone,close:close))
        }
        overlay=panel
        panel.orderFrontRegardless()
        dismissTimer=Timer.scheduledTimer(withTimeInterval:5,repeats:false){[weak self] _ in self?.dismissPreview()}
    }
    func dismissPreview(){dismissTimer?.invalidate();dismissTimer=nil;overlay?.orderOut(nil);overlay?.close();overlay=nil}
}
private final class VisualPreviewPanel:NSPanel {
    override var canBecomeKey:Bool{false}
    override var canBecomeMain:Bool{false}
}

// Live presentation is independent of the gallery's timed preview panel.
// Continuous scores update existing edge views; red has a separate card lifetime.
final class LiveZoneVisualsController {
    var pauseAction:(()->Void)?
    private let menuGlow=MenuBarGlowController()
    var showsMenuGlow=false {
        didSet {refreshMenuGlow()}
    }
    var smokeDepthScale:CGFloat=1 {
        didSet {
            guard smokeDepthScale != oldValue else{return}
            if smokeDepthScale<=0 {clearSmoke()}
            else if showsSmoke && appearance != .hidden && haloPanels.isEmpty {createSmoke()}
            else {haloViews.forEach{$0.setDepthScale(smokeDepthScale)};edgeViews.forEach{$0.setDepthScale(smokeDepthScale)}}
        }
    }
    var edgeEffectStyle:EdgeEffectStyle = .smoke {
        didSet {
            guard edgeEffectStyle != oldValue else{return}
            clearSmoke()
            if showsSmoke && appearance != .hidden {createSmoke()}
        }
    }
    private var warningProgress=0.0
    private func refreshMenuGlow() {menuGlow.present(showsMenuGlow && appearance != .hidden,severity:severity,progress:warningProgress)}
    var showsSmoke=true {
        didSet {
            guard showsSmoke != oldValue else{return}
            if !showsSmoke {clearSmoke()}
            else if appearance != .hidden && haloPanels.isEmpty {createSmoke()}
        }
    }
    private var appearance=ZoneAppearance.hidden
    private var haloPanels:[NSPanel]=[]
    private var haloViews:[SmokeHaloView]=[]
    private var edgeViews:[PeripheralEffectView]=[]
    private var focusPanel:NSPanel?
    private var severity=0.0
    private var observers:[NSObjectProtocol]=[]
    init() {
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main){[weak self] _ in self?.present(.hidden)})
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main){[weak self] _ in self?.rebuildForDisplays()})
    }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        clearSmoke();clearFocus()
    }
    func present(_ next:ZoneAppearance,severity:Double=0,progress:Double=0) {
        // Green is a clear desktop, including legacy callers of greenHalo.
        let next:ZoneAppearance = next == .greenHalo ? .hidden:next
        let target=max(1,SmokeGeometry.clamp(severity)),changed=target != self.severity
        self.severity=target;appearance=next;warningProgress=progress;refreshMenuGlow()
        guard next != .hidden else{clearSmoke();clearFocus();return}
        if showsSmoke {
            if haloPanels.isEmpty{createSmoke()}
            else if changed{haloViews.forEach{$0.setSeverity(target)};edgeViews.forEach{$0.setSeverity(target)}}
        }
        if next == .redFocus {if focusPanel==nil{createFocus()}}
        else{clearFocus()}
    }
    private func rebuildForDisplays() {
        clearSmoke();clearFocus()
        guard appearance != .hidden else{return}
        if showsSmoke{createSmoke()};if appearance == .redFocus{createFocus()}
    }
    private func clearSmoke(){haloPanels.forEach{WarningEntranceView.remove($0)};haloPanels=[];haloViews=[];edgeViews=[]}
    private func clearFocus(){if let focusPanel{WarningEntranceView.remove(focusPanel)};focusPanel=nil}
    private func createSmoke() {
        guard smokeDepthScale>0,smokeDepthScale.isFinite else{return}
        for screen in NSScreen.screens {
            let panel=makePanel(frame:screen.frame,clickThrough:true)
            let content:NSView
            if edgeEffectStyle == .smoke {
                let view=SmokeHaloView(severity:severity,depthScale:smokeDepthScale)
                haloViews.append(view);content=view
            } else {
                let view=PeripheralEffectView(style:edgeEffectStyle,severity:severity,depthScale:smokeDepthScale)
                edgeViews.append(view);content=view
            }
            let entrance=WarningEntranceView(content:content,size:screen.frame.size)
            panel.contentView=entrance
            haloPanels.append(panel)
            entrance.appear();panel.orderFrontRegardless()
        }
    }
    private func createFocus() {
        if let screen=NSScreen.main ?? NSScreen.screens.first {
            let available=screen.visibleFrame
            let frame=FocusCardLayout.frame(in:available)
            let panel=makePanel(frame:frame,clickThrough:false)
            panel.level=NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue+1)
            let content=NSHostingView(rootView:DesktopFocusCard(zone:.red,close:{[weak self] in self?.pauseAction?()},isPreview:false))
            let entrance=WarningEntranceView(content:content,size:frame.size)
            panel.contentView=entrance
            focusPanel=panel;entrance.appear();panel.orderFrontRegardless()
        }
    }
    private func makePanel(frame:NSRect,clickThrough:Bool)->NSPanel {
        let panel=VisualPreviewPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.level = .floating;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
        panel.hidesOnDeactivate=false;panel.isReleasedWhenClosed=false;panel.animationBehavior = .none
        panel.isOpaque=false;panel.backgroundColor = .clear
        panel.hasShadow = !clickThrough;panel.ignoresMouseEvents=clickThrough
        return panel
    }
}

private struct VisualGalleryView:View {
    let controller:VisualStylesController
    @State private var zone:VisualZone = .green
    init(controller:VisualStylesController,initialZone:VisualZone = .green) {
        self.controller=controller;_zone=State(initialValue:initialZone)
    }
    var body:some View {
        GeometryReader {geometry in
            let scale=max(0.9,min(1.35,geometry.size.width/1100))
            VStack(spacing:0) {
                HStack {
                    Button(action:controller.backToPosture) {
                        Label("Back to Zone",systemImage:"chevron.left").font(.system(size:14,weight:.semibold)).padding(.horizontal,15).padding(.vertical,10)
                    }.buttonStyle(.plain).background(VisualPalette.ink.opacity(0.08),in:RoundedRectangle(cornerRadius:10)).keyboardShortcut(.cancelAction)
                    Spacer()
                    Text("Progressive liquid smoke · Sustained red focus card").font(.system(size:12)).foregroundStyle(VisualPalette.ink.opacity(0.65))
                }.padding(.horizontal,30).padding(.vertical,16)
                Divider().overlay(VisualPalette.ink.opacity(0.1))
                ScrollView {
            VStack(alignment:.leading,spacing:18) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:9) {
                        Text("ZONE · NATIVE MAC POSSIBILITIES").font(.system(size:9,weight:.bold)).tracking(1.8)
                        Text("Choose your atmosphere.").font(.system(size:32*scale,design:.serif))
                        Text("Three ways to feel your green, yellow and red. Try them over your actual desktop.").font(.system(size:12)).foregroundStyle(VisualPalette.ink.opacity(0.7))
                    }
                    Spacer()
                    Text("VISUAL\nPLAYGROUND").font(.system(size:9,weight:.medium)).tracking(1.5).multilineTextAlignment(.trailing).lineSpacing(5).foregroundStyle(VisualPalette.ink.opacity(0.55)).padding(.top,5)
                }
                HStack(spacing:16) {
                    Text("Preview a zone").font(.system(size:12,weight:.semibold))
                    Picker("Preview zone",selection:$zone) {ForEach(VisualZone.allCases){item in Text(item.rawValue).tag(item)}}.pickerStyle(.segmented).labelsHidden().frame(width:280)
                    Spacer()
                    Circle().fill(zone.color).frame(width:8,height:8)
                    Text(zone.short).font(.system(size:11)).foregroundStyle(VisualPalette.ink.opacity(0.75))
                }
                HStack(alignment:.top,spacing:18) {
                    ForEach(VisualStyle.allCases){style in
                        VStack(alignment:.leading,spacing:0) {
                            MiniDesktop(style:style,zone:zone).frame(height:170*scale).clipShape(UnevenRoundedRectangle(topLeadingRadius:19,topTrailingRadius:19))
                            VStack(alignment:.leading,spacing:12) {
                                Text(style.number+" / "+style.category).font(.system(size:8,weight:.semibold)).tracking(0.7).foregroundStyle(VisualPalette.ink.opacity(0.65)).lineLimit(1).minimumScaleFactor(0.8)
                                Text(style.name).font(.system(size:26*scale,design:.serif))
                                Text(style.explanation).font(.system(size:12*scale)).lineSpacing(4).frame(height:76*scale,alignment:.top)
                                Button(action:{controller.tryStyle(style,zone:zone)}) {
                                    HStack{Text("Try on desktop");Spacer();Image(systemName:"arrow.up.right")}.font(.system(size:12,weight:.medium)).padding(.horizontal,14).padding(.vertical,13).contentShape(Rectangle())
                                }.buttonStyle(.plain).foregroundStyle(.white).background(VisualPalette.ink,in:RoundedRectangle(cornerRadius:10))
                            }.padding(19)
                        }.background(Color.white.opacity(0.6),in:RoundedRectangle(cornerRadius:19)).overlay(RoundedRectangle(cornerRadius:19).stroke(VisualPalette.ink.opacity(0.12))).frame(maxWidth:.infinity)
                    }
                }
                HStack(alignment:.center,spacing:12) {
                    Image(systemName:"sparkles").font(.system(size:17))
                    Text("Preview only. Each appearance lasts 5 seconds. This never starts the camera or changes monitoring or your current alert style.").font(.system(size:11)).lineSpacing(4)
                    Spacer()
                    Button("Stop preview",action:controller.dismissPreview).font(.system(size:11)).buttonStyle(.bordered)
                }.foregroundStyle(VisualPalette.ink.opacity(0.7)).padding(.top,1)
            }.padding(24)
                }
            }
        }.background(VisualPalette.paper).foregroundStyle(VisualPalette.ink)
    }
}

private struct MiniDesktop:View {
    let style:VisualStyle
    let zone:VisualZone
    var body:some View {
        GeometryReader {geometry in
            ZStack {
                LinearGradient(colors:[Color(red:0.52,green:0.63,blue:0.58),Color(red:0.79,green:0.80,blue:0.67),Color(red:0.37,green:0.49,blue:0.45)],startPoint:.topLeading,endPoint:.bottomTrailing)
                    .overlay { Ellipse().fill(Color.white.opacity(0.12)).frame(width:320,height:180).rotationEffect(.degrees(-28)).offset(x:90,y:90) }
                VStack(spacing:0) {
                    HStack(spacing:7){Image(systemName:"apple.logo");Text("Your desktop");Spacer();Text("Preview")}.font(.system(size:7,weight:.medium)).padding(.horizontal,12).frame(height:18).background(.ultraThinMaterial)
                    Spacer()
                }
                VStack(alignment:.leading,spacing:9) {
                    HStack(spacing:4){ForEach(0..<3,id:\.self){_ in Circle().fill(Color.gray.opacity(0.35)).frame(width:4,height:4)};Spacer()}.padding(.bottom,3)
                    RoundedRectangle(cornerRadius:3).fill(VisualPalette.ink.opacity(0.2)).frame(width:75,height:6)
                    ForEach(0..<4,id:\.self){index in RoundedRectangle(cornerRadius:2).fill(VisualPalette.ink.opacity(0.09)).frame(width:CGFloat(index%2==0 ? 125:100),height:4)}
                    Spacer(minLength:0)
                }.padding(12).frame(width:geometry.size.width*0.64,height:111).background(Color.white.opacity(0.88),in:RoundedRectangle(cornerRadius:7)).shadow(color:.black.opacity(0.1),radius:8,y:5).offset(x:-7,y:14)
                if style == .halo {
                    SmokeHaloSurface(severity:zone == .green ? 0:zone == .yellow ? 1:2,time:2)
                } else if style == .pill {
                    HStack(spacing:6){Circle().fill(zone.color).frame(width:6,height:6);Text(zone.rawValue.uppercased()).font(.system(size:8,weight:.bold));Text("·  "+zone.title).font(.system(size:8))}.padding(.horizontal,11).padding(.vertical,9).background(.regularMaterial,in:Capsule()).overlay(Capsule().stroke(Color.white.opacity(0.6))).shadow(color:.black.opacity(0.15),radius:7,y:3).offset(y:-50)
                } else {
                    VStack(spacing:8){Text("PREVIEW · "+zone.rawValue.uppercased()).font(.system(size:7,weight:.bold)).tracking(1);Image(systemName:zone.symbol).font(.system(size:19,weight:.light));Text(zone.title).font(.system(size:21,design:.serif));Text("A little moment to reset.").font(.system(size:7))}.padding(15).frame(width:geometry.size.width*0.8,height:132).background(zone.softColor.opacity(0.95),in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(.white.opacity(0.5))).shadow(color:.black.opacity(0.15),radius:10,y:5).offset(y:6)
                }
            }.frame(width:geometry.size.width,height:geometry.size.height).clipped()
        }.accessibilityElement(children:.ignore).accessibilityLabel("\(style.name) in \(zone.rawValue) on an illustrated desktop")
    }
}

private struct DesktopHalo:View {
    let zone:VisualZone
    var isPreview=true
    var body:some View {
        ZStack {
            SmokeHaloSurface(severity:zone == .green ? 0:zone == .yellow ? 1:2)
            if isPreview {VStack {HStack(spacing:7){Circle().fill(zone.color).frame(width:7,height:7);Text("PREVIEW · \(zone.rawValue.uppercased()) HALO · 5 SECONDS").font(.system(size:10,weight:.semibold)).tracking(0.6)}.padding(.horizontal,16).padding(.vertical,10).foregroundStyle(VisualPalette.ink).background(.regularMaterial,in:Capsule()).padding(.top,50);Spacer()}}
        }.allowsHitTesting(false)
    }
}
private struct DesktopPill:View {
    let zone:VisualZone
    let close:()->Void
    var body:some View {
        HStack(spacing:12) {
            ZStack{Circle().fill(zone.color.opacity(0.17)).frame(width:34,height:34);Circle().fill(zone.color).frame(width:11,height:11)}
            VStack(alignment:.leading,spacing:4){Text("\(zone.rawValue.uppercased()) · PREVIEW").font(.system(size:9,weight:.bold)).tracking(1.4);Text(zone.short).font(.system(size:12,weight:.medium))}
            Spacer(minLength:4)
            Button(action:close){Image(systemName:"xmark").font(.system(size:10,weight:.semibold)).frame(width:30,height:30).contentShape(Circle())}.buttonStyle(.plain).accessibilityLabel("Dismiss preview")
        }.padding(.horizontal,19).padding(.vertical,16).background(.regularMaterial,in:Capsule()).overlay(Capsule().fill(zone.color.opacity(0.08)).allowsHitTesting(false)).overlay(Capsule().stroke(Color.white.opacity(0.5),lineWidth:1)).foregroundStyle(VisualPalette.ink).padding(6)
    }
}
private struct DesktopFocusCard:View {
    let zone:VisualZone
    let close:()->Void
    var isPreview=true
    var body:some View {
        VStack(spacing:16) {
            HStack{Text(isPreview ? "\(zone.rawValue.uppercased()) · VISUAL PREVIEW":"RED ZONE · A LITTLE REMINDER TO RESET").font(.system(size:9,weight:.bold)).tracking(1.8);Spacer();if isPreview {Button(action:close){Image(systemName:"xmark").font(.system(size:11)).frame(width:28,height:28).contentShape(Circle())}.buttonStyle(.plain).accessibilityLabel("Dismiss preview")}}
            Image(systemName:zone.symbol).font(.system(size:33,weight:.ultraLight)).foregroundStyle(zone.color)
            Text(zone.title).font(.system(size:isPreview ? 45:58,design:.serif)).minimumScaleFactor(0.8).lineLimit(1)
            Text(zone.detail).font(.system(size:13)).multilineTextAlignment(.center).lineSpacing(4).frame(maxWidth:370)
            if isPreview {Text("PREVIEW ONLY · CLOSES IN 5 SECONDS").font(.system(size:8,weight:.medium)).tracking(1).opacity(0.65).padding(.top,5)}
            else {
                Button("Pause reminders",action:close).buttonStyle(.plain).font(.system(size:13,weight:.semibold)).foregroundStyle(.white).padding(.horizontal,26).padding(.vertical,13).background(VisualPalette.ink,in:RoundedRectangle(cornerRadius:10))
                Text("Clears as soon as you return below your red boundary.").font(.system(size:10)).opacity(0.75)
            }
        }.padding(28).frame(maxWidth:.infinity,maxHeight:.infinity).foregroundStyle(VisualPalette.ink).background {ZStack{RoundedRectangle(cornerRadius:26).fill(.regularMaterial);RoundedRectangle(cornerRadius:26).fill(zone.softColor.opacity(0.72))}}.overlay(RoundedRectangle(cornerRadius:26).stroke(.white.opacity(0.6))).padding(7)
    }
}

// Deterministic native view entry point for offscreen render QA. No camera access.
func makeVisualGalleryView(zone:Int=0)->some View {
    VisualGalleryView(controller:.shared,initialZone:VisualZone.allCases[max(0,min(2,zone))])
}

func makeLiveFocusView()->some View {DesktopFocusCard(zone:.red,close:{},isPreview:false)}
func makeLiveHaloView(yellow:Bool=false)->some View {DesktopHalo(zone:yellow ? .yellow:.green,isPreview:false)}

func makeVisualComparisonView()->some View {VisualComparisonView()}

private struct VisualComparisonView:View {
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(alignment:.bottom) {
                VStack(alignment:.leading,spacing:10){Text("POSTURE ZONE · NATIVE MAC VISUAL PREVIEWS").font(.system(size:10,weight:.bold)).tracking(2);Text("A feeling for every zone.").font(.system(size:43,design:.serif));Text("Three ways your Mac can bring you back to yourself.").font(.system(size:14)).foregroundStyle(VisualPalette.ink.opacity(0.7))}
                Spacer();Text("3 STYLES\n3 ZONES").font(.system(size:10,weight:.semibold)).tracking(1.6).multilineTextAlignment(.trailing).lineSpacing(6).foregroundStyle(VisualPalette.ink.opacity(0.55)).padding(.bottom,5)
            }.padding(.bottom,4)
            HStack(spacing:14) {
                Color.clear.frame(width:145,height:1)
                ForEach(VisualZone.allCases){zone in HStack(spacing:8){Circle().fill(zone.color).frame(width:9,height:9);Text(zone.rawValue).font(.system(size:15,weight:.semibold));Spacer();Text(zone == .green ? "COMFORTABLE":zone == .yellow ? "NEAR THE EDGE":"TIME TO RESET").font(.system(size:8,weight:.medium)).tracking(0.5)}.padding(.horizontal,5).frame(maxWidth:.infinity)}
            }
            ForEach(VisualStyle.allCases){style in
                HStack(alignment:.center,spacing:14) {
                    VStack(alignment:.leading,spacing:10){Text(style.number).font(.system(size:10,weight:.semibold)).foregroundStyle(VisualPalette.ink.opacity(0.5));Text(style.name).font(.system(size:25,design:.serif)).fixedSize(horizontal:false,vertical:true);Text(style == .halo ? "Color at the edge.\nYour work stays clear.":style == .pill ? "A small glass signal.\nAlways in view.":"A moment to notice.\nRoom to reset.").font(.system(size:11)).lineSpacing(4).foregroundStyle(VisualPalette.ink.opacity(0.7))}.frame(width:145,alignment:.leading)
                    ForEach(VisualZone.allCases){zone in MiniDesktop(style:style,zone:zone).frame(height:190).clipShape(RoundedRectangle(cornerRadius:15)).overlay(RoundedRectangle(cornerRadius:15).stroke(VisualPalette.ink.opacity(0.14))).frame(maxWidth:.infinity)}
                }
            }
            HStack(spacing:10){Image(systemName:"sparkles");Text("Visual previews only. Try each appearance on your desktop from the app’s gallery.");Spacer();Text("PRIVATE · ON YOUR MAC").font(.system(size:9,weight:.semibold)).tracking(1)}.font(.system(size:11)).foregroundStyle(VisualPalette.ink.opacity(0.65)).padding(.top,3)
            Spacer(minLength:0)
        }.padding(32).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).background(VisualPalette.paper).foregroundStyle(VisualPalette.ink)
    }
}
