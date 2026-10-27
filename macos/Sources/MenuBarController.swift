import AppKit
import SwiftUI
import Combine

/// One owner for the menu-bar item, camera model and on-demand controls window.
/// Hiding controls never changes capture, calibration or saved preferences.
final class ZoneAppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate {
    let model:CameraModel
    private(set) var controlsWindow:NSWindow?
    private(set) var statusItem:NSStatusItem?
    private var subscription:AnyCancellable?
    private var visualPolicyObserver:NSObjectProtocol?
    private var lastStatus=""
    private var lastPresentationKey=""
    var isMenuIconAnimating:Bool{false}
    private var terminated=false
    private var controlsPresenceGeneration:UInt=0
    private var controlsWantedOpen=false
    private var controlsFrame:NSRect?

    override convenience init(){self.init(model:CameraModel())}
    init(model:CameraModel){
        self.model=model;super.init()
        model.updateWindowContext={ [weak self] in
            (page:self?.model.controlsPage.rawValue ?? "Posture",visible:self?.controlsWindow.map{$0.isVisible || $0.isMiniaturized} ?? false)
        }
    }
    deinit{subscription?.cancel();if let visualPolicyObserver{NotificationCenter.default.removeObserver(visualPolicyObserver)}}

    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory)
        applyApplicationIcon()
        installMainMenu()
        installStatusItem()
        if let receipt=model.consumeUpdateResume() {
            if NSRunningApplication(processIdentifier:receipt.request.sourcePID)?.isTerminated == false {
                model.message="The previous Zone instance is still closing. Turn Camera on when ready.";showControls();return
            }
            model.controlsPage=ControlsPage(rawValue:receipt.state.page) ?? .posture
            if receipt.state.controlsVisible {showControls()}
            model.resumeAfterUpdate(receipt.state)
        } else {showControls()}
    }

    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {
        showControls();return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
    func applicationWillTerminate(_ notification:Notification) {
        guard !terminated else{return}
        terminated=true;model.prepareForApplicationTermination();subscription?.cancel();subscription=nil
        if let statusItem {NSStatusBar.system.removeStatusItem(statusItem)}
        statusItem=nil
    }

    @objc func showControls() {
        installStatusItem()
        if controlsWindow==nil {
            let window=NSWindow(contentRect:NSRect(origin:.zero,size:ZoneWindowLayout.size),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            window.title="Zone"
            window.identifier=NSUserInterfaceItemIdentifier("posture-main")
            window.contentMinSize=ZoneWindowLayout.size
            window.contentMaxSize=ZoneWindowLayout.size
            // Ordinary window ordering: other apps may come forward, while
            // the controls remain open until explicit close/minimize.
            window.hidesOnDeactivate=false
            window.level = .normal
            window.collectionBehavior=[.managed,.participatesInCycle]
            window.isReleasedWhenClosed=false
            window.delegate=self
            window.contentView=nil
            if let controlsFrame {window.setFrame(window.constrainFrameRect(controlsFrame,to:NSScreen.main),display:false)}else{window.center()}
            controlsWindow=window
        }
        guard let window=controlsWindow else{return}
        controlsPresenceGeneration &+= 1;controlsWantedOpen=true
        // A real controls window participates in ordinary Dock/Command-Tab
        // navigation. The camera owner never changes during this transition.
        NSApp.setActivationPolicy(.regular)
        applyApplicationIcon()
        // Dock creation after an accessory→regular transition is asynchronous.
        // Reapply once after this turn; closing/reopening cancels an old refresh.
        let iconGeneration=controlsPresenceGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,!self.terminated,self.controlsWantedOpen,
                  self.controlsPresenceGeneration==iconGeneration else{return}
            self.applyApplicationIcon()
        }
        attachControlsContent()
        if window.isMiniaturized{window.deminiaturize(nil)}
        NSApp.activate(ignoringOtherApps:true)
        window.makeKeyAndOrderFront(nil)
    }

    private func applyApplicationIcon() {
        guard let resource=Bundle.main.object(forInfoDictionaryKey:"CFBundleIconFile") as? String,
              let url=Bundle.main.url(forResource:resource,withExtension:"icns"),
              let data=try? Data(contentsOf:url),let image=NSImage(data:data) else{return}
        // Decode the current bytes rather than a URL/name-cached image.
        NSApp.applicationIconImage=image
        NSApp.dockTile.display()
    }

    private func attachControlsContent() {
        guard let window=controlsWindow,window.contentView==nil else{return}
        window.contentView=NSHostingView(rootView:MainView(model:model,onHideControls:{[weak self] in self?.hideControls()},onQuit:{[weak self] in self?.quitZone()}).preferredColorScheme(.light))
    }
    @objc func hideControls(){
        controlsPresenceGeneration &+= 1;controlsWantedOpen=false
        model.setPreviewLayer(nil)
        if let window=controlsWindow {
            controlsFrame=window.frame
            window.contentView=nil;window.delegate=nil
            // Release the native window/backing store as well as the SwiftUI
            // tree. Camera ownership stays in this delegate's persistent model.
            window.close();controlsWindow=nil
        }
        let generation=controlsPresenceGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,!self.terminated,!self.controlsWantedOpen,generation==self.controlsPresenceGeneration,
                  self.controlsWindow==nil else{return}
            NSApp.setActivationPolicy(.accessory)
        }
    }
    func windowDidMiniaturize(_ notification:Notification){model.setPreviewLayer(nil);controlsWindow?.contentView=nil}
    func windowDidDeminiaturize(_ notification:Notification){if controlsWantedOpen {attachControlsContent()}}

    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard sender === controlsWindow else{return true}
        hideControls();return false
    }

    private func installStatusItem() {
        guard statusItem==nil,!terminated else{return}
        let item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        if let button=item.button {
            button.setAccessibilityLabel("Zone")
            button.target=self;button.action=#selector(statusItemClicked(_:))
            button.sendAction(on:[.leftMouseUp,.rightMouseUp])
        }
        item.menu=nil
        statusItem=item
        if visualPolicyObserver==nil {
            visualPolicyObserver=NotificationCenter.default.addObserver(forName:.diagnosticVisualPolicyChanged,object:nil,queue:.main){[weak self] _ in self?.refreshStatus()}
        }
        if subscription==nil {
            // objectWillChange fires before assignments. Deliver after the batch so
            // the menu-bar description reads the new values, not the previous frame.
            subscription=model.objectWillChange
                .debounce(for:.milliseconds(20),scheduler:RunLoop.main)
                .sink{[weak self] _ in self?.refreshStatus()}
        }
        refreshStatus()
    }

    /// Event routing stays separate from menu construction so native checks do
    /// not have to synthesize input or quit their own host process.
    static func opensStatusMenu(for eventType:NSEvent.EventType?,controlPressed:Bool=false)->Bool {
        eventType == .rightMouseUp || (eventType == .leftMouseUp && controlPressed)
    }
    @objc func statusItemClicked(_ sender:NSStatusBarButton) {
        let event=NSApp.currentEvent
        guard Self.opensStatusMenu(for:event?.type,controlPressed:event?.modifierFlags.contains(.control) == true) else {
            showControls();return
        }
        // A native, transient contextual menu provides standard outside-click
        // dismissal. Keep statusItem.menu nil so left-click always opens controls.
        let menu=makeStatusMenu()
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.minY-4),in:sender)
    }
    func makeStatusMenu()->NSMenu {
        let menu=NSMenu(title:"Zone")
        menu.addItem(item("Open Zone",action:#selector(showControls),key:""))
        menu.addItem(.separator())
        menu.addItem(item("Quit app",action:#selector(quitZone),key:"q"))
        return menu
    }

    private var statusSummary:String {
        if model.loading{return "Starting camera"}
        if !model.active{return "Camera off"}
        if model.paused{return "Reminders paused"}
        if model.state=="lost"{return "Tracking paused"}
        if !model.monitoring {
            switch model.stage {
            case "green":return "Setup: comfortable height"
            case "yellow":return "Setup: yellow boundary"
            case "red":return "Setup: red boundary"
            case "review":return model.persistenceMessage == nil ? "Finishing height setup":"Height not saved"
            default:return "Setting up your zones"
            }
        }
        if model.state=="lost" || (!model.hasPose && !model.bottomExitHeld){return "Tracking paused"}
        switch model.state {
        case "inside":return "Green: in your zone"
        case "yellow":return "Yellow: near your edge"
        case "outside","alert":return "Red: outside your zone"
        default:return "Finding your position"
        }
    }

    private var iconZone:String {
        guard model.active,!model.loading,!model.paused,model.monitoring,(model.hasPose || model.bottomExitHeld),
              ["inside","yellow","outside","alert"].contains(model.state),
              let score=model.score,score.isFinite else{return "neutral"}
        return score < model.yellow ? "green":score < model.red ? "yellow":"red"
    }
    private func statusImage(zone:String)->NSImage? {
        guard let symbol=NSImage(systemSymbolName:"circle.dotted",accessibilityDescription:"Zone")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:17,weight:.semibold)) else{return nil}
        guard zone != "neutral" else {
            let image=NSImage(size:MenuBarIcon.size,flipped:false){rect in symbol.draw(in:rect.insetBy(dx:0.5,dy:0.5));return true}
            image.isTemplate=true;return image
        }
        let color:NSColor
        switch zone {
        case "green":color=NSColor(srgbRed:0.12,green:0.70,blue:0.36,alpha:1)
        case "yellow":color=NSColor(srgbRed:0.96,green:0.66,blue:0.08,alpha:1)
        default:color=NSColor(srgbRed:0.94,green:0.23,blue:0.24,alpha:1)
        }
        // Bake color into a non-template image so macOS does not replace it with
        // the menu bar's monochrome tint. The original symbol geometry is retained.
        let image=NSImage(size:MenuBarIcon.size,flipped:false) {rect in
            symbol.draw(in:rect.insetBy(dx:0.5,dy:0.5))
            color.setFill();rect.fill(using:.sourceIn)
            return true
        }
        image.isTemplate=false
        return image
    }
    func refreshStatus(at now:Double=ProcessInfo.processInfo.systemUptime) {
        guard !terminated else{return}
        let summary=statusSummary,zone=iconZone
        let mode=DiagnosticVisualPolicy.shared.mode
        if mode.freezesIcon {
            if statusItem?.button?.image==nil {statusItem?.button?.image=MenuBarIcon.statusImage(zone:"neutral")}
            lastPresentationKey="diagnostic-frozen"
        } else {
            let shownZone=mode.suppressesOverlays ? "neutral":zone
            // Only a zone/availability change redraws the static color icon.
            // Numeric menu scores have been removed; the main live chart remains.
            if shownZone != lastPresentationKey || statusItem?.button?.image==nil {
                statusItem?.button?.image=MenuBarIcon.statusImage(zone:shownZone)
                lastPresentationKey=shownZone
            }
        }
        if statusItem?.length != NSStatusItem.squareLength {statusItem?.length=NSStatusItem.squareLength}
        if statusItem?.button?.title != "" {statusItem?.button?.title=""}
        guard summary != lastStatus || statusItem?.button?.toolTip==nil else{return}
        lastStatus=summary
        statusItem?.button?.toolTip="Zone · \(summary)\nClick to open Zone. Right-click to quit."
        statusItem?.button?.setAccessibilityLabel("Zone: \(summary)")
        statusItem?.button?.setAccessibilityHelp("Click to open Posture, Progress and Settings. Right-click for Quit app.")
    }

    @objc func showSettings(){model.controlsPage = .settings;showControls()}

    @objc func quitZone(){model.updateResumeStore.cancel();model.stop();NSApp.terminate(nil)}

    private func item(_ title:String,action:Selector,key:String)->NSMenuItem {
        let result=NSMenuItem(title:title,action:action,keyEquivalent:key);result.target=self;return result
    }
    private func installMainMenu() {
        let main=NSMenu()
        let applicationItem=NSMenuItem(),applicationMenu=NSMenu(title:"Zone")
        applicationMenu.addItem(item("Open Zone",action:#selector(showControls),key:""))
        applicationMenu.addItem(item("Settings…",action:#selector(showSettings),key:","))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(item("Quit app",action:#selector(quitZone),key:"q"))
        applicationItem.submenu=applicationMenu;main.addItem(applicationItem)
        let windowItem=NSMenuItem(),windowMenu=NSMenu(title:"Window")
        windowMenu.addItem(item("Hide Controls",action:#selector(hideControls),key:"w"))
        windowItem.submenu=windowMenu;main.addItem(windowItem)
        NSApp.mainMenu=main;NSApp.windowsMenu=windowMenu
    }
}
