import AppKit

// Compile with Sources/SmokeHalo.swift. Optional first argument is a PNG output folder.
@main struct LayeredSmokeChecks {
    static var checks=0
    static func check(_ condition:@autoclosure()->Bool,_ name:String) {
        guard condition() else{fatalError("FAIL: \(name)")}
        checks += 1
    }
    // AppKit may spend a short first run-loop pass servicing offscreen-window
    // setup. Wait for the actual timer callback, bounded independently of that work.
    static func pump(until condition:()->Bool,timeout:Double=2) {
        let deadline=ProcessInfo.processInfo.systemUptime+timeout
        while !condition() && ProcessInfo.processInfo.systemUptime<deadline {
            RunLoop.main.run(until:Date().addingTimeInterval(0.02))
        }
    }
    static func host(_ smoke:SmokeHaloView,size:NSSize)->NSWindow {
        let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.isOpaque=false;window.backgroundColor = .clear
        window.contentView=smoke;smoke.frame=NSRect(origin:.zero,size:size);smoke.layoutSubtreeIfNeeded()
        return window
    }
    static func raster(_ view:NSView)->NSBitmapImageRep {
        view.layoutSubtreeIfNeeded();view.displayIfNeeded()
        let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
        view.cacheDisplay(in:view.bounds,to:bitmap)
        return bitmap
    }
    static func pixel(_ bitmap:NSBitmapImageRep,size:NSSize,x:CGFloat,y:CGFloat)->NSColor {
        let px=max(0,min(bitmap.pixelsWide-1,Int(x/size.width*CGFloat(bitmap.pixelsWide))))
        let py=max(0,min(bitmap.pixelsHigh-1,Int(y/size.height*CGFloat(bitmap.pixelsHigh))))
        return bitmap.colorAt(x:px,y:py)!.usingColorSpace(.sRGB)!
    }
    // Average both horizontal edges so raster-coordinate orientation is immaterial.
    static func band(_ bitmap:NSBitmapImageRep,size:NSSize,inset:CGFloat)->(alpha:Double,darkness:Double) {
        var alpha=0.0,darkness=0.0
        for index in 0..<80 {
            let x=size.width*(0.48+0.04*CGFloat(index)/79)
            for y in [inset,size.height-inset-1] {
                let c=pixel(bitmap,size:size,x:x,y:y),a=Double(c.alphaComponent)
                let luminance=0.2126*Double(c.redComponent)+0.7152*Double(c.greenComponent)+0.0722*Double(c.blueComponent)
                alpha += a;darkness += a*(1-luminance)
            }
        }
        return (alpha/160,darkness/160)
    }
    static func main() throws {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited);app.appearance=NSAppearance(named:.aqua)
        let output=CommandLine.arguments.count>1 ? URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true):FileManager.default.temporaryDirectory.appendingPathComponent("zone-layered-smoke",isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let size=NSSize(width:1920,height:1400)
        for scale in [CGFloat(2),4,8,20,50] {
            check(SmokeGeometry.depth(2,scale:scale)==30*scale,"exact nominal red depth \(scale)x")
            check(SmokeGeometry.depth(0,scale:scale)==5*scale,"exact nominal green depth \(scale)x")
            let smoke=SmokeHaloView(severity:2,time:2,depthScale:scale),window=host(smoke,size:size)
            let image=raster(smoke),nominalDepth=SmokeGeometry.depth(2,scale:scale)
            // At very large scales, visible reach is softly capped before the
            // center. Sample inside that reach, rather than past the far edge.
            let depth=min(nominalDepth,size.height*0.46)
            let edge=band(image,size:size,inset:max(1,depth*0.02))
            let middle=band(image,size:size,inset:depth*0.25)
            let tail=band(image,size:size,inset:depth*0.65)
            check(edge.alpha>middle.alpha && middle.alpha>tail.alpha,"opacity falls inward \(scale)x")
            check(edge.darkness>middle.darkness && middle.darkness>tail.darkness,"darkness falls inward \(scale)x")
            check(band(image,size:size,inset:min(depth+2,size.height/2)).alpha<0.005,"deepest tail transparent \(scale)x")
            check(pixel(image,size:size,x:size.width/2,y:size.height/2).alphaComponent<0.005,"center clear \(scale)x")
            let background=LightSmokeBackground(frame:NSRect(origin:.zero,size:size))
            smoke.removeFromSuperview();window.contentView=background;background.addSubview(smoke);smoke.frame=background.bounds
            let flat=raster(background)
            try flat.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("layered-smoke-\(Int(scale))x.png"))
            check(pixel(flat,size:size,x:size.width/2,y:size.height/2).alphaComponent>0.99,"opaque preview background \(scale)x")
            window.contentView=nil;window.close()
        }
        let smallSize=NSSize(width:320,height:220)
        for scale in [CGFloat(20),50] {
            let small=SmokeHaloView(severity:3,time:2,depthScale:scale),smallWindow=host(small,size:smallSize)
            check(SmokeGeometry.depth(3,scale:scale)==40*scale,"nominal depth retained on small display \(scale)x")
            let smallImage=raster(small)
            check(pixel(smallImage,size:smallSize,x:160,y:110).alphaComponent<0.005,"small display center protection \(scale)x")
            check(small.subviews.allSatisfy{$0.frame.width<=smallSize.width && $0.frame.height<=smallSize.height},"strips bounded by display \(scale)x")
            smallWindow.contentView=nil;smallWindow.close()
        }
        check(SmokeGeometry.depth(2,scale:12.5)==375,"fractional scale retains exact nominal depth")
        let fractional=SmokeHaloView(severity:2,time:2,depthScale:12.5)
        check(fractional.depthScale==12.5,"fractional scale initializer")
        fractional.setDepthScale(49.5)
        check(fractional.depthScale==49.5,"continuous scale updates")
        fractional.setDepthScale(99)
        check(fractional.depthScale==50 && SmokeGeometry.depth(3,scale:99)==2000,"upper scale clamp is 50")
        check(SmokeGeometry.depth(2,scale:1)==30,"legacy 1x scale retained")

        let shrinking=SmokeHaloView(severity:2,time:2,depthScale:20),shrinkWindow=host(shrinking,size:size)
        check(band(raster(shrinking),size:size,inset:100).alpha>0.01,"wide tail initially visible")
        shrinking.setDepthScale(2)
        check(band(raster(shrinking),size:size,inset:100).alpha<0.005,"shrinking clears former tail")
        check(shrinking.subviews[0].frame.height==62,"strip follows current depth plus padding")
        shrinkWindow.contentView=nil;shrinkWindow.close()

        let animated=SmokeHaloView(severity:2,depthScale:20),animatedWindow=host(animated,size:size)
        check(animated.isAnimating,"attached live view starts timer")
        check(animated.subviews.isEmpty,"live smoke uses hosted layers, not redrawn views")
        check(animated.layer?.sublayers?.count==4,"four bounded live edge layers")
        let firstTextures=animated.layer!.sublayers!.flatMap{$0.sublayers!}.flatMap{$0.sublayers!}.compactMap{$0.contents as AnyObject?}
        let phase=animated.animationPhase
        pump(until:{animated.animationPhase>phase+0.10})
        check(animated.animationPhase>phase,"real timer callback advances animation")
        check(animated.layer!.sublayers!.allSatisfy{$0.sublayers!.allSatisfy{$0.animation(forKey:"smoke-drift") != nil}},"compositor drift animates without redraw timers")
        let before=animated.displayedSeverity;animated.setSeverity(0)
        check(animated.displayedSeverity<before,"retreat begins on observation")
        pump(until:{animated.displayedSeverity<0.08})
        check(animated.displayedSeverity<0.08,"real timer settles recovery")
        check(animated.layer!.sublayers![0].frame.height<120,"recovery immediately shrinks live strip")
        let nextTextures=animated.layer!.sublayers!.flatMap{$0.sublayers!}.flatMap{$0.sublayers!}.compactMap{$0.contents as AnyObject?}
        check(firstTextures.count==24 && zip(firstTextures,nextTextures).allSatisfy{$0 === $1},"severity updates reuse all24 bounded textures")
        let liveBitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(size.width),pixelsHigh:Int(size.height),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let context=NSGraphicsContext(bitmapImageRep:liveBitmap)!.cgContext
        animated.layer!.render(in:context)
        check(band(liveBitmap,size:size,inset:200).alpha<0.005,"actual live layers clear former deep pixels")
        animatedWindow.contentView=nil
        check(!animated.isAnimating,"detachment stops timer")
        animatedWindow.close()
        print("PASS: \(checks) layered smoke checks. PNG previews: \(output.path)")
    }
}

private final class LightSmokeBackground:NSView {
    override var isOpaque:Bool{true}
    override func draw(_ dirtyRect:NSRect) {
        NSColor(srgbRed:0.96,green:0.95,blue:0.93,alpha:1).setFill();dirtyRect.fill()
    }
}
