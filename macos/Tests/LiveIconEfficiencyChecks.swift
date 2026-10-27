import AppKit
import Foundation

@main struct LiveIconEfficiencyChecks {
    static func main() {
        _=NSApplication.shared
        let notched=MenuBarIcon.statusImage(zone:"yellow")
        precondition(notched === MenuBarIcon.statusImage(zone:"yellow"),"Within-zone artwork stays identical without a redraw timer")
        precondition(notched.size==MenuBarIcon.colorStatusSize && notched.representations.count==1,"Color icon stays20pt with one cached raster")
        guard let statusRaster=notched.representations.first as? NSBitmapImageRep else{preconditionFailure("Notches must have no deferred vector drawing")}
        precondition(statusRaster.pixelsWide==40 && statusRaster.pixelsHigh==40,"Retina status art is rasterized once at2x")
        for y in 16...23 {for x in 16...23 {
            precondition((statusRaster.colorAt(x:x,y:y)?.alphaComponent ?? 0)<0.01,"The middle of every zone icon stays fully empty")
        }}
        // Count independent opaque components: not a filled disc, dotted ring,
        // or a continuous outline. Each of the twelve rectangular notches is solid.
        var remaining=Set<Int>()
        for y in 0..<40 {for x in 0..<40 {
            if (statusRaster.colorAt(x:x,y:y)?.alphaComponent ?? 0)>0.5 {remaining.insert(y*40+x)}
        }}
        var components=0
        while let first=remaining.first {
            components += 1;remaining.remove(first);var frontier=[first]
            while let point=frontier.popLast() {
                let x=point%40,y=point/40
                for dy in -1...1 {for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx=x+dx,ny=y+dy
                    if (0..<40).contains(nx),(0..<40).contains(ny),remaining.remove(ny*40+nx) != nil {frontier.append(ny*40+nx)}
                }}
            }
        }
        precondition(components==12,"Option C has exactly twelve separate solid notches")
        let neutralStatus=MenuBarIcon.statusImage(zone:"neutral")
        precondition(neutralStatus.isTemplate && !notched.isTemplate,"Neutral notches adapt to light/dark menus; zone colors remain baked in")
        precondition(neutralStatus === MenuBarIcon.statusImage(zone:"unknown"),"Unavailable/unknown state shares the bounded neutral raster")
        precondition(MenuBarIcon.statusImage(zone:"green") !== notched && MenuBarIcon.statusImage(zone:"red") !== notched,"Zone changes select distinct cached color art immediately")
        precondition(MenuBarIcon.liveCacheCountLimit==96 && MenuBarIcon.liveCacheCostLimit<=1024*1024)
        precondition(MenuBarIcon.liveRasterCost*MenuBarIcon.liveCacheCountLimit<=MenuBarIcon.liveCacheCostLimit,
            "Even the full configured cache stays below one MiB of raster storage")
        let first=MenuBarIcon.liveImage(severity:1.211,progress:0)
        let sameStep=MenuBarIcon.liveImage(severity:1.219,progress:1)
        precondition(first === sameStep,"One severity step reuses the same raster; yellow ignores stale red progress")
        let redFirst=MenuBarIcon.liveImage(severity:2.101,progress:0.301)
        let redSame=MenuBarIcon.liveImage(severity:2.119,progress:0.309)
        precondition(redFirst === redSame,"Red dwell progress is cached at the same twenty-step precision")
        precondition(first !== MenuBarIcon.liveImage(severity:1.30,progress:0),"Different severity retains its own appearance")
        let neutral=MenuBarIcon.liveImage(severity:0,progress:0)
        precondition(neutral === MenuBarIcon.liveImage(severity:.nan,progress:.infinity),"Invalid values resolve to the bounded neutral key")
        func raster(_ image:NSImage)->NSBitmapImageRep {
            precondition(image.size==NSSize(width:18,height:18) && !image.isTemplate)
            precondition(image.representations.count==1,"A live image retains no deferred vector representation")
            guard let bitmap=image.representations.first as? NSBitmapImageRep else{preconditionFailure("Live status artwork must already be rasterized")}
            precondition(bitmap.pixelsWide==36 && bitmap.pixelsHigh==36)
            precondition(bitmap.size==NSSize(width:18,height:18) && bitmap.bytesPerRow*bitmap.pixelsHigh<=MenuBarIcon.liveRasterCost)
            return bitmap
        }
        func strongest(_ image:NSImage)->NSColor {
            let bitmap=raster(image)
            var winner=NSColor.clear
            for y in 0..<bitmap.pixelsHigh {for x in 0..<bitmap.pixelsWide {
                if let color=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.sRGB),color.alphaComponent>winner.alphaComponent {winner=color}
            }}
            precondition(winner.alphaComponent>0.5,"Raster contains visible artwork within its tiny bounds")
            return winner
        }
        let green=strongest(neutral),yellow=strongest(MenuBarIcon.liveImage(severity:1,progress:0)),red=strongest(MenuBarIcon.liveImage(severity:2,progress:1))
        precondition(green.greenComponent>green.redComponent)
        precondition(yellow.redComponent>0.8 && yellow.greenComponent>0.5 && yellow.blueComponent<0.2)
        precondition(red.redComponent>0.8 && red.greenComponent<0.4)
        for severity in [0.0,1,1.1,1.5,1.95] {
            let base=MenuBarGlowView.opacity(severity:severity,progress:1,time:0,reduceMotion:true)
            for time in [0.0,0.3,0.8,2.1,10] {
                let actual=MenuBarGlowView.opacity(severity:severity,progress:1,time:time,reduceMotion:false)
                precondition(abs(actual-base)<0.0000001,"Yellow glow stays steady with its existing color/opacity")
            }
        }
        let peak=MenuBarGlowView.opacity(severity:2,progress:1,time:0.25/MenuBarIcon.pulseFrequency,reduceMotion:false)
        let trough=MenuBarGlowView.opacity(severity:2,progress:1,time:0.75/MenuBarIcon.pulseFrequency,reduceMotion:false)
        precondition(peak>trough,"Red retains its restrained pulse")
        print("PASS: selected12-notch status art, empty middle and static per-zone cache; legacy same-step live raster identity, bounded96-entry cache,36px/18pt non-template bitmaps and colors, invalid-value bounds, steady yellow and pulsing red; synthetic only")
    }
}
