import AppKit
import SwiftUI

@main struct SmokeChecks {
    static func main() throws {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
        app.appearance=NSAppearance(named:.aqua)
        precondition(SmokeGeometry.depth(0)==5 && SmokeGeometry.depth(1)==15 && SmokeGeometry.depth(2)==30 && SmokeGeometry.depth(3)==40)
        precondition(SmokeGeometry.depth(99)==40 && SmokeGeometry.depth(.nan)==5)
        let output=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let easing=SmokeHaloView(severity:2)
        easing.setSeverity(0)
        precondition(easing.displayedSeverity<2 && easing.displayedSeverity>0,"Retreat begins on receipt, remains smooth")
        for _ in 0..<8 {easing.advance(dt:1/60)}
        precondition(easing.displayedSeverity<0.06,"Retreat settles in about120ms")
        easing.setSeverity(2);let start=easing.displayedSeverity;easing.advance(dt:1/60)
        precondition(easing.displayedSeverity>start && easing.displayedSeverity<0.5,"Advance interpolates instead of jumping")
        for _ in 0..<30 {easing.advance(dt:1/60)}
        precondition(easing.displayedSeverity>1.95,"Advance converges smoothly")
        for severity in [0.0,1,2] {
            let size=NSSize(width:1920,height:1080)
            let smoke=SmokeHaloView(severity:severity,time:2)
            let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.isOpaque=false;window.backgroundColor = .clear;window.contentView=smoke
            smoke.frame=NSRect(origin:.zero,size:size);smoke.layoutSubtreeIfNeeded()
            let bitmap=smoke.bitmapImageRepForCachingDisplay(in:smoke.bounds)!
            smoke.cacheDisplay(in:smoke.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("smoke-\(Int(severity)).png"))
            let cx=bitmap.pixelsWide/2,cy=bitmap.pixelsHigh/2
            precondition(bitmap.colorAt(x:cx,y:cy)!.alphaComponent==0,"Screen center must stay fully transparent")
            precondition(bitmap.colorAt(x:cx,y:2)!.alphaComponent>0.01,"Top edge must be visible")
            precondition(bitmap.colorAt(x:2,y:cy)!.alphaComponent>0.01,"Side edge must be visible")
            precondition(bitmap.colorAt(x:cx,y:bitmap.pixelsHigh-3)!.alphaComponent>0.01,"Bottom edge must be visible")
            precondition(bitmap.colorAt(x:bitmap.pixelsWide-3,y:cy)!.alphaComponent>0.01,"Right edge must be visible")
            precondition(bitmap.colorAt(x:cx,y:100)!.alphaComponent==0,"Smoke must not fill center")
            precondition(bitmap.colorAt(x:2,y:2)!.alphaComponent>0.01,"Overlapping corners must not erase one another")
            let light=NSView(frame:smoke.bounds);light.wantsLayer=true;light.layer?.backgroundColor=NSColor(srgbRed:0.96,green:0.95,blue:0.93,alpha:1).cgColor
            window.contentView=light;smoke.removeFromSuperview();light.addSubview(smoke);smoke.frame=light.bounds;light.layoutSubtreeIfNeeded()
            let flat=light.bitmapImageRepForCachingDisplay(in:light.bounds)!;light.cacheDisplay(in:light.bounds,to:flat)
            try flat.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("smoke-light-\(Int(severity)).png"))
            window.close()
        }
        let controller=LiveZoneVisualsController()
        controller.present(.greenHalo,severity:0)
        precondition(app.windows.filter{$0.isVisible}.isEmpty,"Green creates no overlays")
        controller.present(.yellowHalo,severity:1)
        let halos=app.windows.filter{$0.isVisible && $0.ignoresMouseEvents}
        precondition(halos.count==NSScreen.screens.count,"One smoke panel per display")
        let ids=Set(halos.map{ObjectIdentifier($0)})
        controller.present(.yellowHalo,severity:1.4)
        precondition(ids.isSubset(of:Set(app.windows.filter{$0.isVisible}.map{ObjectIdentifier($0)})),"Zone changes reuse halo panels")
        controller.present(.redFocus,severity:2)
        precondition(ids.isSubset(of:Set(app.windows.filter{$0.isVisible}.map{ObjectIdentifier($0)})),"Red focus keeps smoke panels")
        precondition(app.windows.filter{$0.isVisible && !$0.ignoresMouseEvents}.count==1,"Red adds one focus card")
        controller.present(.greenHalo,severity:0)
        precondition(app.windows.filter{$0.isVisible}.isEmpty,"Recovery immediately clears every overlay")
        controller.showsSmoke=false
        precondition(app.windows.filter{$0.isVisible}.isEmpty,"Menu-only mode immediately removes screen smoke")
        controller.present(.yellowHalo,severity:1.5)
        precondition(app.windows.filter{$0.isVisible}.isEmpty,"Menu-only warning creates no edge overlay")
        controller.present(.redFocus,severity:2)
        let card=app.windows.filter{$0.isVisible}
        precondition(card.count==1 && !card[0].ignoresMouseEvents,"Menu-only mode still displays the red card")
        controller.showsSmoke=true
        precondition(app.windows.contains{$0 === card[0] && $0.isVisible},"Comparison switch preserves active red card")
        precondition(app.windows.filter{$0.isVisible && $0.ignoresMouseEvents}.count==NSScreen.screens.count,"Smoke mode restores screen edges")
        controller.present(.hidden)
        precondition(app.windows.filter{$0.isVisible}.isEmpty,"Stop hides every overlay")
        print("PASS: smoke depth, transparent center, four edges, multi-display panel reuse, red card recovery, stop cleanup")
    }
}
