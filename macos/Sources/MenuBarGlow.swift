import AppKit

// A click-through wash over the existing menu bar. Menus and their labels remain
// native; no system appearance settings or screen-recording access are needed.
final class MenuBarGlowController {
    private(set) var panels:[NSPanel]=[]
    private var views:[MenuBarGlowView]=[]
    private var observer:NSObjectProtocol?
    private var visible=false
    private var severity=0.0
    private var progress=0.0
    init() {
        observer=NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main){[weak self] _ in
            guard let self else{return};self.clear();if self.visible{self.create()}
        }
    }
    deinit {if let observer{NotificationCenter.default.removeObserver(observer)};clear()}
    static func frame(for screen:NSScreen)->NSRect {
        let height=max(NSStatusBar.system.thickness,screen.safeAreaInsets.top)
        return NSRect(x:screen.frame.minX,y:screen.frame.maxY-height,width:screen.frame.width,height:height)
    }
    func present(_ visible:Bool,severity:Double=0,progress:Double=0) {
        self.visible=visible;self.severity=SmokeGeometry.clamp(severity);self.progress=progress
        guard visible else{clear();return}
        if panels.isEmpty{create()}
        views.forEach{$0.update(severity:self.severity,progress:progress)}
    }
    private func create() {
        for screen in NSScreen.screens {
            let panel=NSPanel(contentRect:Self.frame(for:screen),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.identifier=NSUserInterfaceItemIdentifier("zone-menu-bar-glow")
            panel.level=NSWindow.Level(rawValue:NSWindow.Level.statusBar.rawValue+1)
            panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
            panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=false
            panel.ignoresMouseEvents=true;panel.hidesOnDeactivate=false;panel.isReleasedWhenClosed=false;panel.animationBehavior = .none
            let view=MenuBarGlowView(severity:severity,progress:progress)
            let entrance=WarningEntranceView(content:view,size:panel.frame.size)
            panel.contentView=entrance;panels.append(panel);views.append(view)
            entrance.appear();panel.orderFrontRegardless()
        }
    }
    private func clear(){panels.forEach{WarningEntranceView.remove($0)};panels=[];views=[]}
}

final class MenuBarGlowView:NSView {
    private(set) var severity:Double
    private(set) var progress:Double
    private let origin=ProcessInfo.processInfo.systemUptime
    private let fixedTime:Double?
    private let glow=CAGradientLayer()
    private var pulseSignature:[Double]?
    override var isOpaque:Bool{false}
    init(severity:Double,progress:Double,time:Double?=nil) {
        self.severity=SmokeGeometry.clamp(severity);self.progress=progress;fixedTime=time
        super.init(frame:.zero)
        if time==nil {wantsLayer=true;layer?.addSublayer(glow);glow.actions=["colors":NSNull(),"opacity":NSNull(),"bounds":NSNull(),"position":NSNull()];refreshLayer()}
    }
    required init?(coder:NSCoder){fatalError("Not supported")}
    override func hitTest(_ point:NSPoint)->NSView?{nil}
    override func layout() {super.layout();CATransaction.begin();CATransaction.setDisableActions(true);glow.frame=bounds;CATransaction.commit()}
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();refreshLayer()}
    func update(severity:Double,progress:Double) {
        let next=SmokeGeometry.clamp(severity)
        guard next != self.severity || progress != self.progress else{return}
        self.severity=next;self.progress=progress
        if fixedTime==nil {refreshLayer()} else {needsDisplay=true}
    }
    private func refreshLayer() {
        guard fixedTime==nil else{return}
        let color=SmokeGeometry.color(severity)
        glow.colors=[color.withAlphaComponent(0.82).cgColor,color.cgColor]
        let base=Self.opacity(severity:severity,progress:progress,time:0,reduceMotion:true)
        glow.opacity=Float(base)
        let animate=window != nil && severity>=2 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animate else{glow.removeAnimation(forKey:"breath");pulseSignature=nil;return}
        let peak=Self.opacity(severity:severity,progress:progress,time:0.25/MenuBarIcon.pulseFrequency,reduceMotion:false)
        let amplitude=peak-base
        let signature=[Double(base),Double(amplitude)]
        // Color may change without changing pulse geometry. Retain the existing
        // red animation instead of allocating identical keyframes per sample.
        guard pulseSignature != signature || glow.animation(forKey:"breath")==nil else{return}
        pulseSignature=signature
        let pulse=CAKeyframeAnimation(keyPath:"opacity")
        pulse.values=(0...32).map {Float(base+amplitude*CGFloat(sin(Double($0)*2*Double.pi/32)))}
        pulse.duration=1/MenuBarIcon.pulseFrequency;pulse.repeatCount = .infinity
        // All views share a stable phase; posture updates do not restart the pulse.
        pulse.beginTime=origin
        glow.add(pulse,forKey:"breath")
    }
    static func opacity(severity:Double,progress:Double,time:Double,reduceMotion:Bool)->CGFloat {
        let s=SmokeGeometry.clamp(severity),p=s>=2 && progress.isFinite ? min(1,max(0,progress)):0
        let urgency=min(1,s/2)*0.75+p*0.25
        let wave=reduceMotion || s<2 ? 0:sin(time*2*Double.pi*MenuBarIcon.pulseFrequency)
        return CGFloat(0.18+0.20*urgency+wave*0.045*max(0,min(1,s-1))*(0.3+0.7*p))
    }
    override func draw(_ dirtyRect:NSRect) {
        guard fixedTime != nil else{return}
        let time=fixedTime ?? ProcessInfo.processInfo.systemUptime-origin
        let alpha=Self.opacity(severity:severity,progress:progress,time:time,reduceMotion:NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let color=SmokeGeometry.color(severity)
        NSGradient(starting:color.withAlphaComponent(alpha*0.82),ending:color.withAlphaComponent(alpha))?.draw(in:bounds,angle:90)
    }
}
