import AppKit
import QuartzCore

// Integrator-run executable: use the existing synthetic visual-check harness,
// including WarningEntrance.swift and replacing the harness's check entry point.
// Uses synthetic warning state; no camera or preferences.
// This check creates real panels, so run only in the authorized QA environment.
@main struct WarningEntranceChecks {
    static func check(_ value:@autoclosure()->Bool,_ message:String) {
        precondition(value(),message)
    }
    static func animation(_ view:WarningEntranceView)->CAAnimation? {
        view.layer?.animation(forKey:WarningEntranceView.animationKey)
    }
    static func pumpPastEntrance() {
        let deadline=Date().addingTimeInterval(WarningEntranceView.duration+0.15)
        while Date()<deadline {RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
    }
    static func helperChecks() {
        let content=NSView(frame:.zero)
        let entrance=WarningEntranceView(content:content,size:NSSize(width:320,height:200))
        check(content.superview === entrance && content.frame == entrance.bounds,"wrapper preserves content sizing")
        entrance.setFrameSize(NSSize(width:480,height:300))
        check(content.frame == entrance.bounds,"content follows panel resizing")
        check(entrance.layer?.opacity == 0,"warning begins transparent before ordering")
        entrance.appear(reduceMotion:false)
        let first=animation(entrance) as! CABasicAnimation
        check(first.keyPath == "opacity" && first.duration == 0.4,"one 0.4 second compositor entrance")
        check((first.fromValue as? NSNumber)?.floatValue == 0 && (first.toValue as? NSNumber)?.floatValue == 1,"opacity endpoints")
        check(first.delegate == nil && first.repeatCount == 0 && !first.autoreverses && first.isRemovedOnCompletion,"no completion delegate, repetition or fade-out")
        check(entrance.layer?.opacity == 1,"model layer is visible after entrance without callback")
        entrance.appear(reduceMotion:false)
        check(animation(entrance)?.beginTime == first.beginTime,"repeat appearance cannot restart entrance")
        entrance.layer?.removeAnimation(forKey:WarningEntranceView.animationKey)
        entrance.appear(reduceMotion:false)
        check(animation(entrance) == nil,"completed entrance cannot restart")
        let reduced=WarningEntranceView(content:NSView(),size:NSSize(width:10,height:10))
        reduced.appear(reduceMotion:true)
        check(reduced.layer?.opacity == 1 && animation(reduced) == nil,"Reduce Motion appears immediately")
        let cancelled=WarningEntranceView(content:NSView(),size:NSSize(width:10,height:10))
        cancelled.appear(reduceMotion:false);cancelled.cancel();cancelled.appear(reduceMotion:false)
        check(cancelled.isCancelled && cancelled.layer?.opacity == 0 && animation(cancelled) == nil,"cancel unfinished entrance permanently")
        let neverShown=WarningEntranceView(content:NSView(),size:NSSize(width:10,height:10))
        neverShown.cancel();neverShown.appear(reduceMotion:false)
        check(!neverShown.hasAppeared && animation(neverShown) == nil,"cancel before appearance is terminal")
    }
    static func warningPanels()->[NSPanel] {
        NSApplication.shared.windows.compactMap{$0 as? NSPanel}.filter{$0.contentView is WarningEntranceView}
    }
    static func integrationChecks() {
        check(!NSScreen.screens.isEmpty,"QA requires a screen")
        var controller:LiveZoneVisualsController?=LiveZoneVisualsController()
        controller!.showsMenuGlow=true
        controller!.present(.yellowHalo,severity:1.2)
        let first=warningPanels()
        let wrappers=first.map{$0.contentView as! WarningEntranceView}
        let starts=wrappers.map{animation($0)?.beginTime}
        check(first.count == 2*NSScreen.screens.count,"smoke and menu glow on every screen")
        check(first.allSatisfy{$0.isVisible && $0.ignoresMouseEvents},"yellow remains visible and click-through")
        check(wrappers.allSatisfy{$0.hasAppeared},"each new panel receives entrance")
        controller!.present(.yellowHalo,severity:1.6,progress:0.3)
        controller!.present(.redFocus,severity:2.2,progress:0.7)
        check(first.allSatisfy{$0.isVisible},"severity preserves existing panels")
        for index in wrappers.indices {
            check(first[index].contentView === wrappers[index],"severity does not replace content")
            // Natural compositor completion may remove the animation while the
            // synthetic card is being built. A surviving animation keeps its epoch.
            let current=animation(wrappers[index])
            check(current == nil || current?.beginTime == starts[index],"severity/progress does not restart entrance")
        }
        let cards=warningPanels().filter{!$0.ignoresMouseEvents}
        check(cards.count == 1 && (cards[0].contentView as! WarningEntranceView).hasAppeared,"new red card enters and retains interaction")
        let card=cards[0],cardView=card.contentView as! WarningEntranceView
        controller!.present(.redFocus,severity:2.5,progress:1)
        check(card.contentView === cardView,"sustained red preserves original card")
        controller!.present(.yellowHalo,severity:1.7)
        check(!card.isVisible && card.contentView == nil && cardView.isCancelled,"red card clears immediately on retreat")
        controller!.present(.redFocus,severity:2.1)
        let recreatedCard=warningPanels().first{!$0.ignoresMouseEvents}!
        check(recreatedCard !== card && (recreatedCard.contentView as! WarningEntranceView).hasAppeared,"new red lifetime gets new entrance")
        let beforeDisplayChange=warningPanels()
        let beforeDisplayViews=beforeDisplayChange.map{$0.contentView as! WarningEntranceView}
        NotificationCenter.default.post(name:NSApplication.didChangeScreenParametersNotification,object:nil)
        check(beforeDisplayChange.allSatisfy{!$0.isVisible && $0.contentView == nil},"display rebuild closes old panels immediately")
        check(beforeDisplayViews.allSatisfy{$0.isCancelled && animation($0) == nil},"display rebuild cancels old entrances")
        check(warningPanels().count == 2*NSScreen.screens.count+1,"display rebuild preserves smoke, menu glow and original red card count")
        check(warningPanels().allSatisfy{panel in
            !beforeDisplayChange.contains{$0 === panel} && (panel.contentView as! WarningEntranceView).hasAppeared
        },"genuinely recreated display panels receive new entrances")
        let removed=warningPanels(),removedViews=removed.map{$0.contentView as! WarningEntranceView}
        controller!.present(.greenHalo,severity:0)
        check(removed.allSatisfy{!$0.isVisible && $0.contentView == nil},"green orders out and detaches every panel synchronously")
        check(removedViews.allSatisfy{$0.isCancelled && animation($0) == nil && $0.layer?.opacity == 0},"green cancels every unfinished entrance")
        pumpPastEntrance()
        removedViews.forEach{$0.appear(reduceMotion:false)}
        check(removed.allSatisfy{!$0.isVisible} && warningPanels().isEmpty,"no late callback restores removed visuals")
        controller!.present(.yellowHalo,severity:1.3)
        check(warningPanels().count == 2*NSScreen.screens.count,"warning recreates after green")
        check(warningPanels().allSatisfy{panel in !removed.contains{$0 === panel}},"recreated panels have new identities")
        for _ in 0..<2 {
            let panels=warningPanels()
            controller!.present(.hidden) // loss / pause / stop presentation path
            check(panels.allSatisfy{!$0.isVisible && $0.contentView == nil},"hidden removes immediately")
            controller!.present(.redFocus,severity:2)
        }
        let finalPanels=warningPanels()
        controller=nil
        check(finalPanels.allSatisfy{!$0.isVisible && $0.contentView == nil},"controller teardown closes all warnings")
        pumpPastEntrance()
        check(warningPanels().isEmpty,"teardown has no delayed resurrection")
    }
    static func main() {
        _=NSApplication.shared
        helperChecks();integrationChecks()
        print("PASS: warning entrance one-shot, updates, cancellation, removal, recreation, Reduce Motion and teardown")
    }
}
