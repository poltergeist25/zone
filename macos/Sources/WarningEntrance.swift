import AppKit
import QuartzCore

// Own a separate container layer; never replace or animate NSHostingView's layer.
// One container belongs to one panel lifetime. There are no completion callbacks,
// timers, or deferred orderFront calls that could resurrect a removed warning.
final class WarningEntranceView:NSView {
    static let animationKey="zone-warning-entrance"
    static let duration:CFTimeInterval=0.4
    private(set) var hasAppeared=false
    private(set) var isCancelled=false
    let content:NSView

    init(content:NSView,size:NSSize) {
        self.content=content
        super.init(frame:NSRect(origin:.zero,size:size))
        wantsLayer=true
        content.frame=bounds
        content.autoresizingMask=[.width,.height]
        addSubview(content)
        // Keep the original content and its accessibility descendants intact.
        setAccessibilityElement(false)
        CATransaction.begin();CATransaction.setDisableActions(true)
        layer?.allowsGroupOpacity=true
        layer?.opacity=0
        CATransaction.commit()
    }
    required init?(coder:NSCoder){fatalError("Not supported")}

    func appear(reduceMotion:Bool=NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        guard !hasAppeared,!isCancelled,let layer else{return}
        hasAppeared=true
        CATransaction.begin();CATransaction.setDisableActions(true)
        layer.opacity=1
        if !reduceMotion {
            let entrance=CABasicAnimation(keyPath:"opacity")
            entrance.fromValue=Float(0);entrance.toValue=Float(1)
            entrance.duration=Self.duration
            entrance.beginTime=layer.convertTime(CACurrentMediaTime(),from:nil)
            entrance.timingFunction=CAMediaTimingFunction(name:.easeOut)
            layer.add(entrance,forKey:Self.animationKey)
        }
        CATransaction.commit()
    }

    func cancel() {
        isCancelled=true
        CATransaction.begin();CATransaction.setDisableActions(true)
        layer?.removeAnimation(forKey:Self.animationKey)
        layer?.opacity=0
        CATransaction.commit()
    }

    // All callers clear synchronously, including during an unfinished entrance.
    static func remove(_ panel:NSPanel) {
        panel.orderOut(nil)
        (panel.contentView as? WarningEntranceView)?.cancel()
        panel.contentView=nil
        panel.close()
    }
}
